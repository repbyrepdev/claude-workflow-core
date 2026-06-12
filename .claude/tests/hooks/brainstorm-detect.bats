#!/usr/bin/env bats
# covers: hooks/brainstorm-detect.sh
#
# #2293: UserPromptSubmit hook that detects brainstorm-mode trigger words in
# the user's prompt and injects a <system-reminder> so Claude discusses instead
# of executing. Anchored matching: "brainstorm" / "/brainstorm" / "brainstorm:"
# fire, but "brainstormed" / "brainstormer" must NOT. Non-trigger prompts pass
# silently. bash-3.2 compatible (no mapfile).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/brainstorm-detect.sh"
	[ -f "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t brainstorm-detect.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */brainstorm-detect.* ]] && rm -rf "$TEST_TMP"
}

# Run the hook against a full JSON payload (stderr merged for assertions).
_run_raw() {
	(cd "$TEST_TMP" && printf '%s' "$1" | bash "$SCRIPT" 2>&1)
}

# Convenience: wrap a prompt string under the .prompt key.
_run_prompt() {
	_run_raw "$(jq -nc --arg p "$1" '{prompt:$p}')"
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "empty payload → silent pass (exit 0)" {
	run _run_raw '{}'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "non-trigger prompt → silent pass (no reminder)" {
	run _run_prompt "fix the failing test in auth.py"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "'brainstorm <topic>' → explicit trigger reminder" {
	run _run_prompt "brainstorm the caching layer"
	[ "$status" -eq 0 ]
	[[ $output == *"system-reminder"* ]]
	[[ $output == *"explicit"* ]]
}

@test "'/brainstorm' slash form → explicit trigger" {
	run _run_prompt "/brainstorm"
	[ "$status" -eq 0 ]
	[[ $output == *"system-reminder"* ]]
	[[ $output == *"explicit"* ]]
}

@test "'brainstorm:' colon form → explicit trigger" {
	run _run_prompt "brainstorm: how to shard the table"
	[ "$status" -eq 0 ]
	[[ $output == *"explicit"* ]]
}

@test "\"let's discuss\" → natural trigger" {
	# Uses a natural phrase WITHOUT the word "brainstorm" — otherwise the
	# explicit branch (which matches " brainstorm " anywhere) wins first.
	run _run_prompt "let's discuss the rollout plan"
	[ "$status" -eq 0 ]
	[[ $output == *"system-reminder"* ]]
	[[ $output == *"natural"* ]]
}

@test "leading 'should we' → exploratory trigger" {
	run _run_prompt "should we migrate to postgres or stay on sqlite"
	[ "$status" -eq 0 ]
	[[ $output == *"exploratory"* ]]
}

@test "'brainstormed' does NOT trigger (anchoring guard)" {
	# The trailing-boundary anchor excludes brainstormed/brainstormer; a silent
	# pass proves the over-match guard called out in the hook's comments holds.
	run _run_prompt "we brainstormed this yesterday and shipped it"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "prompt under the .message key → also detected (key fallback)" {
	# The hook reads .prompt // .user_prompt // .message; assert the fallback.
	run _run_raw "$(jq -nc --arg m "brainstorm the API shape" '{message:$m}')"
	[ "$status" -eq 0 ]
	[[ $output == *"explicit"* ]]
}

@test "prompt under the .user_prompt key → also detected (middle fallback)" {
	# Completes the .prompt // .user_prompt // .message chain — the middle key
	# was the one link left unexercised.
	run _run_raw "$(jq -nc --arg u "brainstorm the schema" '{user_prompt:$u}')"
	[ "$status" -eq 0 ]
	[[ $output == *"explicit"* ]]
}
