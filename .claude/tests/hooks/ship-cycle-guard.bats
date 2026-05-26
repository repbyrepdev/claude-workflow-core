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
	# Use jq to safely encode the command — printf '%s' would break on
	# commands containing quotes, backslashes, or control chars (CR-CLI
	# r3 finding).
	local cmd=$1
	jq -nc --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}'
}

_payload_agent() {
	local subagent=$1
	jq -nc --arg s "$subagent" '{tool_name:"Agent",tool_input:{subagent_type:$s}}'
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
	(cd "$TEST_TMP" && git checkout -q -b somebranch)
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
}

@test "fix/* branch activates the guard (parity with feat/chore)" {
	(cd "$TEST_TMP" && git checkout -q -b fix/v0.9.5/bug)
	# Re-create state file for the new branch's HEAD
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo '{"stage":"phase1","branch":"fix/v0.9.5/bug"}' >"$TEST_TMP/.claude/.session-state/ship-pr-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "passes through when no ship-pr-cycle state file" {
	(cd "$TEST_TMP" && rm -rf .claude/.session-state/ship-pr-cycle)
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
}

@test "corrupt state JSON denies (fail-closed)" {
	# CR-CLI r3 major: partial-write race on state file shouldn't
	# silently disable the guard. Corrupt jq → deny.
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo 'not valid {{ json' >"$TEST_TMP/.claude/.session-state/ship-pr-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"corrupt JSON"* ]]
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
	# Use per-call env to avoid SC2030/SC2031 (bats @test subshell
	# scope makes export-then-run-then-unset shellcheck-noisy).
	payload=$(_payload_bash 'gh pr merge 91')
	run bash -c "cd '$TEST_TMP' && export SKILL_WRAPPER=1 && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "SHIP_PR_CYCLE_BYPASS=1 env bypasses + emits audit log" {
	payload=$(_payload_bash 'gh pr merge 91')
	run bash -c "cd '$TEST_TMP' && export SHIP_PR_CYCLE_BYPASS=1 && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
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

@test "SHIP_PR_CYCLE_BYPASS=1 at command END does NOT bypass (anchored regex)" {
	# Security-review finding: prior regex matched the token anywhere.
	# Anchored regex must reject the suffix-positioned form.
	run _run_guard "$(_payload_bash 'gh pr merge 91 SHIP_PR_CYCLE_BYPASS=1')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "SHIP_PR_CYCLE_BYPASS=1 mid-command does NOT bypass (anchored regex)" {
	run _run_guard "$(_payload_bash 'gh pr merge SHIP_PR_CYCLE_BYPASS=1 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "FOO_SHIP_PR_CYCLE_BYPASS=1 (different var) does NOT bypass" {
	# Word-boundary protection — only the exact variable name bypasses.
	run _run_guard "$(_payload_bash 'FOO_SHIP_PR_CYCLE_BYPASS=1 gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "SKILL_WRAPPER=1 bypass emits audit log line" {
	# Silent-failure-hunter finding: SKILL_WRAPPER was silently
	# passing through; leaked env from stale shell could disable
	# enforcement undetectably. Now audit-logged.
	payload=$(_payload_bash 'gh pr merge 91')
	run bash -c "cd '$TEST_TMP' && export SKILL_WRAPPER=1 && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
	[[ $output == *"SKILL_WRAPPER=1"* ]]
	[[ $output == *"passing through"* ]]
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
