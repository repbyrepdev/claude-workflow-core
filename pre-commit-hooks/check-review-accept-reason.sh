#!/bin/bash
# v4.3.D (#360): commit-msg hook — if a commit was produced after invoking
# Phase 1 "accept-with-reason" (the round-3-cap escape hatch for inter-agent
# contradictions), require a `Review-accept-reason:` git trailer in the
# commit body. Prevents accept-with-reason from becoming a silent way to
# dismiss a Phase 1 agent's persistent finding.
#
# Signal that accept-with-reason fired: the review-log for HEAD's sha-staged
# (or the currently-staged-but-not-yet-committed state) has a phase:1 entry
# with kind:"accept-with-reason" in its most recent round.
#
# Invoked by pre-commit framework at commit-msg stage (see .pre-commit-config.yaml).
set -u

MSG_FILE="${1:-}"
if [ -z "$MSG_FILE" ] || [ ! -f "$MSG_FILE" ]; then
	echo "check-review-accept-reason: commit-msg path not provided — skipping" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$REPO_ROOT" ] && exit 0

# Find the most recent review-log file — we don't know the sha yet (commit
# hasn't happened); pick the most-recently-modified .jsonl in the log dir.
LOG_DIR="$REPO_ROOT/.claude/review-log"
[ ! -d "$LOG_DIR" ] && exit 0

LATEST=$(find "$LOG_DIR" -name '*.jsonl' -not -name 'cr-budget.jsonl' \
	-exec stat -f "%m %N" {} \; 2>/dev/null |
	sort -rn | head -1 | awk '{print $2}')
# Linux fallback
if [ -z "$LATEST" ]; then
	LATEST=$(find "$LOG_DIR" -name '*.jsonl' -not -name 'cr-budget.jsonl' \
		-printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
fi
[ -z "$LATEST" ] && exit 0 # no review log → nothing to enforce

# Did the most recent round use accept-with-reason?
if ! grep -q '"kind":"accept-with-reason"' "$LATEST" 2>/dev/null; then
	exit 0
fi

# Require the trailer in the commit body
if ! grep -qE '^Review-accept-reason:\s*\S' "$MSG_FILE"; then
	cat >&2 <<'ERR'
BLOCK: Review-accept-reason trailer missing.

The review-log for this HEAD recorded a Phase 1 accept-with-reason event
(round-3 inter-agent contradiction). Commit body must document the reason
as a git trailer:

    Review-accept-reason: <why this contradiction was resolved this way>

Example:

    fix(deploy): simplify retry backoff

    Addresses flaky network recovery. Phase 1 round 3 had code-simplifier
    and silent-failure-hunter contradicting on the sleep loop — simplifier
    wanted it removed, failure-hunter wanted it kept.

    Review-accept-reason: kept the backoff loop per silent-failure-hunter;
    CLAUDE.md rule on "never retry in a tight loop" applies here.
ERR
	exit 1
fi

exit 0
