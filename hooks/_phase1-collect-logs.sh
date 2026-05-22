#!/bin/bash
# v4.15.Y #499 — Aggregate Phase 1 review-logs across all commits on the
# current branch since base.
#
# WHY: review-log.sh writes to $LOG_DIR/${SHA}.jsonl — per-SHA. So every
# commit resets round count to 1, making MIN_ROUNDS=5 unreachable on a
# single SHA when the dogfood loop COMMITS between rounds (as it must,
# because Phase 1 agents review the committed diff, not the working tree).
#
# HOW: walk `git rev-list BASE..HEAD` → concat every existing JSONL →
# emit on stdout. Callers (gates + F-block) pipe to jq to compute
# convergence across the whole branch history.
#
# Round identity: preserved as (.sha, .round) tuple — each entry already
# carries .sha, so two rounds numbered "1" on different commits are
# correctly distinct. Convergence-counting code groups on this tuple.
#
# Usage:
#   _phase1-collect-logs.sh [base-ref]
# Default base is main. Output: JSONL on stdout (one line per entry,
# same format as $LOG_DIR/*.jsonl).
#
# Exit 0 always (empty output = no logs). Stderr gets any git warnings.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOG_DIR="$REPO_ROOT/.claude/review-log"
BASE="${1:-main}"

# git rev-list BASE..HEAD — oldest-to-newest requires --reverse. For
# convergence we want newest-first for the streak walk, but leave that
# to the caller. Emit oldest-first so timestamps-within-file stay
# chronological.
# v4.15.Z: fail-closed on git errors. Prior silent swallow masked bad
# base refs and shallow-clone issues, hiding the real cause of gate
# refusals behind "0 rounds" messages.
cd "$REPO_ROOT" || {
	echo "collect-logs: cd $REPO_ROOT failed — failing closed" >&2
	exit 2
}
if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
	echo "collect-logs: base '$BASE' missing — failing closed" >&2
	exit 2
fi

if ! SHAS=$(git rev-list --reverse "$BASE..HEAD"); then
	echo "collect-logs: git rev-list failed — failing closed" >&2
	exit 2
fi
for sha in $SHAS; do
	if [ -f "$LOG_DIR/${sha}.jsonl" ]; then
		cat "$LOG_DIR/${sha}.jsonl"
	else
		echo "collect-logs: no review-log for commit ${sha:0:8} — skipping" >&2
	fi
done
