#!/bin/bash
# v4.3.G (#374): log a CodeRabbit invocation to .claude/review-log/cr-budget.jsonl.
# Called from (a) the skill invoking `coderabbit review --plain` (source=cli),
# (b) observing a completed CR check on a PR (source=ci).
#
# Usage:
#   .claude/hooks/cr-log-invocation.sh <source> [pr_number] [head_sha] [findings_count]
# Example:
#   .claude/hooks/cr-log-invocation.sh cli "" abc1234 6
#   .claude/hooks/cr-log-invocation.sh ci 365 ee84980 6
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOG_DIR="$REPO_ROOT/.claude/review-log"
LOG="$LOG_DIR/cr-budget.jsonl"
mkdir -p "$LOG_DIR"

SOURCE="${1:-}"
PR="${2:-}"
SHA="${3:-}"
FINDINGS="${4:-}"

if [ -z "$SOURCE" ]; then
	echo "Usage: $0 <cli|ci> [pr_number] [head_sha] [findings_count]" >&2
	exit 2
fi
case "$SOURCE" in
cli | ci) ;;
*)
	echo "ERROR: source must be 'cli' or 'ci' — got '$SOURCE'" >&2
	exit 2
	;;
esac

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build JSON line defensively — jq handles null + empty string correctly
# Build the record + append. Fail loud on write error (full disk, no
# perms) rather than silently losing events — budget tracker would
# undercount and CR gate would false-pass.
RECORD=$(jq -nc \
	--arg ts "$TS" \
	--arg source "$SOURCE" \
	--arg pr "$PR" \
	--arg sha "$SHA" \
	--arg findings "$FINDINGS" \
	'{
    ts: $ts,
    source: $source,
    pr_number: (if $pr == "" then null else ($pr | tonumber) end),
    head_sha: (if $sha == "" then null else $sha end),
    findings_count: (if $findings == "" then null else ($findings | tonumber) end)
  }')
if ! printf '%s\n' "$RECORD" >>"$LOG"; then
	echo "ERROR: failed to append CR invocation to $LOG (disk full? perms?)" >&2
	exit 1
fi
