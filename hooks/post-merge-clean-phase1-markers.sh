#!/bin/bash
set -euo pipefail
# event: git-post-merge
# auto-register: false
# v0.27.0 (#173) — git post-merge hook that self-heals stale Phase 1
# directive markers when local main moves to include merged commits.
#
# Pairs with hooks/phase1-directive-pending-guard.sh (Layer 1 gate self-
# heal) and skills/github-pr-merge/run.sh (Layer 2 merge-wrapper cleanup).
#
# Why a 3rd layer: catches the GitHub-UI-merge-then-git-pull case.
# Operator merges a PR via GitHub web (or another machine), then
# `git pull` brings the squash-merge commit local. Local marker file
# for the original branch HEAD sha is now stranded (Layer 2 didn't
# fire — merge wasn't via local skill). This hook fires on every
# post-merge / post-pull, scans markers, drops any whose SHA is now
# reachable from main.
#
# Wiring (one-time per clone): scripts/install-hooks.sh now adds this
# to .git/hooks/post-merge alongside post-merge-release-fire.sh.
#
# Behavior:
#   1. Locate .claude/.session-state/ship-cycle/*.phase1-directive.txt
#   2. For each, check if its <sha> is reachable from origin/main
#   3. If yes (work landed) → rm the marker
#   4. Audit-log every cleanup to .claude/logs/phase1-marker-cleanup.jsonl
#
# Exit codes:
#   0 — always (defensive cleanup; never block post-merge)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO_ROOT"

DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
[ -d "$DIR" ] || exit 0

LOG_DIR="$REPO_ROOT/.claude/logs"
# v0.27.1 CR: log-dir creation failure should NOT abort cleanup — degraded
# logging is acceptable, but losing cleanup means marker leaks accumulate.
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/phase1-marker-cleanup.jsonl"

cleaned=0
inspected=0
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for f in "$DIR"/*.phase1-directive.txt; do
	[ -f "$f" ] || continue
	inspected=$((inspected + 1))
	sha=$(basename "$f" .phase1-directive.txt)
	if git merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
		rm -f "$f"
		cleaned=$((cleaned + 1))
		if command -v jq >/dev/null 2>&1; then
			jq -cn --arg ts "$TS" --arg sha "$sha" --arg event "cleaned-on-merge" \
				'{ts:$ts,sha:$sha,event:$event}' >>"$LOG_FILE" 2>/dev/null || true
		fi
	fi
done

[ "$cleaned" -gt 0 ] && echo "post-merge-clean-phase1-markers: cleaned $cleaned of $inspected stale phase1-directive marker(s)" >&2
exit 0
