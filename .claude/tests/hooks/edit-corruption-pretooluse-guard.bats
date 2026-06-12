#!/usr/bin/env bats
# covers: hooks/edit-corruption-pretooluse-guard.sh
#
# #2292: PreToolUse guard (matcher Write|Edit|MultiEdit) that refuses content
# carrying the Edit-tool corruption signature BEFORE the bytes reach disk —
# those bytes trip the Anthropic content filter on later API calls.
# Fail-closed on unparseable payloads; COMMIT_CORRUPT_GUARD_SKIP=1 bypasses
# WITH an audit record; the guard's own test/source files are whitelisted.
# bash-3.2 compatible (no mapfile).
#
# Isolation: the hook derives repo_root from BASH_SOURCE/../.. (NOT cwd), so we
# mirror the layout in the sandbox via symlinks — the bypass audit then writes
# into the sandbox, and ../_lib/hook-deny.sh resolves to the REAL deny helper
# (exercising the real permissionDecision:deny path, not the inline fallback).

setup() {
	REAL_SCRIPT=$(cd "${BATS_TEST_DIRNAME}/../../../hooks" && pwd)/edit-corruption-pretooluse-guard.sh
	REAL_LIB=$(cd "${BATS_TEST_DIRNAME}/../../../_lib" && pwd)/hook-deny.sh
	[ -f "$REAL_SCRIPT" ]
	[ -f "$REAL_LIB" ]
	TEST_TMP=$(cd "$(mktemp -d -t edit-corrupt-guard.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Mirror the CONSUMER layout (.claude/hooks + .claude/_lib): the hook computes
	# repo_root as dirname/../.. , which only lands on the repo root when the hook
	# sits under .claude/hooks/ — so the bypass audit writes inside the sandbox.
	mkdir -p "$TEST_TMP/.claude/hooks" "$TEST_TMP/.claude/_lib"
	ln -s "$REAL_SCRIPT" "$TEST_TMP/.claude/hooks/guard.sh"
	ln -s "$REAL_LIB" "$TEST_TMP/.claude/_lib/hook-deny.sh"
	SCRIPT="$TEST_TMP/.claude/hooks/guard.sh"
	# Assemble the corruption signature from parts so this tracked test file
	# never itself contains the literal bytes the guard exists to keep OUT of
	# files (they trip the Anthropic content filter on later API round-trips).
	_gt=">>" _qq='""'
	CORRUPT="before ${_gt}${_qq} after"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */edit-corrupt-guard.* ]] && rm -rf "$TEST_TMP"
}

# Write/Edit payload: $1=tool_name $2=content/new_string $3=file_path
_payload() {
	jq -nc --arg t "$1" --arg c "$2" --arg f "${3:-/tmp/x.sh}" \
		'{tool_name:$t, tool_input:{content:$c, new_string:$c, file_path:$f}}'
}

# MultiEdit payload with a single edit: $1=new_string $2=file_path
_payload_multiedit() {
	jq -nc --arg c "$1" --arg f "${2:-/tmp/x.sh}" \
		'{tool_name:"MultiEdit", tool_input:{file_path:$f, edits:[{new_string:$c}]}}'
}

# Run the symlinked real hook. $1=payload, $2..=env assignments. stderr merged.
_run_guard() {
	local payload=$1
	shift
	(printf '%s' "$payload" | env "$@" bash "$SCRIPT" 2>&1)
}

@test "real hook script exists and is executable" {
	[ -x "$REAL_SCRIPT" ]
}

@test "clean Write content → allowed (exit 0, no deny)" {
	run _run_guard "$(_payload Write 'echo hello world')"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "Write content with the corruption signature → DENIED" {
	run _run_guard "$(_payload Write "$CORRUPT")"
	# Real hook_deny: deny-JSON on stdout + exit 0; assert the decision AND that
	# the reason names the corruption signature (not just any deny).
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
	[[ $output == *corruption* ]]
}

@test "Edit new_string with the signature → DENIED" {
	run _run_guard "$(_payload Edit "$CORRUPT")"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
	[[ $output == *corruption* ]]
}

@test "MultiEdit edits[].new_string with the signature → DENIED" {
	run _run_guard "$(_payload_multiedit "$CORRUPT")"
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
	[[ $output == *corruption* ]]
}

@test "non-Write/Edit/MultiEdit tool → allowed (exit 0)" {
	# The case-default short-circuits any other tool name.
	run _run_guard "$(_payload Bash "$CORRUPT")"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "empty content → allowed (exit 0, e.g. truncate-write)" {
	run _run_guard "$(_payload Write '')"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}

@test "unparseable (non-JSON) stdin → fail-closed deny" {
	run _run_guard 'this is not json {'
	# A malformed payload must NOT fail open: the tool_name parse fails and the
	# hook denies. Assert the decision AND the fail-closed reason.
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
	[[ $output == *"failing closed"* ]]
}

@test "COMMIT_CORRUPT_GUARD_SKIP=1 → bypass + audit log written" {
	run _run_guard "$(_payload Write "$CORRUPT")" COMMIT_CORRUPT_GUARD_SKIP=1
	[ "$status" -eq 0 ]
	# Bypass announces itself AND records the audit (jq present → audit-logged).
	[[ $output == *bypassing* ]]
	[[ $output == *audit-logged* ]]
	[ -f "$TEST_TMP/.claude/logs/edit-corrupt-guard-skip.jsonl" ]
}

@test "the guard's own whitelisted test path → allowed despite the signature" {
	# The guard's own bats/source files intentionally contain the pattern, so
	# an exact-path match must short-circuit BEFORE detection (else this very
	# file could never be written).
	run _run_guard "$(_payload Write "$CORRUPT" '.claude/tests/hooks/edit-corruption-pretooluse-guard.bats')"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
}
