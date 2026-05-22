#!/bin/bash
set -euo pipefail
# v4.21 (#520): thin wrapper over the `coderabbit:autofix` skill that
# batches fetch + apply in a single invocation. The skill itself handles
# the CR comment → commit mechanics; this script adds:
#
# 1. Pre-flight: list outstanding CR findings on PR HEAD (via
#    query-findings.sh) so the operator sees scope before autofix runs.
# 2. Budget preflight via rate-budget.sh --check.
# 3. Dry-run: show what WOULD be fetched + (best-effort) what the skill
#    would apply, without invoking the skill.
#
# Usage:
#   .claude/scripts/cr/autofix-batch.sh <pr-num>
#   .claude/scripts/cr/autofix-batch.sh <pr-num> --dry-run
#
# NB: the skill itself is invoked via Claude Code's skill system
# (coderabbit:autofix). This script exits with guidance to invoke the
# skill when ready — it can't drive the skill programmatically from
# bash (skills are Claude-initiated).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../_common.sh
source "$REPO_ROOT/.claude/scripts/_common.sh"

SCM_DRY_RUN=0
PR=""
for arg in "$@"; do
	case "$arg" in
	--dry-run) SCM_DRY_RUN=1 ;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		if [ -z "$PR" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
			PR="$arg"
		else
			scm_fail "unknown or invalid arg: $arg"
		fi
		;;
	esac
done
[ -n "$PR" ] || scm_fail "usage: $0 <pr-num> [--dry-run]"

# Preflight 1: budget.
if ! "$SCRIPT_DIR/rate-budget.sh" --check >/dev/null 2>&1; then
	scm_warn "CR budget near-exhausted — autofix may blow through the 10/hr cap (Pro Plus, refill 6min/token). Consider waiting."
fi

# Preflight 2: findings inventory via the read-only script shipped in PR-B.
echo "=== CR findings on PR #$PR HEAD ==="
"$SCRIPT_DIR/query-findings.sh" "$PR"
echo ""

if [ "$SCM_DRY_RUN" = "1" ]; then
	echo "[dry-run] would invoke the coderabbit:autofix skill on PR #$PR"
	echo "[dry-run] the skill batches CR comments → commits (no direct bash driver — skill invocation is Claude-side)"
	exit 0
fi

# The skill itself needs Claude to invoke. We print the next-action
# directive and exit 0 — the operator (or Claude Code auto-loop) picks
# it up. This mirrors the pattern used by pr-trigger.sh.
echo "=== Next action ==="
echo "Invoke the coderabbit:autofix skill to batch-apply the fixes above:"
echo "  /coderabbit:autofix $PR"
echo ""
echo "(this wrapper can't drive the skill from bash — skills are Claude-side)"

scm_log cr-autofix-batch "$(jq -nc --argjson pr "$PR" --argjson dry "$SCM_DRY_RUN" \
	'{pr: $pr, dry_run: $dry}')"
