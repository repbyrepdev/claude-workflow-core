#!/bin/bash
set -uo pipefail
# event: PostToolUse
# enforcement: inform
# auto-register: true
#
# (#2554) The staleness CLOCK for the task-queue nudges. Every tool call ticks
# it; a todo-tool call resets it and snapshots what is open.
#
# TWO JOBS, and the second was added in #2555 after this header was written:
#
#   1. RECORD (#2554) — tick the clock, snapshot the queue. So that
#      next-task-stop-nudge.sh and the staleness check below can ask "how long
#      has this item sat untouched" without each keeping its own count and
#      disagreeing about the answer.
#   2. NUDGE (#2555) — when an in_progress item passes the staleness
#      threshold, register a hook-ack sentinel, which DOES block the next tool
#      call until it is Read.
#
# The header said "decides nothing and blocks nothing" until phase 3 review
# pointed out that it now does both. Recorded rather than quietly reworded:
# the pairing lives in one file because the clock and the thing that reads it
# must not disagree, and a comment claiming otherwise is how the next reader
# gets the trust boundary wrong.
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

if [ "${TASK_NUDGE_SKIP:-0}" = "1" ]; then
	# Audited to stderr, not silent: an operator who set this weeks ago and
	# forgot needs to see WHY the nudges stopped. skip-env-approval-gate.sh
	# already gates SETTING it; this is the other half — the standing reminder
	# that it is still set.
	echo "task-queue-track: TASK_NUDGE_SKIP=1 — task nudges disabled by operator toggle" >&2
	exit 0
fi

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

# Read ONCE, used by both branches. Review flagged this as a dead read on the
# todo branch, which it was — until that branch started carrying
# ids_at_last_commit forward rather than rebuilding the object from scratch.
# It now has a real use on both paths.
_prev=$(task_queue_state_read "$SESSION_ID")

# Via the library predicate, not a grep fork. This is the hottest path in the
# repo — it runs after every tool call — and the regex was exported raw and
# fed to jq's test() in the lib and to `grep -qE` here, two engines for one
# constant. One place, one engine, no fork.
if task_queue_is_task_tool "$TOOL_NAME"; then
	# A todo-tool call IS the status update. Snapshot what is open and put the
	# clock back to zero — the counter measures calls since the operator last
	# said anything about the queue, so the saying is the reset.
	TOOL_INPUT=$(printf '%s' "$PAYLOAD" | jq -c '.tool_input // {}' 2>/dev/null) || exit 0
	_items=$(task_queue_from_tool_input "$TOOL_INPUT") || exit 0
	_ids=$(task_queue_open_ids "$_items") || _ids=""
	# CARRIES FORWARD ids_at_last_commit. Rebuilding the object from scratch
	# dropped it on every todo call — and that field is the entire basis of
	# task-issue-reconcile.sh's comparison, so a task-list update silently
	# reset its baseline and cost it a commit. Built from _prev rather than
	# jq -n for exactly that reason.
	_state=$(printf '%s' "$_prev" | jq -c --arg ids "$_ids" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson items "$_items" \
		'{ids_at_last_commit: (.ids_at_last_commit // ""),
		  open_ids: $ids, calls_since_update: 0, updated_at: $ts,
		  items: $items, nudged_for: ""}' 2>/dev/null) || exit 0
	# WARNs. This is the write whose failure disables the whole mechanism —
	# no snapshot means every later call finds no queue and exits — while the
	# 7-day prune inside the same function, whose worst outcome is a reset
	# counter, was the one that spoke up. The instrument was on the wrong
	# failure.
	task_queue_state_write "$SESSION_ID" "$_state" ||
		echo "task-queue-track: WARN: could not record the task-queue snapshot; staleness tracking is inactive for this session" >&2
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

# --- staleness (#2555) ----------------------------------------------------
#
# An item marked in_progress that has seen no status update across N tool
# calls is the second half of the stall #2551 records: items sit in_progress
# long after they are done, and work discovered mid-flight never gets added.
# The list stops describing reality, and every later decision is then made
# from fiction.
#
# THRESHOLD, not zero: nudging the moment the counter moves would fire during
# ordinary work on the item itself. 40 tool calls is long enough that the
# operator has plainly moved on without saying so.
_THRESH=${TASK_STALE_AFTER_CALLS:-40}
[[ $_THRESH =~ ^[1-9][0-9]*$ ]] || _THRESH=40
[ "$_next" -ge "$_THRESH" ] || exit 0

# Through the lib accessor, which also excludes BLOCKED items: a bare status
# filter reported an item marked blocked-and-in_progress as stale, nudging the
# operator about work they had already said cannot proceed.
_inprog=$(task_queue_state_stale_candidate "$_state") || exit 0
[ -n "$_inprog" ] || exit 0

# ARM ONCE per item. Without this the nudge re-fires on every subsequent tool
# call — the sentinel thrashes, the operator acknowledges the same directive
# repeatedly, and a mechanism meant to be noticed becomes one to be dismissed.
# Re-arms only when the next status update resets the clock, which also
# rewrites nudged_for to "".
_nudged=$(printf '%s' "$_state" | jq -r '.nudged_for // ""' 2>/dev/null) || _nudged=""
[ "$_nudged" = "$_inprog" ] && exit 0

_ACK_LIB="$_HOOK_DIR/../_lib/hook-ack.sh"
[ -r "$_ACK_LIB" ] || exit 0
# shellcheck source=../_lib/hook-ack.sh
source "$_ACK_LIB" 2>/dev/null || exit 0

_SHORT=$(printf '%s' "$_inprog" | head -c 160)
_BODY="This task has been in_progress for $_next tool calls with no status update:

    $_SHORT

Either it is done and the list has not caught up, or it grew into something
larger than one item. Both are the drift #2551 records — a list that
disagrees with reality, which every later decision is then made from.

RECONCILE by doing ONE of:
  - mark it completed, if it is
  - split it, if the work turned out to be several items
  - update its status or wording, if the scope changed
  - mark it blocked, if it cannot proceed — blocked items are skipped

This fires once per item, not once per tool call. It will not fire again for
this item until the task list is next updated.

Threshold: TASK_STALE_AFTER_CALLS (default 40).
Operator toggle: TASK_NUDGE_SKIP=1 disables the task-nudge family."

# The append is what ENFORCES — the diagnostic file alone is just a file that
# nobody is required to read. Still non-fatal (this must never break a tool
# call), but LOUD, and its result decides whether the item is armed off.
_DIAG=$(hook_ack_diagnostic_write "task-queue-track" "task-stale" "$_BODY" 2>/dev/null) || _DIAG=""

# NEVER register a sentinel with an EMPTY file_path: hook_ack_append accepts
# one, and hook-ack-clear.sh preserves every row whose path is empty, so the
# entry can only be escaped with HOOK_ACK_CLEAR=1. A detection-side write
# failure would then hard-block every subsequent tool call — the most closed
# state the ack system has, produced by the failure of a reminder.
_armed=0
if [ -n "$_DIAG" ]; then
	if hook_ack_append "task-queue-track" "task-stale" "$_DIAG" 2>/dev/null; then
		_armed=1
	else
		echo "task-queue-track: WARN: could not register the task-stale sentinel — the diagnostic is at $_DIAG but nothing will block on it; will retry on the next tool call" >&2
	fi
else
	echo "task-queue-track: WARN: could not write the stale-task diagnostic (is .claude/.session-state writable?) — NOT registering a sentinel, because one with no file path cannot be acknowledged and would block every subsequent tool call" >&2
fi

# ARM OFF ONLY ON SUCCESS. Recording nudged_for unconditionally meant a FAILED
# append still suppressed the item for the rest of the session — the arm-once
# guard reads this field and exits, and it re-arms only when a todo call
# rewrites it. hook_ack_append returns 1 on ordinary contention (a 2s lock
# timeout), so a transient failure became permanent silence: exactly "a nudge
# that reported itself as fired while blocking nothing", which the comment
# above claims to have removed. The WARN made the failure visible; this makes
# it recoverable.
[ "$_armed" = "1" ] || exit 0

_state=$(printf '%s' "$_state" | jq -c --arg n "$_inprog" '.nudged_for = $n' 2>/dev/null) || exit 0
task_queue_state_write "$SESSION_ID" "$_state" ||
	echo "task-queue-track: WARN: could not record the arm-once marker; the stale nudge for this item may repeat on the next tool call" >&2
exit 0
