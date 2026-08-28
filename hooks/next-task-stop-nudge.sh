#!/bin/bash
set -uo pipefail
# event: Stop
# enforcement: inform
# auto-register: true
#
# (#2555) The nudge that closes the gap #2551 names: after finishing one task
# the agent stops and writes a status report instead of starting the next open
# item, and the operator has to say "continue" — sometimes several times.
#
# `hooks/next-step-advisor.sh` already existed and is advisory-only: exit 0,
# PostToolUse, output that scrolls past exactly like the lint failures #2547
# fixed. So this does NOT rely on being read in the terminal. It registers a
# hook-ack sentinel, which makes `stale-state-gate.sh` deny the next tool call
# until the diagnostic is Read. That is the difference between documenting an
# intent and making it happen, which is the whole of epic #2544.
#
# BOUNDED, because a nudge that fires wrongly gets switched off and then
# protects nothing:
#   - never on a conversational turn (queue ABSENT — see the three-state
#     classifier in _lib/task-queue.sh, which exists for this)
#   - never on an empty or all-completed queue
#   - never when the Stop hook is already active (loop guard)
#   - never when the operator has set TASK_NUDGE_SKIP=1
#
# Detection FAILS OPEN throughout: every parse failure exits 0. Enforcement is
# the shared gate's and fails closed. Keeping those apart is what makes a jq
# glitch cost nothing while a real open item still blocks.

if [ "${TASK_NUDGE_SKIP:-0}" = "1" ]; then
	# Audited to stderr, not silent: an operator who set this weeks ago and
	# forgot needs to see WHY the nudges stopped. skip-env-approval-gate.sh
	# already gates SETTING it; this is the other half — the standing reminder
	# that it is still set.
	echo "next-task-stop-nudge: TASK_NUDGE_SKIP=1 — task nudges disabled by operator toggle" >&2
	exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# LOOP GUARD FIRST. A Stop hook that fires during its own Stop handling
# re-enters forever, and the block it registers would be re-registered each
# time — so this precedes every other check.
STOP_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_ACTIVE" = "true" ] && exit 0

TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // ""' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] || exit 0

_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
_TQ_LIB="$_HOOK_DIR/../_lib/task-queue.sh"
_ACK_LIB="$_HOOK_DIR/../_lib/hook-ack.sh"
[ -r "$_TQ_LIB" ] && [ -r "$_ACK_LIB" ] || exit 0
# shellcheck source=../_lib/task-queue.sh
source "$_TQ_LIB" 2>/dev/null || exit 0
# shellcheck source=../_lib/hook-ack.sh
source "$_ACK_LIB" 2>/dev/null || exit 0

ITEMS=$(task_queue_from_transcript "$TRANSCRIPT") || exit 0
STATE=$(task_queue_classify "$ITEMS")

# `absent` and `empty` both exit here, and they are DISTINCT states for a
# reason: absent means no todo tool was ever used, i.e. a conversational turn.
# A two-state answer would collapse them and nudge on every such turn.
[ "$STATE" = "open" ] || exit 0

NEXT=$(task_queue_next_actionable "$ITEMS") || exit 0
[ -n "$NEXT" ] || exit 0

OPEN_N=$(printf '%s' "$ITEMS" | jq -r '
    [ .[]? | select(.status == "pending" or .status == "in_progress") ] | length' 2>/dev/null) || OPEN_N="?"

# The item's own words, truncated. Prose from a payload goes in a diagnostic
# file rather than a shell string, and nothing here interpolates it into a
# command.
NEXT_SHORT=$(printf '%s' "$NEXT" | head -c 160)

BODY="$OPEN_N open task(s) remain. The next actionable one is:

    $NEXT_SHORT

This fired because the turn ended with work still open — the stall #2551
records, where the agent finishes one item, writes a status report, and waits
to be told 'continue'.

WHAT TO DO
  - Start (or resume) the item above, OR
  - Update the task list if it is out of date: mark done what is done, and
    remove or re-scope what is no longer the plan. A list that disagrees with
    reality is what makes this nudge wrong rather than useful.

If the item cannot proceed, mark it blocked — blocked items are skipped by
the selector, so saying so stops this pointing at it again.

Operator toggle: TASK_NUDGE_SKIP=1 disables the task-nudge family."

# ONE call — it both writes the file and echoes its path. Calling it twice
# (once to write, once to capture) would leave two diagnostics for one nudge,
# and the operator would Read one and still be blocked by the other.
_DIAG=$(hook_ack_diagnostic_write "next-task-stop-nudge" "next-open-task" "$BODY" 2>/dev/null) || _DIAG=""
hook_ack_append "next-task-stop-nudge" "next-open-task" "$_DIAG" 2>/dev/null || true

# Also surface it immediately, following hooks/stop-uncommitted-changes.sh.
# The sentinel is what makes it stick; this is what makes it visible NOW.
# Always exit 0 — a Stop hook that exits non-zero is an error, not a nudge.
jq -nc --arg msg "$OPEN_N open task(s) remain — next: $NEXT_SHORT" '{systemMessage: $msg}' 2>/dev/null || true
exit 0
