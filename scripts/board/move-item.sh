#!/bin/bash
set -euo pipefail
# v4.21 (#520): move an issue between board columns (Status field).
# Thin wrapper over set-field.sh that validates the column name against
# the Status single-select options.
#
# Usage:
#   .claude/scripts/board/move-item.sh <issue-num> <column> [--dry-run]
#
# Columns: the authoritative list is the Homelab board's Status single-
# select options, resolved at runtime by scm_board_resolve_ids in
# _board-lib.sh. Current options (verify via `board/audit.sh --json`):
#   Backlog | Ready | In Progress | Review | Done
#
# Examples:
#   .claude/scripts/board/move-item.sh 520 "In Progress"
#   .claude/scripts/board/move-item.sh 520 Done --dry-run

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

SCM_DRY_RUN=0
ARGS=()
for arg in "$@"; do
	if [ "$arg" = "--dry-run" ]; then
		SCM_DRY_RUN=1
	else
		ARGS+=("$arg")
	fi
done

[ "${#ARGS[@]}" -eq 2 ] || scm_fail "usage: $0 <issue-num> <column> [--dry-run]"
ISSUE="${ARGS[0]}"
COLUMN="${ARGS[1]}"
# Validate locally in addition to set-field.sh's check — catches obvious
# typos before the exec hands control off (better error locality).
[[ "$ISSUE" =~ ^[0-9]+$ ]] || scm_fail "issue must be numeric; got '$ISSUE'"

# Delegate to set-field.sh with field=Status. Preserves --dry-run semantics
# because set-field.sh has its own --dry-run handling. A direct mutation here
# would duplicate validation + the GraphQL call — composing is cleaner.
# Branch explicitly on dry-run rather than building a FLAGS=() array +
# expanding `"${FLAGS[@]}"` — an empty array expansion trips set -u on
# bash 3.2 (macOS default) and crashes BEFORE exec runs.
if [ "$SCM_DRY_RUN" = "1" ]; then
	exec "$SCRIPT_DIR/set-field.sh" "$ISSUE" Status "$COLUMN" --dry-run
else
	exec "$SCRIPT_DIR/set-field.sh" "$ISSUE" Status "$COLUMN"
fi
