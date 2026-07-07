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
#
# #2483 error contract: failures are FAIL-LOUD (ERROR to stderr + nonzero
# exit), never a silent no-op. git ignores a post-commit hook's exit status
# (githooks(5)), so this can never block the commit; the documented caller's
# `|| true` exists so a `set -e` post-commit DISPATCHER still runs its
# remaining hooks after our nonzero exit. Failures that only affect the
# graduation-invalidation preflight skip THAT block but still attempt the
# review-log migration (this hook's primary #512 job), then exit nonzero.

_mrloa_rc=0

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	echo "migrate-review-log: ERROR — not inside a git repository; cannot run amend migration/invalidation (#2483)" >&2
	exit 1
fi
if ! cd "$REPO_ROOT"; then
	echo "migrate-review-log: ERROR — cd '$REPO_ROOT' failed (#2483)" >&2
	exit 1
fi

# Detect amend via reflog. Anchored to the reflog-subject format
# (`commit (amend): <message>`) so a REGULAR commit whose message
# happens to contain the substring "commit (amend)" (e.g. a doc commit
# explaining the amend workflow) doesn't false-positive-migrate.
# #2483: a FAILED reflog read is an error, not "not an amend" — on repos
# with reflogs disabled/expired every amend would otherwise silently skip
# both the migration and the invalidation.
if ! REFLOG_OP=$(git reflog -1 --format="%gs" 2>/dev/null); then
	echo "migrate-review-log: ERROR — cannot read the reflog; amend detection impossible (#2483)" >&2
	exit 1
fi
printf '%s\n' "$REFLOG_OP" | grep -qE '^commit \(amend\)(:| )' || exit "$_mrloa_rc"

# PRIOR_SHA stays lenient: HEAD@{1} legitimately fails on a single-entry
# reflog (first commit) — that is a skip, not an error. NEW_SHA is fail-loud:
# HEAD must resolve after a just-detected amend.
PRIOR_SHA=$(git rev-parse "HEAD@{1}" 2>/dev/null || true)
if ! NEW_SHA=$(git rev-parse HEAD 2>/dev/null); then
	echo "migrate-review-log: ERROR — cannot resolve HEAD after a detected amend (#2483)" >&2
	exit 1
fi
if [ -z "$PRIOR_SHA" ] || [ "$PRIOR_SHA" = "$NEW_SHA" ]; then
	exit "$_mrloa_rc"
fi

# #2296: an amend rotated HEAD's SHA, so a graduation marker certifying Phase
# 0.5/1 at the pre-amend SHA now describes discarded code. Invalidate it
# immediately (local, before any push) so the amended content is re-reviewed.
# Independent of the review-log migration below — fires even when there is no
# prior log to carry forward. The happy path only emits when a marker actually
# existed; the lib-unreadable WARN below is evidence-gated so never-graduated
# repos stay silent too.
# #2296: resolve THIS hook's dir (absolute) so the graduation lib can be
# sourced from its `../_lib` sibling. The documented install shape (above)
# invokes this script by ABSOLUTE path, so ${BASH_SOURCE[0]} is already
# absolute and `dirname/../_lib` resolves correctly; under a bare `.git/hooks`
# symlink install it resolves to the WRONG depth, the lib is unreadable, and
# the evidence-gated WARN below fires instead. CR #2485: resolved LAZILY —
# only the invalidation block consumes it, and resolving before the amend gate
# would (on a resolver failure) ERROR on every commit instead of only on
# amends, violating the same evidence-gating intent as the WARN. Fail-loud but
# NON-FATAL: the review-log migration further down does not need the lib. The
# pre-push gate is the authoritative backstop either way — its #2483 ancestry
# check (graduated_sha must be an ancestor of the pushed sha) catches every
# rewrite shape at push time.
if ! _MRLOA_HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); then
	echo "migrate-review-log: ERROR — cannot resolve this hook's directory; graduation invalidation will be skipped (#2483)" >&2
	_MRLOA_HOOK_DIR=""
	_mrloa_rc=1
fi
_grad_lib="$_MRLOA_HOOK_DIR/../_lib/phase-graduation.sh"
_grad_marker_dir="$REPO_ROOT/.claude/.session-state/phase-graduation"
# #2483: branch-resolution failure is fail-loud but NON-FATAL — it blocks only
# the invalidation preflight; the migration below must still run. Detached
# HEAD ("HEAD") stays a LEGITIMATE skip: there is no branch marker to
# invalidate.
_amend_branch=""
if ! _amend_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
	echo "migrate-review-log: ERROR — cannot resolve the current branch; graduation invalidation skipped (#2483)" >&2
	_amend_branch=""
	_mrloa_rc=1
fi
if [ ! -r "$_grad_lib" ]; then
	# Symlink-install shape (see resolver comment above). Evidence-gated: only
	# WARN when some branch is actually graduated (a marker file exists) —
	# otherwise this fires on EVERY amend under that install shape and trains
	# operators to ignore the one occurrence that matters.
	if [ -n "$_amend_branch" ] && [ "$_amend_branch" != "HEAD" ] && ls "$_grad_marker_dir"/*.json >/dev/null 2>&1; then
		echo "migrate-review-log: WARN — graduation lib unreadable at $_grad_lib; amend invalidation SKIPPED. The pre-push gate's ancestry check (#2483) re-invalidates the rewritten branch at push time." >&2
	fi
elif [ -n "$_amend_branch" ] && [ "$_amend_branch" != "HEAD" ]; then
	# shellcheck source=/dev/null
	. "$_grad_lib"
	if graduation_check "$_amend_branch"; then
		if graduation_invalidate "$_amend_branch"; then
			echo "migrate-review-log: amend on $_amend_branch — invalidated stale graduation marker (#2296)" >&2
		else
			# graduation_invalidate already prints the rm error to stderr;
			# surface it at the hook level too so a failed removal is not lost
			# in the post-commit noise. The pre-push ancestry check (#2483)
			# catches the persisted stale marker at push time, but flag the
			# manual cleanup anyway.
			echo "migrate-review-log: WARN — amend on $_amend_branch but the stale graduation marker could NOT be removed (see error above); the pre-push ancestry check (#2483) will refuse to honor it, remove it manually (see _lib/phase-graduation.sh graduation_marker_path)" >&2
		fi
	fi
fi

PRIOR_LOG="$REPO_ROOT/.claude/review-log/${PRIOR_SHA}.jsonl"
NEW_LOG="$REPO_ROOT/.claude/review-log/${NEW_SHA}.jsonl"

# No prior log: nothing to migrate
[ -f "$PRIOR_LOG" ] || exit "$_mrloa_rc"

# Idempotency: if new log already has entries, skip (don't overwrite)
if [ -f "$NEW_LOG" ] && [ -s "$NEW_LOG" ]; then
	echo "migrate-review-log: ${NEW_SHA:0:8} already has a log — skipping amend-migration from ${PRIOR_SHA:0:8}" >&2
	exit "$_mrloa_rc"
fi

# jq required for sha-field rewrite
if ! command -v jq >/dev/null 2>&1; then
	echo "migrate-review-log: jq missing — cannot migrate (install jq or manually copy $PRIOR_LOG to $NEW_LOG)" >&2
	exit 1
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
exit "$_mrloa_rc"
