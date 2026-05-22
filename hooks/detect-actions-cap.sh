#!/bin/bash
# Detect whether GitHub Actions are capped / deferred on this repo.
#
# Returns:
#   0 — Actions are open (workflows active, recent runs have non-zero billable_ms)
#   1 — Actions are capped / deferred (workflows disabled_manually OR recent runs show 0ms billable failure)
#   2 — Inconclusive (gh CLI missing, network error, new repo with no runs)
#
# Usage:
#   .claude/hooks/detect-actions-cap.sh [--quiet]
#
# Signals, in order:
#   1. `disabled_manually` workflow count > 0  → capped (the 2026-04-19 deferral pattern)
#   2. Recent runs show billable_ms=0 + conclusion=failure within 3s → capped
#   3. Otherwise → open

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

log() { [ "$QUIET" = "1" ] || echo "$@" >&2; }

command -v gh >/dev/null || {
	log "detect-actions-cap: gh CLI not installed"
	exit 2
}
command -v jq >/dev/null || {
	log "detect-actions-cap: jq not installed"
	exit 2
}

# Signal 1 — disabled workflow count
DISABLED=$(gh workflow list --limit 50 --all 2>/dev/null | awk -F'\t' '$2=="disabled_manually"' | wc -l | tr -d ' ')
if [ "${DISABLED:-0}" -gt 0 ] 2>/dev/null; then
	log "detect-actions-cap: $DISABLED workflows disabled_manually — deferral active (see issue #366)"
	exit 1
fi

# Signal 2 — recent-run billable pattern. Pull 5 latest, check if all show
# billable_ms=0 AND duration<3s AND conclusion=failure. If so, billing blocked.
# v4.3 CR round 2: resolve OWNER_REPO ONCE instead of calling gh repo view
# twice on every hook invocation.
OWNER_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
RECENT=$(gh api "/repos/${OWNER_REPO}/actions/runs?per_page=5" 2>/dev/null |
	jq -r '.workflow_runs[] | .id' 2>/dev/null)
if [ -z "$RECENT" ]; then
	log "detect-actions-cap: no recent runs — inconclusive"
	exit 2
fi
ZERO_BILLABLE=0
CHECKED=0
for rid in $RECENT; do
	TIMING=$(gh api "/repos/${OWNER_REPO}/actions/runs/${rid}/timing" 2>/dev/null)
	[ -z "$TIMING" ] && continue
	CHECKED=$((CHECKED + 1))
	BILLABLE=$(echo "$TIMING" | jq -r '.billable.UBUNTU.total_ms // 0')
	WALL=$(echo "$TIMING" | jq -r '.run_duration_ms // 0')
	if [ "$BILLABLE" = "0" ] && [ "$WALL" -lt 5000 ] 2>/dev/null; then
		ZERO_BILLABLE=$((ZERO_BILLABLE + 1))
	fi
done

if [ "$CHECKED" -ge 3 ] && [ "$ZERO_BILLABLE" -ge 3 ]; then
	log "detect-actions-cap: $ZERO_BILLABLE/$CHECKED recent runs had 0ms billable — billing cap active"
	exit 1
fi

log "detect-actions-cap: workflows active, recent runs billed normally — Actions open"
exit 0
