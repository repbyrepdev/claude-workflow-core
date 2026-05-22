#!/bin/bash
set -u
# event: PreToolUse
# matcher: Bash|Edit|Write|NotebookEdit
# PreToolUse hook — the gold-standard "seamless context injection" piece.
# Reads .claude/hooks/memory-guard.rules.json; for each rule matching the
# current tool invocation, emits a system-reminder warning via stdout JSON
# so Claude sees the memory rule AT THE MOMENT it's about to break it.
#
# Memory is currently passive (loaded once at session-start). This makes it
# active — a firewall, not a reference doc.
#
# Part of v3.19 meta-learning infrastructure (#236).
#
# Contract:
# - Exit 0 always (advisory rules); BLOCKING rules emit deny-JSON + exit 0
# - <100ms runtime (PreToolUse runs on EVERY tool call)
# - Strict matching — false positives here pollute every tool call
#
# v4.27 (#632): rules can set `"block": true` to convert from advisory
# (additionalContext system-reminder) to BLOCKING (permissionDecision=deny).
# A blocking rule short-circuits the hook — exit immediately with deny-JSON
# rather than continuing to match additional rules. Used by the rm-rf-variable
# rule to prevent destructive expansions. Override: set the env var named in
# `block_override_env` (defaults to MEMORY_GUARD_BLOCK_SKIP=1) for emergency.

# Telemetry: log hook run at exit (from _lib.sh)
_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

RULES_FILE=".claude/hooks/memory-guard.rules.json"
[ -f "$RULES_FILE" ] || exit 0

input=$(cat 2>/dev/null || echo '{}')
tool_name=$(echo "$input" | jq -r '.tool_name // empty')
[ -z "$tool_name" ] && exit 0

# Build a matching surface per tool type
case "$tool_name" in
Bash)
	surface=$(echo "$input" | jq -r '.tool_input.command // empty')
	;;
Edit | Write | NotebookEdit)
	file_path=$(echo "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
	new_str=$(echo "$input" | jq -r '.tool_input.new_string // .tool_input.content // empty')
	surface="file=$file_path"
	content="$new_str"
	;;
*)
	surface=$(echo "$input" | jq -r '.tool_input // empty' | head -c 1000)
	;;
esac

# Iterate rules, collect matches
matches=""
while IFS= read -r rule; do
	rule_tool=$(echo "$rule" | jq -r '.tool')
	rule_pattern=$(echo "$rule" | jq -r '.pattern')
	rule_target=$(echo "$rule" | jq -r '.pattern_target // empty')
	rule_msg=$(echo "$rule" | jq -r '.message')
	rule_id=$(echo "$rule" | jq -r '.id')
	# v4.27 (#632): blocking flag. When true, matched rule short-circuits
	# the hook with permissionDecision=deny instead of advisory injection.
	rule_block=$(echo "$rule" | jq -r '.block // false')

	# Tool filter — rule_tool is pipe-delimited alternation (e.g. "Edit|Write")
	echo "$tool_name" | grep -Ew "$rule_tool" >/dev/null 2>&1 || continue

	# Select matching surface based on target
	match_against="$surface"
	if [ "$rule_target" = "file_path" ]; then
		match_against="${file_path:-}"
	elif [ "$rule_target" = "new_string|content" ]; then
		match_against="${content:-}"
	fi
	[ -z "$match_against" ] && continue

	# Pattern match via perl — portable (macOS BSD grep lacks -P)
	PCRE="$rule_pattern" TEXT="$match_against" perl -e 'exit(!($ENV{TEXT} =~ /$ENV{PCRE}/s))' 2>/dev/null || continue

	# v4.27 (#632): blocking rule — emit deny-JSON + exit. Override via
	# MEMORY_GUARD_BLOCK_SKIP=1 (audit-logged to stderr).
	if [ "$rule_block" = "true" ]; then
		if [ "${MEMORY_GUARD_BLOCK_SKIP:-0}" = "1" ]; then
			echo "memory-guard: rule '$rule_id' would block but MEMORY_GUARD_BLOCK_SKIP=1 — bypassing" >&2
		else
			deny_reason="🛑 BLOCKED by memory-guard rule [$rule_id]:

$rule_msg

Override (audit-logged): MEMORY_GUARD_BLOCK_SKIP=1 <your-command>"
			deny_json=$(jq -nc --arg r "$deny_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
				echo "memory-guard: jq failed emitting deny — exit 2 fallback" >&2
				exit 2
			}
			printf '%s\n' "$deny_json"
			exit 0
		fi
	fi

	# v3.21 #270: cite rule ID so operator can trace false positives + maintain
	# rules. Without this, all injections blur together.
	labeled_msg="[rule: $rule_id] $rule_msg"
	if [ -z "$matches" ]; then
		matches="$labeled_msg"
	else
		matches="$matches

$labeled_msg"
	fi
done < <(jq -c '.rules[]' "$RULES_FILE")

[ -z "$matches" ] && exit 0

# Emit system-reminder injection via hookSpecificOutput.additionalContext
jq -nc \
	--arg ctx "memory-guard matched:

$matches" \
	'{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'

exit 0
