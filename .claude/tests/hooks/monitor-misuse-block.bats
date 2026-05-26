#!/usr/bin/env bats
# covers: hooks/monitor-misuse-block.sh
#
# Tests for the Monitor-misuse PreToolUse hook (#80). Verifies that
# one-shot `until <cond>; do ...; sleep N; done` polling is denied,
# legitimate streams pass, multi-line forms still match, bypass env
# is honored with an actual audit-log file written.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/monitor-misuse-block.sh"
	TEST_TMP=$(cd "$(mktemp -d -t mon-misuse.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Real git repo so the bypass audit-log path resolves
	(
		cd "$TEST_TMP" || exit 1
		git init -q
	)
}

teardown() {
	# shellcheck disable=SC2164  # `cd /tmp` essentially never fails;
	# masking with || true silently swallowed errors (CR-CLI r1).
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */mon-misuse.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: build payload via jq (safe for any input), pipe to hook via
# stdin in a subshell. Avoids nested-quoting fragility.
_run_with_cmd() {
	local cmd=$1
	(cd "$TEST_TMP" && jq -nc --arg c "$cmd" '{tool_name:"Monitor",tool_input:{command:$c}}' | bash "$SCRIPT" 2>&1)
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

# --- anti-pattern blocked ---------------------------------------

@test "blocks 'until grep -q complete; do sleep 5; done'" {
	run _run_with_cmd 'until grep -q complete .output; do sleep 5; done'
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"run_in_background"* ]]
}

@test "blocks 'until [ -f flag ]; do sleep 2; done' (test-bracket variant)" {
	run _run_with_cmd 'until [ -f /tmp/done.flag ]; do sleep 2; done'
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "blocks until-loop with extra statements between do and sleep" {
	# Adjacency-free: `do; echo waiting; sleep 5; done` (sleep no
	# longer needs to be immediately after `do`).
	run _run_with_cmd 'until grep -q complete .output; do echo polling; sleep 5; done'
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "blocks multi-line until-block (flattened-newline regex)" {
	# Real operators paste multi-line forms; the hook flattens
	# newlines to spaces before matching.
	cmd="until grep -q complete .output
do
  sleep 5
done"
	run _run_with_cmd "$cmd"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

# --- legitimate forms pass --------------------------------------

@test "passes 'tail -f' (continuous stream)" {
	run _run_with_cmd 'tail -f /var/log/messages'
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "passes 'inotifywait -m'" {
	run _run_with_cmd 'inotifywait -m /watch/dir'
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "passes 'while true; do curl; sleep; done' (explicit unbounded)" {
	run _run_with_cmd 'while true; do curl -s http://x; sleep 60; done'
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "passes 'until cond; do non-sleep-body; done' (until without sleep — operator's busy-retry)" {
	# Until-loops without sleep are legitimate busy-retries; only
	# the sleep-polling form is the anti-pattern.
	run _run_with_cmd 'until make build; do git pull; done'
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "no false-positive: command with 'until' in echo + unrelated 'for; do sleep'" {
	# code-reviewer/code-simplifier finding: independent greps
	# coupled two unrelated lexical signals. Single-shape regex
	# rejects this pattern.
	run _run_with_cmd "echo 'wait until ready'; for x in 1 2 3; do sleep 1; done"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

# --- bypass + audit log -----------------------------------------

@test "MONITOR_MISUSE_SKIP=1 bypasses + writes audit log with cmd_hash" {
	# silent-failure-hunter finding: prior 'audit logged' message
	# was an empty promise — only stderr emission. Now writes
	# .claude/logs/monitor-misuse-bypass.jsonl with command hash.
	# CR-CLI r3 major: prior fix passed "" so cmd_hash was always "-".
	payload=$(jq -nc --arg c 'until grep -q done; do sleep 5; done' '{tool_name:"Monitor",tool_input:{command:$c}}')
	run bash -c "cd '$TEST_TMP' && export MONITOR_MISUSE_SKIP=1 && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
	[ -f "$TEST_TMP/.claude/logs/monitor-misuse-bypass.jsonl" ]
	got=$(jq -r '.event' "$TEST_TMP/.claude/logs/monitor-misuse-bypass.jsonl")
	[ "$got" = "monitor_misuse_skip" ]
	# cmd_hash MUST be a sha256 (64 hex chars), not the "-" placeholder
	got_hash=$(jq -r '.cmd_hash' "$TEST_TMP/.claude/logs/monitor-misuse-bypass.jsonl")
	[[ $got_hash =~ ^[a-f0-9]{64}$ ]]
}

# --- non-Monitor passthrough ------------------------------------

@test "non-Monitor tool passes through" {
	payload='{"tool_name":"Bash","tool_input":{"command":"until grep complete; do sleep; done"}}'
	run bash -c "cd '$TEST_TMP' && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

# --- fail-closed paths -------------------------------------------

@test "malformed JSON payload denies (fail-closed)" {
	run bash -c "cd '$TEST_TMP' && printf '%s' 'not json' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "malformed tool_input (non-object) denies (fail-closed)" {
	# pr-test-analyzer finding: second jq extraction's fail-closed
	# branch was previously unreachable in tests.
	payload='{"tool_name":"Monitor","tool_input":"not-an-object"}'
	run bash -c "cd '$TEST_TMP' && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "empty command passes through (legitimate)" {
	run _run_with_cmd ''
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "missing tool_input passes through (legitimate, no command to check)" {
	# pr-test-analyzer finding: pin the fail-open semantics on
	# missing optional fields. Hook only acts on present commands.
	payload='{"tool_name":"Monitor"}'
	run bash -c "cd '$TEST_TMP' && printf '%s' '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}
