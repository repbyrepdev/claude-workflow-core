#!/bin/bash
set -euo pipefail
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
