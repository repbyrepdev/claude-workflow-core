#!/usr/bin/env bats
# covers: hooks/ship-cycle-guard.sh
#
# Tests for the ship-pr-cycle mechanical-enforcement guard (#82).

# shellcheck disable=SC2030,SC2031
# SHA set in setup() + referenced in @test bodies — bats runs each
# test in a subshell that inherits setup() state. shellcheck doesn't
# fully model bats semantics; the cross-subshell-modification info
# findings are noise here.

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
	mkdir -p .claude/.session-state/ship-cycle
	cat >".claude/.session-state/ship-cycle/$SHA.json" <<EOF
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
	echo '{"stage":"phase1","branch":"fix/v0.9.5/bug"}' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "passes through when no ship-pr-cycle state file" {
	(cd "$TEST_TMP" && rm -rf .claude/.session-state/ship-cycle)
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
}

@test "state JSON with empty .stage denies (corrupt — CR PR #99 r1)" {
	# CR finding: '{"stage": ""}' or {} or {"stage": null} previously
	# slipped through (jq -r '.stage // ""' yielded ''), making the
	# guard a no-op on missing-stage manifests. Now fail-closed.
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo '{"stage":""}' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"corrupt JSON"* ]]
}

@test "state JSON without .stage field denies (corrupt — CR PR #99 r1)" {
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo '{"branch":"feat/v/x"}' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"corrupt JSON"* ]]
}

@test "corrupt state JSON denies (fail-closed)" {
	# CR-CLI r3 major: partial-write race on state file shouldn't
	# silently disable the guard. Corrupt jq → deny.
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo 'not valid {{ json' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	run _run_guard "$(_payload_bash 'gh pr merge 91')"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"corrupt JSON"* ]]
}

@test "passes through when stage=merged" {
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	echo '{"stage":"merged"}' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
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

@test "allows pr-review-toolkit Agent when directive sentinel has valid nonce (#92)" {
	# v0.10.0 (#92): nonce-validated sentinel. Sentinel content line 1
	# must match state JSON's phase1_directive_nonce.
	nonce="11111111-2222-3333-4444-555555555555"
	jq --arg n "$nonce" '. + {phase1_directive_nonce: $n}' \
		"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json" >"$TEST_TMP/state.json.tmp"
	mv "$TEST_TMP/state.json.tmp" "$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	printf '%s\ndirective text\n' "$nonce" >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.phase1-directive.txt"
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

# --- v0.10.0 (#92) hardening: tokenized command parsing --------

@test 'tokenized: \gh pr merge 91 (escape bypass) denied (#92)' {
	# Phase 1 security-review bypass #1: backslash-escape on command name.
	# Pre-#92 regex would not match because `\g` isn't preceded by space.
	# Post-#92 shlex.split treats `\g` as literal `g`, basename → `gh`.
	payload=$(_payload_bash '\gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"gh pr merge"* ]]
}

@test "tokenized: /usr/bin/gh pr merge 91 (abs-path bypass) denied (#92)" {
	# Phase 1 security-review bypass #2: absolute-path prefix.
	# Pre-#92 regex would not match because gh isn't word-anchored after `/`.
	# Post-#92 basename(/usr/bin/gh) → `gh`.
	payload=$(_payload_bash '/usr/bin/gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "tokenized: 'gh' pr merge 91 (quoted command bypass) denied (#92)" {
	# Phase 1 security-review bypass #3: quoted command name.
	# Pre-#92 regex would not match because gh is preceded by quote.
	# Post-#92 shlex.split unquotes, basename → `gh`.
	payload=$(_payload_bash "'gh' pr merge 91")
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "tokenized: GH_TOKEN=x gh pr merge 91 (env-prefix) denied (#92)" {
	# Env-assignment prefix is shell-standard. shlex.split treats it as
	# a single token containing `=`; we strip such tokens until we find
	# the real command. basename of next token → `gh`.
	payload=$(_payload_bash 'GH_TOKEN=x gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "tokenized: FOO=1 BAR=2 gh pr merge 91 (multiple env-prefix) denied (#92)" {
	# Multiple env-vars stripped before basename check.
	payload=$(_payload_bash 'FOO=1 BAR=2 gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "tokenized: legitimate gh pr view 91 passes (no merge subcommand)" {
	# Only `gh pr merge` is denied, not all `gh pr *` invocations.
	payload=$(_payload_bash 'gh pr view 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test 'tokenized: "coderabbit" review (quoted Phase 2 bypass) denied (#92)' {
	payload=$(_payload_bash '"coderabbit" review')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"coderabbit review"* ]]
}

@test "tokenized: gh PR merge 91 (case-variant) does NOT match (intentional)" {
	# shlex preserves case; we don't lowercase. `gh PR merge` is not
	# a real subcommand anyway (gh CLI is case-sensitive).
	payload=$(_payload_bash 'gh PR merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "tokenized: unbalanced quote fails closed (#92)" {
	# shlex.split refuses on unbalanced quotes — we can't safely
	# reason about what the shell would actually run, so deny.
	payload=$(_payload_bash 'gh pr merge "91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"tokenization failed"* ]]
}

# --- v0.10.0 (#92) nonce-validated sentinel ---------------------

@test "Agent: pr-review-toolkit denied when sentinel missing (#92)" {
	# Baseline: no sentinel → still denied (unchanged from #82).
	payload=$(_payload_agent 'pr-review-toolkit:code-reviewer')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "Agent: touch-bypass denied (empty sentinel, no nonce match) (#92)" {
	# Pre-#92: touch sentinel → unblocks Agent.
	# Post-#92: empty sentinel has no nonce on line 1 → denied.
	touch "$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.phase1-directive.txt"
	payload=$(_payload_agent 'pr-review-toolkit:code-reviewer')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"sentinel empty"* ]] || [[ $output == *"nonce mismatch"* ]] || [[ $output == *"no phase1_directive_nonce"* ]]
}

@test "Agent: valid nonce sentinel passes (#92)" {
	# Orchestrator-emitted nonce path: state JSON has nonce + sentinel
	# line 1 matches.
	nonce="00000000-1111-2222-3333-444444444444"
	jq --arg n "$nonce" '. + {phase1_directive_nonce: $n}' \
		"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json" >"$TEST_TMP/state.json.tmp"
	mv "$TEST_TMP/state.json.tmp" "$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	printf '%s\nfire phase 1 directive\n' "$nonce" >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.phase1-directive.txt"
	payload=$(_payload_agent 'pr-review-toolkit:code-reviewer')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "Agent: nonce mismatch denied (#92)" {
	# Sentinel has a nonce but state JSON has a different one — likely
	# stale sentinel from a prior round or touch-bypass with guessed
	# nonce. Deny.
	jq '. + {phase1_directive_nonce: "real-nonce-aaaa"}' \
		"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json" >"$TEST_TMP/state.json.tmp"
	mv "$TEST_TMP/state.json.tmp" "$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.json"
	printf 'fake-nonce-bbbb\ndirective\n' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.phase1-directive.txt"
	payload=$(_payload_agent 'pr-review-toolkit:code-reviewer')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"nonce mismatch"* ]]
}

@test "Agent: state JSON without phase1_directive_nonce denied (#92)" {
	# Sentinel exists with a nonce but state JSON has none — orchestrator
	# emit path didn't run (or write failed). Deny.
	printf 'some-nonce\ndirective\n' >"$TEST_TMP/.claude/.session-state/ship-cycle/$SHA.phase1-directive.txt"
	# state JSON still has the default {"stage":"phase1",...} — no nonce field.
	payload=$(_payload_agent 'pr-review-toolkit:code-reviewer')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"no phase1_directive_nonce"* ]] || [[ $output == *"phase1_directive_nonce"* ]]
}

# --- v0.10.0 (#92) residual-bypass coverage (pinned as accepted) ---

@test "residual: bash -c wrapper bypasses (basename=bash) — pinned residual" {
	# Threat-model documents this as a known residual. Pin behavior:
	# the wrapper passes through because basename(first real command)
	# is the wrapper name, not the inner command.
	payload=$(_payload_bash 'bash -c "gh pr merge 91"')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "residual: eval wrapper bypasses — pinned residual" {
	payload=$(_payload_bash 'eval "gh pr merge 91"')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "residual: xargs wrapper bypasses — pinned residual" {
	payload=$(_payload_bash 'xargs -I_ gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "residual: compound and-chain bypasses — pinned residual" {
	payload=$(_payload_bash 'true && gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "residual: compound semi-chain bypasses — pinned residual" {
	payload=$(_payload_bash 'true; gh pr merge 91')
	run _run_guard "$payload"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}
