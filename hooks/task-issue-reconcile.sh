#!/bin/bash
set -uo pipefail
# event: PostToolUse
# matcher: Bash
# enforcement: inform
# auto-register: true
#
# (#2555) The third drift #2551 records: a commit lands referencing an issue,
# and the task list never moves. The work happened; the list still says it is
# pending, or still says in_progress, or never had an item for it at all.
#
# That gap is not cosmetic. The list is what the next decision is made from —
# what to do next, what is left, whether the epic can close — and a list that
# disagrees with the commit history sends every one of those the wrong way.
#
# WHEN IT FIRES: only after a real `git commit` landed (post_commit_detect_init
# gates that, mirroring hooks/post-commit-template-lint.sh), only when the
# message references an issue, and only when no task item changed status
# around it.
#
# Detection FAILS OPEN. A git or jq glitch exits 0 silently: this runs after
# Bash calls, and what it protects is bookkeeping. Enforcement is the shared
# hook-ack gate's and fails closed.
#
# Toggle: TASK_NUDGE_SKIP=1 disables the task-nudge family.

if [ "${TASK_NUDGE_SKIP:-0}" = "1" ]; then
	# Audited to stderr, not silent: an operator who set this weeks ago and
	# forgot needs to see WHY the nudges stopped. skip-env-approval-gate.sh
	# already gates SETTING it; this is the other half — the standing reminder
	# that it is still set.
	echo "task-issue-reconcile: TASK_NUDGE_SKIP=1 — task nudges disabled by operator toggle" >&2
	exit 0
fi
command -v jq >/dev/null 2>&1 || exit 0

_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 0
_PCD_LIB="$_HOOK_DIR/../_lib/post-commit-detect.sh"
[ -r "$_PCD_LIB" ] || exit 0
# shellcheck source=../_lib/post-commit-detect.sh
source "$_PCD_LIB" 2>/dev/null || exit 0

# post_commit_detect_init READS STDIN ITSELF and exports $PAYLOAD.
#
# So it must be called BEFORE anything else touches stdin. An earlier version
# of this hook did its own `PAYLOAD=$(cat)` first for the session id; the lib
# then read an already-drained stdin, fell back to `{}`, found no command, and
# returned 1 — so this hook exited 0 on every single invocation and could
# never have fired in production. Caught by its own tests, which is the
# argument for writing them against the real call sequence.
#
# Gates on a SUCCESSFUL `git commit` (direct or through the skill wrapper).
# Without it the hook would fire on every Bash call and read whatever HEAD
# happened to be.
post_commit_detect_init || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // ""' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$REPO_ROOT" ] || exit 0

MSG=$(git -C "$REPO_ROOT" log -1 --format='%B' 2>/dev/null) || exit 0
[ -n "$MSG" ] || exit 0

# Same `#[0-9]+` shape pre-commit-hooks/commit-scope-to-issue.sh uses, but
# capturing ALL matches: one commit can close several issues, and reconciling
# only the first would leave the rest silently unreconciled.
ISSUES=$(printf '%s' "$MSG" | grep -oE '#[0-9]+' 2>/dev/null | sort -u | tr '\n' ' ') || ISSUES=""
ISSUES=${ISSUES% }
[ -n "$ISSUES" ] || exit 0

_TQ_LIB="$_HOOK_DIR/../_lib/task-queue.sh"
[ -r "$_TQ_LIB" ] || exit 0
# shellcheck source=../_lib/task-queue.sh
source "$_TQ_LIB" 2>/dev/null || exit 0

_STATE=$(task_queue_state_read "$SESSION_ID")
# Through the lib accessors, not ad hoc jq. Reading `.open_ids` and
# `.ids_at_last_commit` directly here put the state SCHEMA in two files —
# exactly the drift this library exists to prevent, reintroduced one field at
# a time.
_IDS=$(task_queue_state_open_ids "$_STATE") || exit 0

# No queue in this session — nothing to reconcile AGAINST. Firing here would
# demand a task list from an operator who never made one, which is the
# conversational-turn failure in a different costume.
[ -n "$_IDS" ] || exit 0

# THE TEST: did the open set change since the last commit this hook saw?
#
# `open_ids` is a hash of the open items' content, rewritten by every todo
# call. If it is identical to what stood at the previous commit, then between
# those two commits nothing was marked done, added, or re-scoped — while a
# commit referencing an issue landed. That is the drift.
#
# Comparing the SET rather than watching for a specific transition is
# deliberate: an operator may reconcile by completing an item, by adding the
# follow-up they discovered, or by re-scoping. All three move the set, and all
# three are reconciliation. Only doing nothing leaves it identical.
_LAST_COMMIT_IDS=$(task_queue_state_ids_at_last_commit "$_STATE") || _LAST_COMMIT_IDS=""

# Record the current set for the NEXT commit regardless of what is decided
# below — otherwise the first commit of a session, which has nothing to
# compare against, would leave the baseline unset forever and never fire.
_NEW_STATE=$(task_queue_state_set_ids_at_last_commit "$_STATE" "$_IDS") || exit 0
# A failed baseline write means the NEXT commit compares against a stale value
# and can report drift that did not happen — worth saying, though never worth
# failing a tool call over.
task_queue_state_write "$SESSION_ID" "$_NEW_STATE" 2>/dev/null ||
	echo "task-issue-reconcile: WARN: could not record the commit baseline; the next commit may compare against a stale open-item set" >&2

# First commit of the session: nothing to compare, so nothing to claim.
[ -n "$_LAST_COMMIT_IDS" ] || exit 0
[ "$_LAST_COMMIT_IDS" = "$_IDS" ] || exit 0

_ACK_LIB="$_HOOK_DIR/../_lib/hook-ack.sh"
[ -r "$_ACK_LIB" ] || exit 0
# shellcheck source=../_lib/hook-ack.sh
source "$_ACK_LIB" 2>/dev/null || exit 0

_SUBJ=$(printf '%s' "$MSG" | head -1 | head -c 120)
_BODY="A commit referencing $ISSUES landed, and the task list did not move.

    $_SUBJ

The open items are byte-identical to what they were at the previous commit:
nothing was marked done, nothing was added, nothing was re-scoped. So either
the work that just landed is not represented in the list, or it is and the
list has not caught up.

This is the drift #2551 records. The list is what the next decision is made
from — what to do next, what is left, whether the epic can close — and a list
that disagrees with the commit history sends all of those the wrong way.

RECONCILE by doing ONE of:
  - mark the item for $ISSUES completed, if this commit finished it
  - add an item, if this commit was work the list never mentioned
  - re-scope the existing item, if the commit changed what remains

If this commit genuinely does not correspond to a task — a typo fix, a
revert — updating nothing is the right answer and this nudge is noise. It
fires once per commit, not repeatedly.

Operator toggle: TASK_NUDGE_SKIP=1 disables the task-nudge family."

_DIAG=$(hook_ack_diagnostic_write "task-issue-reconcile" "commit-no-task-transition" "$_BODY" 2>/dev/null) || _DIAG=""
# The append is what ENFORCES. Swallowing its failure meant the drift was
# detected and then silently dropped.
hook_ack_append "task-issue-reconcile" "commit-no-task-transition" "$_DIAG" 2>/dev/null ||
	echo "task-issue-reconcile: WARN: could not register the drift sentinel — nothing will block on it" >&2
exit 0
