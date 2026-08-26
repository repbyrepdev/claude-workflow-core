#!/usr/bin/env bats
# covers: hooks/no-handoff-to-user.sh
#
# #2293: Stop hook that scans the LAST assistant message in the transcript for
# hand-off-to-user language ("you need to run", "run this yourself", "in your
# terminal", "manually install") and, on a match, injects an additionalContext
# directive telling Claude to run the command itself. Only the last assistant
# message is scanned; multi-line messages stay intact (jq -rs slurp). Missing
# or empty transcripts pass silently. bash-3.2 compatible (no mapfile).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/no-handoff-to-user.sh"
	[ -f "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t no-handoff.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	TRANSCRIPT="$TEST_TMP/transcript.jsonl"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */no-handoff.* ]] && rm -rf "$TEST_TMP"
}

# Write a transcript: each arg is one assistant text message, in order.
_write_transcript() {
	: >"$TRANSCRIPT"
	local m
	for m in "$@"; do
		jq -nc --arg t "$m" \
			'{type:"assistant",message:{content:[{type:"text",text:$t}]}}' \
			>>"$TRANSCRIPT"
	done
}

# Run the Stop hook with a given transcript_path (stderr merged).
_run() {
	local payload
	payload=$(jq -nc --arg tp "$1" '{transcript_path:$tp}')
	(cd "$TEST_TMP" && printf '%s' "$payload" | bash "$SCRIPT" 2>&1)
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "empty transcript_path → silent pass (exit 0)" {
	run _run ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "transcript_path points at a missing file → silent pass" {
	run _run "$TEST_TMP/does-not-exist.jsonl"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "clean last message (no hand-off) → no directive" {
	_write_transcript "Done — all tests pass and the branch is ready."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test '"you need to run" → hand-off directive injected' {
	_write_transcript "You need to run npm install before the build will work."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *additionalContext* ]] || return 1
	[[ $output == *"hand-off detected"* ]]
}

@test '"run this command yourself" → hand-off directive' {
	_write_transcript "Please run this command yourself: sudo systemctl restart x."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"hand-off detected"* ]]
}

@test '"in your terminal" phrase → hand-off directive' {
	_write_transcript "Paste the following in your terminal to finish setup."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"hand-off detected"* ]]
}

@test '"manually install" phrase → hand-off directive' {
	_write_transcript "You will need to manually install the age binary first."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"hand-off detected"* ]]
}

@test "hand-off only in an EARLIER message → no directive (scans last only)" {
	# The hand-off is in the first message; the last is clean. Proves only the
	# final assistant message is scanned (not the whole transcript).
	_write_transcript "You need to run the migration." "All set, deployed and verified."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "multi-line last message with hand-off on a later line → detected" {
	# jq -rs slurps the whole message; a hand-off below the first line must
	# still match (the v4.15.EE multi-line-intact fix).
	_write_transcript "Here is the summary of changes.
The config looks good.
You should install ripgrep to speed up the search."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"hand-off detected"* ]]
}

# --- round-1 phase1 coverage gaps (pr-test-analyzer) ---

@test "interleaved non-assistant entries → last ASSISTANT drives selection" {
	# A user message sits between an earlier hand-off and a clean final
	# assistant message. The jq filter selects the last ASSISTANT (not the last
	# transcript line), so the clean final message wins → no directive. Proves
	# the type filter, not just last-line slicing.
	{
		jq -nc '{type:"assistant",message:{content:[{type:"text",text:"You need to run the migration."}]}}'
		jq -nc '{type:"user",message:{content:[{type:"text",text:"ok thanks"}]}}'
		jq -nc '{type:"assistant",message:{content:[{type:"text",text:"All set, deployed and verified."}]}}'
	} >"$TRANSCRIPT"
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test '"execute the script yourself" → hand-off directive (explicit pattern)' {
	# Hits the (run|execute) (this|that|the) (command|script) (yourself|manually)
	# branch WITHOUT a please/you-need preamble, so it can only match that
	# pattern — covering the second matcher branch in isolation.
	_write_transcript "To finish, execute the script yourself and report back."
	run _run "$TRANSCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"hand-off detected"* ]]
}
