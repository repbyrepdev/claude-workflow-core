#!/bin/bash
set -euo pipefail
# v4.21 PR-E (#520 finalize): pre-commit hook that fires label-sync.sh
# when `.github/labels.yml` changes. Replaces the `label-sync.yml`
# workflow's `push:; paths: .github/labels.yml` trigger — ensures GitHub
# labels stay synced with the SSOT file without depending on Actions.
#
# Advisory-only: sync failure warns but doesn't block the commit (e.g.,
# gh auth lapse on dev machine). The remote authoritative path is the
# merge commit — if the commit lands on main, maintain.sh nightly can
# re-run label-sync if the commit-time run was skipped.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
REPLICA="$REPO_ROOT/.claude/local-backups/label-sync.sh"

MODE_READER="$REPO_ROOT/.claude/hooks/_read-actions-mode.sh"
if [ -x "$MODE_READER" ] && [ "$("$MODE_READER")" = "remote" ]; then
	exit 0
fi

[ -x "$REPLICA" ] || {
	echo "⚠ label-sync replica missing at $REPLICA — skipping" >&2
	exit 0
}

# Invoke with --dry-run — we only want to flag drift, not silently apply
# label changes during a commit. Operator can run label-sync.sh without
# --dry-run (or with --yes / -y for unattended apply) after reviewing.
# `if cmd; then :; else rc=$?` form: `if ! cmd; then rc=$?` would capture
# the negation's exit (always 0), not the real failure code — per the
# feedback_rc_capture_set_e memory.
echo "=== labels.yml changed — running label-sync --dry-run ==="
if "$REPLICA" --dry-run; then
	:
else
	rc=$?
	echo "⚠ label-sync --dry-run exited $rc — review output above before pushing" >&2
fi
exit 0
