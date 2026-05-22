#!/bin/bash
set -u
# v4.24-Q (#604) — shared PreToolUse deny helper.
# Emits Claude Code hook JSON `permissionDecision:"deny"` + exits 0
# (the documented reliable blocking path). Falls back to `exit 2` when
# jq is unavailable — strictly better than empty stdout + exit 0.
#
# Usage:
#   source .claude/_lib/hook-deny.sh
#   hook_deny "<prefix>" "<reason text shown to Claude>"
#
# Prefix appears in stderr for operator logs. Reason text is the
# permissionDecisionReason payload — Claude reads it as the block message.
#
# Third consumer after (v4.17.R) skill-bypass-guard.sh local deny(), which
# established the pattern. This lib unifies it across PreToolUse hooks.

hook_deny() {
	local prefix="${1:-hook-deny}" reason="${2:-denied}" json
	echo "$prefix: $reason" >&2
	if ! command -v jq >/dev/null 2>&1; then
		echo "$prefix: jq not found — falling back to exit 2 (unreliable)" >&2
		exit 2
	fi
	if ! json=$(jq -nc --arg r "$reason" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'); then
		echo "$prefix: jq emit failed — falling back to exit 2" >&2
		exit 2
	fi
	echo "$json"
	exit 0
}
