#!/usr/bin/env bats
# covers: hooks/ship-cycle-guard.sh
#
# Tests for the ship-pr-cycle mechanical-enforcement guard (#82).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/ship-cycle-guard.sh"
	TEST_TMP=$(cd "$(mktemp -d -t ship-guard.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Init a real git repo + populate ship-pr-cycle state so the guard
	# fires (vs no-op).
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email "t@x"
		git config user.name "T"
		git checkout -q -b feat/v0.9.5/test-branch
		# Empty commit so HEAD has a SHA
		git commit -q --allow-empty -m "init"
	)
	cd "$TEST_TMP" || return 1
	SHA=$(git rev-parse HEAD)
	mkdir -p .claude/.session-state/ship-pr-cycle
	cat >".claude/.session-state/ship-pr-cycle/$SHA.json" <<EOF
{"stage": "phase1", "branch": "feat/v0.9.5/test-branch"}
EOF
}

teardown() {
	cd /tmp || true # leave $TEST_TMP before deleting it
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-guard.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_payload_bash() {
	local cmd=$1
	printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

_payload_agent() {
	local subagent=$1
	printf '{"tool_name":"Agent","tool_input":{"subagent_type":"%s"}}' "$subagent"
}

# Helper: run guard with cwd in TEST_TMP, return status + output
_run_guard() {
	local payload=$1
	(cd "$TEST_TMP" && printf '%s' "$payload" | bash "$SCRIPT" 2>&1)
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

# --- inactive-branch passthrough ----------------------------------

@test "passes through when not on feat/chore/fix branch" {
	(cd "$TEST_TMP" && git checkout -q main 2>/dev/null || git checkout -q -b somebranch)
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
}

@test "passes through when no ship-pr-cycle state file" {
	(cd "$TEST_TMP" && rm -rf .claude/.session-state/ship-pr-cycle)
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
}

@test "passes through when stage=merged" {
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo '{"stage":"merged"}' >"$TEST_TMP/.claude/.session-state/ship-pr-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
}

# --- Bash hand-roll detection ------------------------------------

@test "blocks raw 'coderabbit review'" {
	run _run_guard "$(_payload_bash 'coderabbit review --base main')"
	[ "$status" -eq 0 ] # JSON deny exits 0
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"coderabbit review"* ]]
	[[ $output == *"local-review.sh"* ]]
}

@test "blocks raw 'gh pr merge'" {
	run _run_guard "$(_payload_bash 'gh pr merge 91 --squash')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"github-pr-merge"* ]]
}

@test "passes through innocent Bash commands" {
	run _run_guard "$(_payload_bash 'ls /tmp')"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

# --- Agent hand-roll detection -----------------------------------

@test "blocks raw pr-review-toolkit Agent call (no directive sentinel)" {
	run _run_guard "$(_payload_agent 'pr-review-toolkit:code-reviewer')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"pr-review-toolkit"* ]]
}

@test "allows pr-review-toolkit Agent when directive sentinel present" {
	# Orchestrator just emitted Phase 1 directive — sentinel exists.
	(cd "$TEST_TMP" && touch .claude/.session-state/ship-pr-cycle/phase1-directive-pending.txt)
	run _run_guard "$(_payload_agent 'pr-review-toolkit:code-reviewer')"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "passes through non-pr-review-toolkit Agent subagents" {
	run _run_guard "$(_payload_agent 'general-purpose')"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

# --- Bypass paths ------------------------------------------------

@test "SKILL_WRAPPER=1 env bypasses all checks" {
	export SKILL_WRAPPER=1
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	unset SKILL_WRAPPER
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "SHIP_PR_CYCLE_BYPASS=1 env bypasses + emits audit log" {
	export SHIP_PR_CYCLE_BYPASS=1
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	unset SHIP_PR_CYCLE_BYPASS
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
	[[ $output == *"audit logged"* ]]
}

@test "SHIP_PR_CYCLE_BYPASS=1 inline-prefix bypasses for Bash" {
	run _run_guard "$(_payload_bash 'SHIP_PR_CYCLE_BYPASS=1 gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
	[[ $output == *"inline prefix"* ]]
}

# --- malformed input fail-closed ---------------------------------

@test "malformed JSON payload denies (fail-closed)" {
	run bash -c "(cd '$TEST_TMP' && echo 'not json' | bash '$SCRIPT' 2>&1)"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "empty Bash command passes through (legitimate)" {
	run _run_guard "$(_payload_bash '')"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}
