#!/bin/bash
set -euo pipefail
# v4.21 (#520): audit all not-Done board items. Reports any that are missing
# Type, Area, or Priority fields — the triage gaps that silently pile up
# when ai-triage.yml is disabled or the issue template was bypassed.
#
# Usage:
#   .claude/scripts/board/audit.sh              # human-readable table
#   .claude/scripts/board/audit.sh --json       # machine-readable per-item JSON
#   .claude/scripts/board/audit.sh --count      # just the counts
#
# Exits 0 always (advisory). The caller decides whether to escalate.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

FORMAT="table"
while [ $# -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT="json"
		shift
		;;
	--count)
		FORMAT="count"
		shift
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*) scm_fail "unknown arg: $1" ;;
	esac
done

# The Homelab board is project #2 owned by @me. GraphQL query pulls every
# not-Done item with its Type/Area/Priority single-select field values in
# one round-trip (lighter than `gh project item-list` + per-item field reads).
# Cursor pagination: GraphQL caps `first` at 100/page. Board has hundreds
# of items (mostly Done) — without pagination we'd silently truncate and
# "✓ board clean" would be a lie for any gap past position 100. Violates
# the feedback_gh_query_limits rule. Loop until pageInfo.hasNextPage=false.
NODES='[]'
CURSOR="null"
while :; do
	# CURSOR="null" is passed via `-F` which auto-converts the literal
	# string "null" to a JSON null on first iteration — GraphQL's
	# `after: null` means "start at page 1". No `--raw-field` needed.
	PAGE_COUNT=$((${PAGE_COUNT:-0} + 1))
	# Safety cap: prevents an infinite loop if hasNextPage=true + endCursor
	# stuck (server edge case). 50 pages × 100 items = 5000 items, well
	# above any realistic board size.
	if [ "$PAGE_COUNT" -gt 50 ]; then
		scm_fail "pagination exceeded 50 pages — possible stuck cursor"
	fi
	PAGE=$(gh api graphql -f query='
query($cursor: String) {
  viewer {
    projectV2(number: 2) {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content {
            ... on Issue { number title url state }
            ... on PullRequest { number title url state }
          }
          status: fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          type: fieldValueByName(name: "Type") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          area: fieldValueByName(name: "Area") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
          priority: fieldValueByName(name: "Priority") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}' -F "cursor=$CURSOR" 2>&1) || scm_fail "gh graphql query failed: $PAGE"
	# GraphQL returns HTTP 200 + `.errors` on partial failures (auth scope,
	# deprecated fields, etc.) — surface them instead of letting the
	# downstream `.data.nodes` read null-coerce into "0 gaps, clean".
	if printf '%s' "$PAGE" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
		scm_fail "graphql returned .errors: $(printf '%s' "$PAGE" | jq -c .errors)"
	fi
	# Each jq fires `|| scm_fail` rather than relying on set -e + pipefail
	# alone — gives the operator a diagnostic identifying which step failed
	# + the raw payload that tripped it. `.errors` is already checked above,
	# so these should only fire on truly unexpected server responses.
	PAGE_NODES=$(printf '%s' "$PAGE" | jq -c '.data.viewer.projectV2.items.nodes') ||
		scm_fail "audit: jq nodes-extract failed on page $PAGE_COUNT payload: $PAGE"
	NODES=$(jq -nc --argjson a "$NODES" --argjson b "$PAGE_NODES" '$a + $b') ||
		scm_fail "audit: jq nodes-concat failed on page $PAGE_COUNT"
	HAS_NEXT=$(printf '%s' "$PAGE" | jq -r '.data.viewer.projectV2.items.pageInfo.hasNextPage') ||
		scm_fail "audit: jq hasNextPage read failed on page $PAGE_COUNT"
	[ "$HAS_NEXT" = "true" ] || break
	CURSOR=$(printf '%s' "$PAGE" | jq -r '.data.viewer.projectV2.items.pageInfo.endCursor')
done

BOARD_JSON=$(jq -nc --argjson nodes "$NODES" '{data: {viewer: {projectV2: {items: {nodes: $nodes}}}}}')

# Filter to not-Done items, extract gaps. The `// "∅"` in jq catches both
# nulls (field never set) and absent keys (GraphQL omits on null union).
GAPS=$(printf '%s' "$BOARD_JSON" | jq -c '
  [.data.viewer.projectV2.items.nodes[]
   | select(.content.number != null)
   | select((.status.name // "∅") != "Done")
   | {
       num: .content.number,
       title: .content.title,
       status: (.status.name // "∅"),
       type: (.type.name // "∅"),
       area: (.area.name // "∅"),
       priority: (.priority.name // "∅"),
       missing: ([
         (if (.type.name // "∅") == "∅" then "Type" else empty end),
         (if (.area.name // "∅") == "∅" then "Area" else empty end),
         (if (.priority.name // "∅") == "∅" then "Priority" else empty end)
       ])
     }
   | select(.missing | length > 0)]
')

COUNT=$(printf '%s\n' "$GAPS" | jq 'length')

case "$FORMAT" in
json)
	printf '%s\n' "$GAPS" | jq .
	;;
count)
	printf '%s\n' "$COUNT"
	;;
table)
	if [ "$COUNT" = "0" ]; then
		echo "✓ board clean — all not-Done items have Type + Area + Priority set"
		exit 0
	fi
	echo "⚠ $COUNT not-Done board items with missing triage fields:"
	echo ""
	printf '%-6s  %-12s  %-12s  %-25s  %s\n' "#" "STATUS" "MISSING" "TITLE" ""
	printf '%-6s  %-12s  %-12s  %-25s  %s\n' "------" "------------" "------------" "-------------------------" ""
	printf '%s\n' "$GAPS" | jq -r '.[] | "#\(.num)\t\(.status)\t\(.missing | join(","))\t\(.title[0:40])"' |
		awk -F'\t' '{printf "%-6s  %-12s  %-12s  %s\n", $1, $2, $3, $4}'
	echo ""
	echo 'To fix: assign triage fields via `.claude/scripts/board/set-field.sh <num> <field> <value>`'
	;;
esac

scm_log board-audit "$(printf '{"format":"%s","gap_count":%s}' "$FORMAT" "$COUNT")"
