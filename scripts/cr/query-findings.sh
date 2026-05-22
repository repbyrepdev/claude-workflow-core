#!/bin/bash
set -euo pipefail
# v4.21 (#520): count CodeRabbit findings on a PR's current HEAD, grouped
# by severity. User-facing wrapper over the existing
# .claude/hooks/_pr-cr-findings.sh helper. READ-ONLY.
#
# Usage:
#   .claude/scripts/cr/query-findings.sh <pr-num>
#   .claude/scripts/cr/query-findings.sh <pr-num> --json
#   .claude/scripts/cr/query-findings.sh <pr-num> --critical-only
#
# Why a separate script: `_pr-cr-findings.sh` is a PRIVATE helper
# (underscore prefix) meant for composition into hooks. This script
# is the CLI-facing front door with severity grouping + JSON output.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../_common.sh
source "$REPO_ROOT/.claude/scripts/_common.sh"

PR=""
FORMAT="table"
CRITICAL_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT="json"
		shift
		;;
	--critical-only)
		CRITICAL_ONLY=1
		shift
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		if [ -z "$PR" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
			PR="$1"
			shift
		else
			scm_fail "unknown arg: $1"
		fi
		;;
	esac
done
[ -n "$PR" ] || scm_fail "usage: $0 <pr-num> [--json] [--critical-only]"

# Get PR HEAD SHA — CR findings are stamped with commit_id, and only
# findings on the current HEAD are actionable (findings on stale commits
# reflect fixed-and-pushed code).
HEAD_SHA=$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>&1) ||
	scm_fail "gh pr view failed for #$PR: $HEAD_SHA"

# Pull all CR review comments + filter to ones on the HEAD commit.
# Group by severity (extracted from the CR comment body conventions:
# `**Critical**`, `**Minor**`, `**Potential issue**`, etc).
# `gh api --paginate` concatenates JSON arrays from each page into
# `[...][...][...]`, which jq can't parse as a single array. Use `--jq .[]`
# to emit one element per line, then slurp via `jq -s` into a single array.
# Split gh + jq into separate capture steps so gh failure reports gh's
# real error instead of jq's parse error on the error output.
if ! RAW=$(gh api "repos/:owner/:repo/pulls/$PR/comments" --paginate --jq '.[]' 2>&1); then
	scm_fail "gh api pulls comments failed: $RAW"
fi
COMMENTS=$(printf '%s' "$RAW" | jq -s '.') ||
	scm_fail "jq slurp failed on gh paginate output: $RAW"

FINDINGS=$(printf '%s' "$COMMENTS" | jq -c --arg sha "$HEAD_SHA" '
  [.[] | select(.user.login == "coderabbitai[bot]") | select(.commit_id == $sha) |
   {
     id: .id,
     path: .path,
     line: (.line // .original_line),
     severity: (
       if (.body | test("\\*\\*Critical[^\\*]*\\*\\*"; "i")) then "critical"
       elif (.body | test("\\*\\*Potential issue\\*\\*"; "i")) then "potential"
       elif (.body | test("\\*\\*Nitpick"; "i")) then "nitpick"
       elif (.body | test("\\*\\*Minor[^\\*]*\\*\\*"; "i")) then "minor"
       elif (.body | test("\\*\\*Refactor"; "i")) then "refactor"
       else "other"
       end
     )
   }]
')

if [ "$CRITICAL_ONLY" = "1" ]; then
	FINDINGS=$(printf '%s' "$FINDINGS" | jq -c '[.[] | select(.severity == "critical" or .severity == "potential")]')
fi

case "$FORMAT" in
json)
	printf '%s\n' "$FINDINGS" | jq .
	;;
table)
	TOTAL=$(printf '%s' "$FINDINGS" | jq 'length')
	BY_SEV=$(printf '%s' "$FINDINGS" | jq -c 'group_by(.severity) | map({sev: .[0].severity, count: length})')
	echo "PR #$PR HEAD: ${HEAD_SHA:0:8}"
	echo "Total findings on HEAD: $TOTAL"
	if [ "$TOTAL" = "0" ]; then
		echo "(clean)"
	else
		echo ""
		printf '%s\n' "$BY_SEV" | jq -r '.[] | "  \(.sev): \(.count)"'
	fi
	;;
esac

scm_log cr-query-findings "$(printf '{"pr":%s,"head":"%s","total":%s}' "$PR" "$HEAD_SHA" "$(printf '%s' "$FINDINGS" | jq 'length')")"
