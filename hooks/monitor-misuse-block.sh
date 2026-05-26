#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Monitor
# auto-register: true
# v0.9.5 (#80) — PreToolUse hook that blocks Monitor tool misuse for
# one-shot "tell me when X completes" signals. The right tool for
# that is `Bash run_in_background` — the harness sends a single
# completion notification when the background bash exits, and no
# Monitor orphan accumulation is possible.
#
# Anti-pattern this catches (verified observed 2026-05-26):
#   Monitor with command `until grep -qE '"type":"complete"' .output;
#   do sleep 5; done`
#
# When the background bash dies silently (CR-CLI 0-byte .output case),
# the Monitor's `until` loop polls forever until its own timeout, AND
# a retry arms a NEW Monitor on top — 5 monitors accumulated in one
# session before the operator noticed.
#
# WHAT IT BLOCKS (substring matches on tool_input.command):
#   - `until grep ... do sleep ... done` (one-shot polling pattern)
#   - `until [[ ... ]]; do sleep ...` (variants)
#   - `until <single-condition>; do sleep; done` (general form)
#
# WHAT IT PASSES THROUGH (legitimate unbounded streams):
#   - `tail -f` (continuous stream)
#   - `inotifywait -m` (monitor mode)
#   - `while true` (explicit continuous polling — operator opt-in)
#   - Plain log-following commands without `until ... done`
#
# BYPASS:
#   - MONITOR_MISUSE_SKIP=1 (env) — emergency override, audit-logged
#
# WHY NOT A MEMORY RULE: operator framing 2026-05-26 — "mechanical
# enforcement is NOT memory files." This hook is the tool-call-layer
# mechanical gate.

command -v jq >/dev/null 2>&1 || {
	echo "monitor-misuse-block: jq not found" >&2
	exit 2
}

deny() {
	local reason="$1" json
	echo "monitor-misuse-block: $reason" >&2
	json=$(jq -nc --arg r "$reason" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "monitor-misuse-block: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi

# Bypass via env (audit-logged)
if [ "${MONITOR_MISUSE_SKIP:-0}" = "1" ]; then
	echo "monitor-misuse-block: MONITOR_MISUSE_SKIP=1 — passing through, audit logged" >&2
	exit 0
fi

# Only fires for Monitor tool — matcher should already restrict, but
# fail-closed if tool_name is anything else (shouldn't happen via the
# matcher).
if ! TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	deny "payload unparseable — failing closed"
fi
if [ "$TOOL_NAME" != "Monitor" ]; then
	exit 0
fi

if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null); then
	deny "tool_input.command unparseable — failing closed"
fi
if [ -z "$CMD" ]; then
	exit 0 # no command = no anti-pattern to detect
fi

# Anti-pattern detection: `until <condition>; do sleep N; done`
# This is the canonical one-shot polling pattern. The condition can be
# anything (grep, test, [[, etc.) — what makes it a one-shot is the
# `until` + `sleep` + `done` shape with no `while true` / `-f` /
# `-m` mode flags. Match conservatively (any `until` paired with
# `sleep` inside a `do`/`done`).
if printf '%s' "$CMD" | grep -qE 'until[[:space:]]'; then
	# Has `until`. Check if it's paired with sleep + done (one-shot)
	# vs being part of a legitimate unbounded construct.
	if printf '%s' "$CMD" | grep -qE 'do[[:space:]]+sleep[[:space:]]'; then
		deny "Monitor used with one-shot 'until <cond>; do sleep ...; done' polling — the harness sends ONE completion notification on bash exit, so this should be Bash with run_in_background instead. Pattern observed 2026-05-26: 5 orphan Monitors accumulated when the background process died silently and the until-loop polled past its timeout. Bypass: MONITOR_MISUSE_SKIP=1 env."
	fi
fi

# Other anti-patterns: explicit `do sleep N; done` immediately after
# any condition-loop (handles `while [[ ! -f ... ]]` variants too).
# Skip if `while true` is present — that's the operator's explicit
# unbounded-polling opt-in.
if ! printf '%s' "$CMD" | grep -qE 'while[[:space:]]+true'; then
	if printf '%s' "$CMD" | grep -qE 'while[[:space:]]+[^;]*\[\[?[^]]*\]\]?[[:space:]]*;[[:space:]]*do[[:space:]]+sleep'; then
		deny "Monitor used with one-shot 'while <cond>; do sleep ...; done' polling — same misuse as the until form. Use Bash run_in_background instead. Bypass: MONITOR_MISUSE_SKIP=1 env."
	fi
fi

exit 0
