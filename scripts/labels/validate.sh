#!/bin/bash
set -euo pipefail
# v4.21 (#520): validate that every open issue has one type label + one
# area label. Reports violations. READ-ONLY — no mutations.
#
# Usage:
#   .claude/scripts/labels/validate.sh              # table output
#   .claude/scripts/labels/validate.sh --json       # machine-readable
#   .claude/scripts/labels/validate.sh --exit-nonzero-on-violations
#
# Type labels:  bug | enhancement (see .github/labels.yml for full set;
#   'epic' is intentionally excluded because every epic also carries
#   enhancement by convention — enforced by issue-template rules).
# Area labels:  anything with `area:` prefix — see .github/labels.yml (SSOT).
#
# Exits 0 by default (advisory). With --exit-nonzero-on-violations, exits
# 1 when any issue is missing a required label — useful in pre-commit
# or CI-style checks.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

FORMAT="table"
FAIL_ON_VIOLATIONS=0
while [ $# -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT="json"
		shift
		;;
	--exit-nonzero-on-violations)
		FAIL_ON_VIOLATIONS=1
		shift
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*) scm_fail "unknown arg: $1" ;;
	esac
done

# Pull all open issues with their labels in one request. --limit 1000
# because the default 30 is misleadingly small (see memory
# feedback_gh_query_limits). Comfortable margin above any realistic
# open-issue count for this repo (currently ~60 open); if the repo
# ever exceeds 1000 open issues we'd need proper pagination.
ISSUES=$(gh issue list --state open --limit 1000 \
	--json number,title,labels \
	--jq '[.[] | {num: .number, title: .title, labels: [.labels[].name]}]' 2>&1) ||
	scm_fail "gh issue list failed: $ISSUES"

# Truncation warn: if we fetched exactly --limit, there's probably more.
# Switch to pagination when this fires.
ISSUE_COUNT=$(printf '%s' "$ISSUES" | jq 'length') ||
	scm_fail "jq length failed on gh issue list output: $ISSUES"
if [ "$ISSUE_COUNT" = "1000" ]; then
	scm_warn "retrieved exactly 1000 issues — results may be truncated; implement pagination"
fi

# Classify each issue. "violations" field lists the missing categories.
VIOLATIONS=$(printf '%s' "$ISSUES" | jq -c '
  [.[] | . as $issue |
   {
     num: .num,
     title: .title,
     has_type: ((.labels | any(. == "bug" or . == "enhancement"))),
     has_area: ((.labels | any(startswith("area:")))),
     labels: .labels
   }
   | .violations = ([
       (if .has_type then empty else "type" end),
       (if .has_area then empty else "area" end)
     ])
   | select(.violations | length > 0)
   | {num, title, violations, labels}]
')

COUNT=$(printf '%s' "$VIOLATIONS" | jq 'length')

case "$FORMAT" in
json)
	printf '%s\n' "$VIOLATIONS" | jq .
	;;
table)
	if [ "$COUNT" = "0" ]; then
		echo "✓ label validation clean — all open issues have type + area labels"
	else
		echo "⚠ $COUNT open issue(s) missing required labels:"
		echo ""
		printf '%-6s  %-20s  %s\n' "#" "MISSING" "TITLE"
		printf '%-6s  %-20s  %s\n' "------" "--------------------" "-------------------------"
		printf '%s\n' "$VIOLATIONS" | jq -r '.[] | "#\(.num)\t\(.violations | join(","))\t\(.title[0:50])"' |
			awk -F'\t' '{printf "%-6s  %-20s  %s\n", $1, $2, $3}'
		echo ""
		echo "To fix: gh issue edit <num> --add-label <label>"
	fi
	;;
esac

scm_log labels-validate "$(jq -nc --arg f "$FORMAT" --argjson v "$COUNT" '{format: $f, violations: $v}')"

if [ "$FAIL_ON_VIOLATIONS" = "1" ] && [ "$COUNT" != "0" ]; then
	exit 1
fi
