#!/bin/bash
set -euo pipefail
# v4.21 (#520): link a child issue as a sub-issue of a parent via GraphQL
# addSubIssue mutation. Verifies the link after creation so silent failures
# (e.g., GraphQL returning 200 + .errors) surface loudly.
#
# Thin wrapper: the actual GraphQL logic lives in skc_graphql_add_sub_issue
# in .claude/skills/_lib/skill-common.sh — this script exposes it as a
# standalone CLI so non-skill callers (scripts, ad-hoc invocations) can use it.
#
# Usage:
#   .claude/scripts/board/link-parent.sh <child-num> <parent-num> [--dry-run]
#
# Examples:
#   .claude/scripts/board/link-parent.sh 533 520
#   .claude/scripts/board/link-parent.sh 533 520 --dry-run

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../_common.sh
source "$REPO_ROOT/.claude/scripts/_common.sh"
# shellcheck source=../../skills/_lib/skill-common.sh
source "$REPO_ROOT/.claude/skills/_lib/skill-common.sh"

SCM_DRY_RUN=0
ARGS=()
for arg in "$@"; do
	if [ "$arg" = "--dry-run" ]; then
		SCM_DRY_RUN=1
	else
		ARGS+=("$arg")
	fi
done

[ "${#ARGS[@]}" -eq 2 ] || scm_fail "usage: $0 <child-num> <parent-num> [--dry-run]"
CHILD="${ARGS[0]}"
PARENT="${ARGS[1]}"

[[ "$CHILD" =~ ^[0-9]+$ ]] || scm_fail "child must be numeric; got '$CHILD'"
[[ "$PARENT" =~ ^[0-9]+$ ]] || scm_fail "parent must be numeric; got '$PARENT'"
[ "$CHILD" != "$PARENT" ] || scm_fail "child and parent must differ"

if [ "$SCM_DRY_RUN" = "1" ]; then
	echo "[dry-run] would link #$CHILD as sub-issue of #$PARENT"
	echo "  (verify pre-condition: both issues exist + neither already linked)"
	exit 0
fi

echo "Linking #$CHILD as sub-issue of #$PARENT..."
skc_graphql_add_sub_issue "$CHILD" "$PARENT"
echo "✓ linked #$CHILD → #$PARENT"
scm_log board-link-parent "$(printf '{"child":%s,"parent":%s}' "$CHILD" "$PARENT")"
