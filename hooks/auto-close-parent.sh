#!/bin/bash
# v4.5.E (#389): local equivalent of .github/workflows/auto-close-parent.yml.
# When a sub-issue is closed, check if its parent epic has any remaining
# open sub-issues; if none, auto-close the parent.
#
# Usage:
#   .claude/hooks/auto-close-parent.sh <closed-issue-number>
#
# Idempotent — no-ops if parent is already closed or has open sub-issues.
# Recursive — after auto-closing a parent, recurses to check the
# grandparent (handles nested epic hierarchies).
#
# Safety properties (v4.5 Phase 1 hardening):
#   * Every GraphQL read is rc-checked + failure is fail-loud (exit 2).
#     NEVER confuse "API failed" with "no parent" or "no open subs" —
#     that would cause destructive close on a transient network blip.
#   * Numeric results are regex-validated before `-gt` comparison.
#   * Resolves owner/repo from the repo itself (matches project-board-sync.sh
#     convention; no hardcoded repo slug).
#   * Paginates sub-issues up to 100 (warn + skip close on hasNextPage,
#     safe no-op on truncated state — parent stays open, never falsely
#     closed). Upgrade to real pagination if any epic approaches the cap.
set -euo pipefail

# v4.7.F (#413): respect mode toggle via the safe reader.
_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$_REPO_ROOT" ] && [ -x "$_REPO_ROOT/.claude/hooks/_read-actions-mode.sh" ]; then
	if [ "$("$_REPO_ROOT/.claude/hooks/_read-actions-mode.sh")" = "remote" ]; then
		echo "ACTIONS_MODE=remote — skipping auto-close-parent (Actions workflow authoritative)"
		exit 0
	fi
fi

NUMBER="${1:-}"
if [ -z "$NUMBER" ] || ! [ "$NUMBER" -eq "$NUMBER" ] 2>/dev/null; then
	echo "Usage: $0 <closed-issue-number>" >&2
	exit 2
fi

OWNER=$(gh repo view --json owner -q .owner.login) || {
	echo "ERROR: gh repo view failed" >&2
	exit 2
}
REPO=$(gh repo view --json name -q .name) || {
	echo "ERROR: gh repo view failed" >&2
	exit 2
}

# Query the parent issue (if any). Fail LOUD on API error — do NOT swallow
# to /dev/null, which would make "no parent" indistinguishable from "API 403"
# and risk a silent destructive close downstream if the caller re-runs.
PARENT_RESP=$(gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    issue(number:$num){ parent{ number state } }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F num="$NUMBER") || {
	echo "ERROR: graphql parent lookup for #$NUMBER failed (auth? network?)" >&2
	exit 2
}
if echo "$PARENT_RESP" | jq -e '.errors != null' >/dev/null 2>&1; then
	echo "ERROR: graphql parent lookup returned errors:" >&2
	echo "$PARENT_RESP" | jq '.errors' >&2
	exit 2
fi

PARENT_NUM=$(echo "$PARENT_RESP" | jq -r '.data.repository.issue.parent.number // empty')

if [ -z "$PARENT_NUM" ]; then
	echo "auto-close-parent: #$NUMBER has no parent epic — nothing to close"
	exit 0
fi

# v4.5 Phase 2 round 2 (CR): strict numeric validation of PARENT_NUM
# before using it in gh issue close. Mirror the OPEN_SUBS check below.
if ! [[ "$PARENT_NUM" =~ ^[0-9]+$ ]]; then
	echo "ERROR: parent number for #$NUMBER is not numeric: '$PARENT_NUM'" >&2
	exit 2
fi

# v4.5 Phase 2 round 2 (CR): extract state from the already-fetched
# PARENT_RESP instead of a second gh issue view call. Saves one API
# round-trip + avoids the race window where parent's state could change
# between the two reads.
PARENT_STATE=$(echo "$PARENT_RESP" | jq -r '.data.repository.issue.parent.state // empty')
if [ -z "$PARENT_STATE" ]; then
	echo "ERROR: could not extract parent state for #$PARENT_NUM from graphql response" >&2
	exit 2
fi
if [ "$PARENT_STATE" = "CLOSED" ]; then
	echo "auto-close-parent: parent #$PARENT_NUM already closed"
	exit 0
fi

# Query parent's sub-issues with pagination cap at 100 (warn + skip
# close on hasNextPage, NEVER falsely close on truncated state).
SUBS_RESP=$(gh api graphql -f query='
query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){
    issue(number:$num){ subIssues(first:100){ nodes{ number state } pageInfo{ hasNextPage } } }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F num="$PARENT_NUM") || {
	echo "ERROR: graphql sub-issue lookup for #$PARENT_NUM failed" >&2
	exit 2
}
if echo "$SUBS_RESP" | jq -e '.errors != null' >/dev/null 2>&1; then
	echo "ERROR: graphql sub-issue lookup returned errors:" >&2
	echo "$SUBS_RESP" | jq '.errors' >&2
	exit 2
fi

# v4.5 CR-in-CI round 2: if pagination overflows, the query returned a
# truncated list. Hard-failing with exit 2 turned the large-epic edge
# case into a build-break; the workflow equivalent paginates and only
# skips close when cap is exceeded. Match that: warn + skip close
# cleanly (the parent stays open — safer than closing on a partially-
# read state). If a future epic approaches 100, upgrade to real pagination.
HAS_MORE=$(echo "$SUBS_RESP" | jq -r '.data.repository.issue.subIssues.pageInfo.hasNextPage // false')
if [ "$HAS_MORE" = "true" ]; then
	echo "auto-close-parent: parent #$PARENT_NUM has >100 sub-issues — skipping close (cannot trust truncated state)" >&2
	exit 0
fi

OPEN_SUBS=$(echo "$SUBS_RESP" | jq -r '[.data.repository.issue.subIssues.nodes[]? | select(.state == "OPEN") | .number] | length')
# Strict numeric validation — never let garbage fall into a `-gt 0` test
# where suppressed errors could make the "greater than 0" branch look false
# and trigger a destructive close.
if ! [[ "$OPEN_SUBS" =~ ^[0-9]+$ ]]; then
	echo "ERROR: sub-issue count for #$PARENT_NUM is not numeric: '$OPEN_SUBS'" >&2
	exit 2
fi

if [ "$OPEN_SUBS" -gt 0 ]; then
	echo "auto-close-parent: parent #$PARENT_NUM has $OPEN_SUBS open sub-issue(s) — not closing"
	exit 0
fi

echo "auto-close-parent: all sub-issues of #$PARENT_NUM are closed — closing parent"
# v4.5 Phase 2 round 4 (CR-in-CI): race condition — a concurrent
# invocation or manual close can close the parent between the PARENT_STATE
# check above and this close call. Capture + inspect the close failure:
# if gh reports it already closed, treat as success (the end-state
# matches what we wanted). Any other error still exits 2.
CLOSE_OUT=$(gh issue close "$PARENT_NUM" --comment "All sub-issues closed — auto-closing via .claude/hooks/auto-close-parent.sh (local equivalent of auto-close-parent.yml during Actions cap per #366)." 2>&1) || {
	if echo "$CLOSE_OUT" | grep -qiE "already closed|is closed"; then
		echo "auto-close-parent: parent #$PARENT_NUM already closed by concurrent actor — treating as success"
	else
		echo "ERROR: gh issue close #$PARENT_NUM failed — NOT running board-sync" >&2
		echo "$CLOSE_OUT" | head -5 >&2
		exit 2
	fi
}

# Fire Status=Done on the board
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$REPO_ROOT" ] && [ -x "$REPO_ROOT/.claude/local-backups/project-board-sync.sh" ]; then
	"$REPO_ROOT/.claude/local-backups/project-board-sync.sh" --on-close "$PARENT_NUM" || {
		echo "WARN: board-sync --on-close for #$PARENT_NUM failed — issue is closed, board Status may not be Done" >&2
	}
fi

# Recursive: the just-closed parent may itself be a sub-issue of a
# grandparent. Cascade the check upward. Surface the recursion's exit
# code with a warning — if a transient API blip breaks the cascade, the
# caller should see which level failed (the just-closed parent is a
# fait accompli regardless).
"$0" "$PARENT_NUM" || echo "WARN: grandparent cascade starting from #$PARENT_NUM exited $? (parent #$PARENT_NUM IS closed)" >&2
