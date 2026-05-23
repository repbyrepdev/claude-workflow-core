#!/bin/bash
set -euo pipefail
# v4.21 (#520): assign self to an issue and verify the auto-move to
# "In Progress" fires (project-automation.yml trigger on issues.assigned).
# With ACTIONS_MODE=local the trigger doesn't fire remotely, so this
# script invokes the local replica after the assignment.
#
# Usage:
#   .claude/scripts/board/assign-self.sh <issue-num> [--dry-run] [--skip-move]
#
# Flags:
#   --skip-move   skip the Status=In Progress move (useful for parent
#                 epics whose assignment shouldn't auto-advance Status)
#
# Examples:
#   .claude/scripts/board/assign-self.sh 520
#   .claude/scripts/board/assign-self.sh 520 --dry-run
#   .claude/scripts/board/assign-self.sh 519 --skip-move

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

SCM_DRY_RUN=0
SKIP_MOVE=0
ARGS=()
for arg in "$@"; do
	case "$arg" in
	--dry-run) SCM_DRY_RUN=1 ;;
	--skip-move) SKIP_MOVE=1 ;;
	*) ARGS+=("$arg") ;;
	esac
done

[ "${#ARGS[@]}" -eq 1 ] || scm_fail "usage: $0 <issue-num> [--dry-run] [--skip-move]"
ISSUE="${ARGS[0]}"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || scm_fail "issue must be numeric; got '$ISSUE'"

# Check current assignment state — idempotent skip if already assigned.
ME=$(gh api user --jq .login 2>&1) || scm_fail "gh api user failed: $ME"
# Ask jq directly whether $ME is in the assignee list — avoids substring
# false-positives (e.g., "alice" matching "alice-bot") that a grep on a
# comma-joined string would risk.
# Split gh + jq into separate commands: piping `gh ... 2>&1 | jq` would
# feed gh's error output into jq on failure, and the script would report
# jq's parse error instead of gh's real cause (auth expired, 404, etc).
if ! RAW=$(gh issue view "$ISSUE" --json assignees 2>&1); then
	scm_fail "gh issue view failed for #$ISSUE: $RAW"
fi
CUR_ASSIGNED=$(printf '%s' "$RAW" | jq -r --arg me "$ME" \
	'[.assignees[].login] | any(. == $me)') ||
	scm_fail "jq parse failed on gh issue view output: $RAW"

if [ "$CUR_ASSIGNED" = "true" ]; then
	echo "ℹ #$ISSUE already assigned to $ME (idempotent skip)"
	ALREADY_ASSIGNED=1
else
	ALREADY_ASSIGNED=0
fi

if [ "$SCM_DRY_RUN" = "1" ]; then
	if [ "$ALREADY_ASSIGNED" = "1" ]; then
		echo "[dry-run] no-op (already assigned)"
	else
		echo "[dry-run] would: gh issue edit $ISSUE --add-assignee @me"
		[ "$SKIP_MOVE" = "0" ] && echo "[dry-run] would: board/move-item.sh $ISSUE 'In Progress'"
	fi
	exit 0
fi

if [ "$ALREADY_ASSIGNED" = "0" ]; then
	scm_run gh issue edit "$ISSUE" --add-assignee "@me" >/dev/null
	echo "✓ assigned #$ISSUE to @me"
fi

# Replicate the project-automation.yml "In Progress on assign" behavior
# unless --skip-move. Parent epics typically want --skip-move so their
# board row doesn't advance prematurely while sub-issue work is ongoing.
MOVE_OUTCOME="skipped"
if [ "$SKIP_MOVE" = "0" ]; then
	# v4.24-B (#567) wire-in: prefer project-board-sync.sh --on-assign
	# over bare move-item.sh — the former ALSO dual-writes Priority / Area
	# / Type board fields from labels (ai-triage-yml-equivalent under the
	# Actions cap). Fall back to bare move when project-board-sync isn't
	# available so this script stays resilient on minimal setups.
	BOARD_SYNC="$REPO_ROOT/.claude/local-backups/project-board-sync.sh"
	sync_out=""
	sync_rc=0
	if [ -x "$BOARD_SYNC" ]; then
		sync_out=$("$BOARD_SYNC" --on-assign "$ISSUE" 2>&1) || sync_rc=$?
	else
		sync_rc=127
	fi
	if [ "$sync_rc" = "0" ] && [ -x "$BOARD_SYNC" ]; then
		MOVE_OUTCOME="ok"
	elif "$SCRIPT_DIR/move-item.sh" "$ISSUE" "In Progress"; then
		MOVE_OUTCOME="ok-fallback"
		# Surface the project-board-sync failure so the fallback isn't silent.
		[ -n "$sync_out" ] && scm_warn "project-board-sync fell back to move-item on #$ISSUE (rc=$sync_rc): $(printf '%s' "$sync_out" | head -1)"
	else
		MOVE_OUTCOME="failed"
		scm_warn "board sync failed on #$ISSUE — assignment succeeded but Status/fields not updated${sync_out:+: $(printf '%s' "$sync_out" | head -1)}"
	fi
fi

# Log outcome (including partial-success state where assign succeeded
# but move failed) so JSONL consumers can detect the half-state even
# though the script exits 0 for idempotency. Build JSON via jq so string
# values can't break the escape (MOVE_OUTCOME is a known enum today but
# the pattern generalizes).
scm_log board-assign-self "$(jq -nc \
	--argjson issue "$ISSUE" --argjson skip "$SKIP_MOVE" \
	--argjson already "$ALREADY_ASSIGNED" --arg move "$MOVE_OUTCOME" \
	'{issue: $issue, skip_move: $skip, already: $already, move: $move}')"
