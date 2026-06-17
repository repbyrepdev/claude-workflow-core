#!/bin/bash
set -euo pipefail
# auto-register: false
# (Invoked by .git/hooks/post-commit, not a Claude tool-use hook — so it
# declares no `# event:`; same pattern as pre-push-pipeline-gate.sh.)
# v4.19 (#512): fix amend-orphan of Phase 1 review-log entries.
#
# Problem: `git commit --amend` rotates HEAD's SHA. The Phase 1 gate
# (phase1-before-cr.sh v4.15.Y) walks (sha, round) tuples across
# `git log main..HEAD`. When an amend happens mid-dogfood, the prior
# SHA is dropped from that range, orphaning all its review-log
# entries — causing a cascade of "streak=0" gate failures (and
# psychological pressure to fabricate entries, as observed 2026-04-20).
#
# Fix (Option 3 from #512): on post-commit, detect amend via reflog,
# copy the prior SHA's review-log to the new SHA's file with the sha
# field rewritten, log the migration to stderr for audit.
#
# Install: add one line to `.git/hooks/post-commit`:
#   "$(git rev-parse --show-toplevel)/.claude/hooks/migrate-review-log-on-amend.sh" || true
# (pre-commit-install.sh v4.19 wires this automatically.)
#
# Safe:
# - Only fires on amend (reflog subject contains "commit (amend)").
# - Idempotent: if new SHA log already exists, skips (won't overwrite).
# - Preserves prior log file (for audit trail — future cleanup could
#   remove orphaned logs older than a configurable threshold).
# - No-op if prior log doesn't exist (first commit on branch, or no
#   review-log entries written yet).

# #2296: resolve THIS hook's dir (absolute) so the graduation lib can be
# sourced after the `cd "$REPO_ROOT"` below. The documented install shape
# (above) invokes this script by ABSOLUTE path, so ${BASH_SOURCE[0]} is already
# absolute and `dirname/../_lib` resolves correctly. NOTE: unlike pre-push-
# pipeline-gate.sh, this hook does NOT defend against a bare `.git/hooks`
# symlink install — under that shape BASH_SOURCE points at `.git/hooks`, the lib
# is unreadable, and the empty-dir fallback simply skips invalidation. That is
# acceptable: the pre-push force-push gate (#2295) re-invalidates a rewritten
# branch at push time, so this post-commit pass is only a local convenience.
_MRLOA_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _MRLOA_HOOK_DIR=""

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$REPO_ROOT" ] && exit 0
cd "$REPO_ROOT" || exit 0

# Detect amend via reflog. Anchored to the reflog-subject format
# (`commit (amend): <message>`) so a REGULAR commit whose message
# happens to contain the substring "commit (amend)" (e.g. a doc commit
# explaining the amend workflow) doesn't false-positive-migrate.
REFLOG_OP=$(git reflog -1 --format="%gs" 2>/dev/null || true)
printf '%s\n' "$REFLOG_OP" | grep -qE '^commit \(amend\)(:| )' || exit 0

PRIOR_SHA=$(git rev-parse "HEAD@{1}" 2>/dev/null || true)
NEW_SHA=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$PRIOR_SHA" ] || [ -z "$NEW_SHA" ] || [ "$PRIOR_SHA" = "$NEW_SHA" ]; then
	exit 0
fi

# #2296: an amend rotated HEAD's SHA, so a graduation marker certifying Phase
# 0.5/1 at the pre-amend SHA now describes discarded code. Invalidate it
# immediately (local, before any push) so the amended content is re-reviewed.
# Independent of the review-log migration below — fires even when there is no
# prior log to carry forward. Only emits when a marker actually existed, so it
# stays silent on amends of never-graduated branches.
_grad_lib="$_MRLOA_HOOK_DIR/../_lib/phase-graduation.sh"
_amend_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ -n "$_amend_branch" ] && [ "$_amend_branch" != "HEAD" ] && [ -r "$_grad_lib" ]; then
	# shellcheck source=/dev/null
	. "$_grad_lib"
	if graduation_check "$_amend_branch"; then
		if graduation_invalidate "$_amend_branch"; then
			echo "migrate-review-log: amend on $_amend_branch — invalidated stale graduation marker (#2296)" >&2
		fi
	fi
fi

PRIOR_LOG="$REPO_ROOT/.claude/review-log/${PRIOR_SHA}.jsonl"
NEW_LOG="$REPO_ROOT/.claude/review-log/${NEW_SHA}.jsonl"

# No prior log: nothing to migrate
[ -f "$PRIOR_LOG" ] || exit 0

# Idempotency: if new log already has entries, skip (don't overwrite)
if [ -f "$NEW_LOG" ] && [ -s "$NEW_LOG" ]; then
	echo "migrate-review-log: ${NEW_SHA:0:8} already has a log — skipping amend-migration from ${PRIOR_SHA:0:8}" >&2
	exit 0
fi

# jq required for sha-field rewrite
if ! command -v jq >/dev/null 2>&1; then
	echo "migrate-review-log: jq missing — cannot migrate (install jq or manually copy $PRIOR_LOG to $NEW_LOG)" >&2
	exit 0
fi

# Copy + rewrite .sha field
mkdir -p "$(dirname "$NEW_LOG")"
if ! jq -c --arg newsha "$NEW_SHA" '.sha = $newsha' "$PRIOR_LOG" >"$NEW_LOG"; then
	echo "migrate-review-log: jq rewrite failed; removing partial output" >&2
	rm -f "$NEW_LOG"
	exit 1
fi

COUNT=$(wc -l <"$NEW_LOG" | tr -d ' ')
echo "migrate-review-log: migrated ${COUNT} entries from ${PRIOR_SHA:0:8} → ${NEW_SHA:0:8} (amend detected)" >&2
