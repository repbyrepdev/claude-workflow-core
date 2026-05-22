#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# PreToolUse hook for Bash — warns when a gh query that returns a list is invoked
# without an explicit --limit, because the defaults are small (30 for projects, 30
# for PRs, 30 for issues) and silently hide work on any board with >30 total items.
#
# Real bug this prevents: declaring the board "clean" while 4 In Progress items
# were invisible past the default cutoff.

command -v jq >/dev/null 2>&1 || exit 0

# `cat` rarely fails reading stdin, but a closed/broken-pipe stdin under
# `set -e` would abort the hook before the empty-COMMAND no-op below could
# fire. `|| INPUT=""` keeps the advisory contract (exit 0, print warning if
# applicable, otherwise pass through) regardless of stdin state.
INPUT=$(cat) || INPUT=""
# Empty stdin would otherwise produce a misleading "malformed JSON" warning;
# normalize to `{}` so jq sees valid input and stderr only fires on real
# parse failures (caller-pipe/double-cat/etc.).
[ -z "$INPUT" ] && INPUT="{}"
# Diagnostic to stderr keeps the failure visible (advisory exit-0 contract).
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
	echo "check-gh-limits: jq parse failed (malformed JSON?) — skipping" >&2
	COMMAND=""
}
[ -z "$COMMAND" ] && exit 0

# Match the three list-style gh commands that paginate.
# v4.28-W2 (#653): `gh project item-list` ALWAYS gets the lib advice now —
# even with --limit 500, GitHub caps the response at 500 items (Homelab
# board hit it 2026-04-27, silently truncating 9 newly-filed sub-issues).
# Only paginated GraphQL is correct.
NEEDS_LIMIT=0
case "$COMMAND" in
*"gh project item-list"*)
	NEEDS_LIMIT=1
	REASON="gh project item-list caps at 500 items even with --limit 500 (Homelab board hit cap 2026-04-27, #653)"
	FIX="use .claude/_lib/board-paginate.sh (board_paginate_open_items <owner> <number>) or .claude/scripts/board/list-non-done.sh — both loop pageInfo.hasNextPage so no item is silently dropped"
	;;
*"gh pr list"* | *"gh issue list"*)
	case "$COMMAND" in
	*" --limit "*) ;;
	*)
		NEEDS_LIMIT=1
		REASON="gh pr/issue list default is 30"
		FIX="add --limit 100 (or higher) to see everything that matters"
		;;
	esac
	;;
esac

if [ "$NEEDS_LIMIT" = "1" ]; then
	cat <<EOF | jq -Rs '{additionalContext: .}'
WARNING: '$COMMAND' will return a truncated result. $REASON. $FIX. Aborting and using the recommended approach is strongly preferred — do NOT rely on the truncated result for any 'board clean' / 'nothing open' assertions.
EOF
fi

exit 0
