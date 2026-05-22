#!/bin/bash
set -euo pipefail
# v4.21 (#520): set a single-select field (Type/Area/Priority) on a board
# item via GraphQL. Replaces ad-hoc `gh api graphql -f query='...'` one-liners.
#
# Usage:
#   .claude/scripts/board/set-field.sh <issue-num> <field> <value> [--dry-run]
#
# Examples:
#   .claude/scripts/board/set-field.sh 520 Type Epic
#   .claude/scripts/board/set-field.sh 520 Priority P1
#   .claude/scripts/board/set-field.sh 520 Area Infrastructure --dry-run
#
# Exit 0 on success; 2 on invalid field/value or issue not on board.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../_common.sh
source "$REPO_ROOT/.claude/scripts/_common.sh"
# shellcheck source=./_board-lib.sh
source "$SCRIPT_DIR/_board-lib.sh"

SCM_DRY_RUN=0
ARGS=()
for arg in "$@"; do
	if [ "$arg" = "--dry-run" ]; then
		SCM_DRY_RUN=1
	else
		ARGS+=("$arg")
	fi
done

[ "${#ARGS[@]}" -eq 3 ] || scm_fail "usage: $0 <issue-num> <field> <value> [--dry-run]"
ISSUE="${ARGS[0]}"
FIELD="${ARGS[1]}"
VALUE="${ARGS[2]}"

[[ "$ISSUE" =~ ^[0-9]+$ ]] || scm_fail "issue must be numeric; got '$ISSUE'"

case "$FIELD" in
Status | Type | Area | Priority) ;;
*) scm_fail "field must be Status|Type|Area|Priority; got '$FIELD'" ;;
esac

scm_board_resolve_ids

ITEM_ID=$(scm_board_item_id_for_issue "$ISSUE") || scm_fail "issue #$ISSUE not on board"
OPTION_ID=$(scm_board_option_id "$FIELD" "$VALUE") || scm_fail "invalid value '$VALUE' for field '$FIELD'"

case "$FIELD" in
Status) FIELD_ID="$BOARD_STATUS_FIELD_ID" ;;
Type) FIELD_ID="$BOARD_TYPE_FIELD_ID" ;;
Area) FIELD_ID="$BOARD_AREA_FIELD_ID" ;;
Priority) FIELD_ID="$BOARD_PRIORITY_FIELD_ID" ;;
esac

if [ "$SCM_DRY_RUN" = "1" ]; then
	echo "[dry-run] would set #$ISSUE Board.$FIELD='$VALUE'"
	echo "  project:  $BOARD_PROJECT_ID"
	echo "  item:     $ITEM_ID"
	echo "  field:    $FIELD_ID"
	echo "  option:   $OPTION_ID"
	exit 0
fi

RESULT=$(gh api graphql -f query='
mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $project,
    itemId: $item,
    fieldId: $field,
    value: { singleSelectOptionId: $option }
  }) {
    projectV2Item { id }
  }
}' -F "project=$BOARD_PROJECT_ID" -F "item=$ITEM_ID" -F "field=$FIELD_ID" -F "option=$OPTION_ID" 2>&1) || {
	echo "✗ graphql mutation failed: $RESULT" >&2
	exit 2
}

# Surface graphql .errors even on HTTP 200 (same pattern as skc_graphql_add_sub_issue)
if printf '%s' "$RESULT" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
	echo "✗ mutation returned errors: $(printf '%s' "$RESULT" | jq -c .errors)" >&2
	exit 2
fi

echo "✓ #$ISSUE Board.$FIELD='$VALUE'"
# jq-based JSON build — FIELD/VALUE are validated but using jq consistently
# across scm_log sites keeps the pattern uniform and immune to any future
# option name containing quote/backslash characters.
scm_log board-set-field "$(jq -nc --argjson issue "$ISSUE" --arg field "$FIELD" --arg value "$VALUE" \
	'{issue: $issue, field: $field, value: $value}')"
