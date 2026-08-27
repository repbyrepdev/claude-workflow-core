#!/bin/bash
set -uo pipefail
# event: PostToolUse
# enforcement: inform
# auto-register: true
#
# (#2554) The staleness CLOCK for the task-queue nudges. Every tool call ticks
# it; a todo-tool call resets it and snapshots what is open.
#
# This hook DECIDES NOTHING and BLOCKS NOTHING. It only records, so that
# hooks/next-task-stop-nudge.sh and the staleness nudge (#2555) can ask "how
# long has this item sat untouched" without each keeping its own count and
# disagreeing about the answer.
#
# FAILS OPEN, everywhere. It runs after EVERY tool call, so a fault here would
# be a fault in every action the operator takes — and the thing it protects is
# a reminder, not an invariant. An unreadable payload, an absent jq, a
# read-only state dir: all exit 0 silently. That is a deliberate asymmetry
# with the gates in this repo, which fail CLOSED because what they protect is
# correctness. Detection fails open; ENFORCEMENT (via hook-ack, in #2555)
# fails closed.
#
# Toggle: TASK_NUDGE_SKIP=1 disables the whole task-nudge family.

[ "${TASK_NUDGE_SKIP:-0}" = "1" ] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

# Read stdin ONCE. A second read gets nothing, and a hook that consumed its
# own payload then behaved as though it were empty would be indistinguishable
# from a genuinely empty one.
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# Cheap early-exit funnel, following hooks/phase1-post-agent-nudge.sh: pull
# only the three fields this hook uses, and leave on any parse failure.
TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0

_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
_TQ_LIB="$_HOOK_DIR/../_lib/task-queue.sh"
[ -r "$_TQ_LIB" ] || exit 0
# shellcheck source=../_lib/task-queue.sh
source "$_TQ_LIB" 2>/dev/null || exit 0

_prev=$(task_queue_state_read "$SESSION_ID")

if printf '%s' "$TOOL_NAME" | grep -qE "$TASK_QUEUE_TOOL_RE"; then
	# A todo-tool call IS the status update. Snapshot what is open and put the
	# clock back to zero — the counter measures calls since the operator last
	# said anything about the queue, so the saying is the reset.
	TOOL_INPUT=$(printf '%s' "$PAYLOAD" | jq -c '.tool_input // {}' 2>/dev/null) || exit 0
	_items=$(task_queue_from_tool_input "$TOOL_INPUT") || exit 0
	_ids=$(task_queue_open_ids "$_items") || _ids=""
	_state=$(jq -nc --arg ids "$_ids" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson items "$_items" \
		'{open_ids: $ids, calls_since_update: 0, updated_at: $ts, items: $items, nudged_for: ""}' 2>/dev/null) || exit 0
	task_queue_state_write "$SESSION_ID" "$_state" || exit 0
	exit 0
fi

# Any other tool: tick the clock. Nothing to do when the queue has never been
# seen — a counter with no queue behind it would make the first todo call look
# instantly stale.
_prev_ids=$(printf '%s' "$_prev" | jq -r '.open_ids // ""' 2>/dev/null) || exit 0
[ -n "$_prev_ids" ] || exit 0

_n=$(printf '%s' "$_prev" | jq -r '.calls_since_update // 0' 2>/dev/null) || exit 0
[[ $_n =~ ^[0-9]+$ ]] || _n=0
_next=$((_n + 1))

_state=$(printf '%s' "$_prev" | jq -c --argjson n "$_next" '.calls_since_update = $n' 2>/dev/null) || exit 0
task_queue_state_write "$SESSION_ID" "$_state" || exit 0
exit 0
