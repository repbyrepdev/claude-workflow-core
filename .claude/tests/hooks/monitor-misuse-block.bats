#!/usr/bin/env bats
# covers: hooks/monitor-misuse-block.sh
#
# Tests for the Monitor-misuse PreToolUse hook (#80). Verifies that
# one-shot polling patterns are denied + legitimate streams pass.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/monitor-misuse-block.sh"
}

_payload() {
	local cmd=$1
	jq -nc --arg c "$cmd" '{tool_name:"Monitor",tool_input:{command:$c}}'
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

# --- anti-patterns blocked ----------------------------------------

@test "blocks 'until grep -q complete; do sleep; done'" {
	run bash -c "echo '$(_payload 'until grep -q complete .output; do sleep 5; done')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
	[[ $output == *"one-shot"* ]]
	[[ $output == *"run_in_background"* ]]
}

@test "blocks 'until grep -qE pattern; do sleep; done'" {
	run bash -c "echo '$(_payload 'until grep -qE complete; do sleep 5; done')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "blocks 'until [ -f file ]; do sleep; done'" {
	# Variant: test-bracket condition instead of grep
	run bash -c "echo '$(_payload 'until [ -f /tmp/done.flag ]; do sleep 2; done')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

# --- legitimate streams pass --------------------------------------

@test "passes 'tail -f' (continuous stream)" {
	run bash -c "echo '$(_payload 'tail -f /var/log/messages')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "passes 'inotifywait -m'" {
	run bash -c "echo '$(_payload 'inotifywait -m /watch/dir')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

@test "passes 'while true; do ...; done' (explicit unbounded)" {
	run bash -c "echo '$(_payload 'while true; do curl -s http://x; sleep 60; done')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

# --- bypass + non-Monitor passthrough ------------------------------

@test "MONITOR_MISUSE_SKIP=1 bypasses + emits audit log" {
	payload=$(_payload 'until grep -q complete .output; do sleep 5; done')
	run bash -c "export MONITOR_MISUSE_SKIP=1 && echo '$payload' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
	[[ $output == *"audit logged"* ]]
}

@test "non-Monitor tool passes through" {
	# Matcher should restrict to Monitor, but defense-in-depth: even
	# if a Bash payload reaches this hook, it's a no-op.
	run bash -c "echo '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"until grep complete; do sleep; done\"}}' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}

# --- fail-closed on malformed --------------------------------------

@test "malformed JSON payload denies (fail-closed)" {
	run bash -c "echo 'not json' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"permissionDecision\":\"deny"* ]]
}

@test "empty command passes through (legitimate)" {
	run bash -c "echo '$(_payload '')' | bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output != *"permissionDecision\":\"deny"* ]]
}
