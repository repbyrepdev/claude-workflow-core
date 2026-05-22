#!/bin/bash
set -euo pipefail
# v4.28-W2 (#653): list non-Done board items via paginated GraphQL.
# Replacement for `gh project item-list 2 --owner @me --limit 500 --format
# json` which silently truncates at 500 items (the Homelab board hit that
# cap on 2026-04-27).
#
# Output format: tabular text matching the prior session-start skill's
# python3 formatter, so the skill's downstream consumers don't need to
# change.
#
# Usage:
#   .claude/scripts/board/list-non-done.sh [--owner LOGIN] [--number N]
#
# Defaults: owner=current `gh` user, number=2 (Homelab).

# shellcheck disable=SC2034  # REPO_ROOT kept for ABI; libs source via plugin-relative paths now
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../_lib/board-paginate.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../_lib/board-paginate.sh"

OWNER=""
NUMBER=2
while [ "$#" -gt 0 ]; do
	case "$1" in
	--owner)
		if [ "$#" -lt 2 ]; then
			echo "error: --owner requires a value" >&2
			exit 2
		fi
		OWNER=$2
		shift 2
		;;
	--number)
		if [ "$#" -lt 2 ]; then
			echo "error: --number requires a value" >&2
			exit 2
		fi
		NUMBER=$2
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		echo "error: unknown arg '$1'" >&2
		exit 2
		;;
	esac
done

# Default OWNER to current gh user if not specified.
if [ -z "$OWNER" ]; then
	# Phase 2 cr-cli r4 (#653): capture gh stderr instead of swallowing
	# it — surfacing the real error (auth missing, network, rate limit)
	# with the wrapper's diagnostic helps the operator fix the actual
	# problem instead of guessing.
	# Phase 2 cr-cli r6 (#653): trap-cleanup tempfile so SIGINT/SIGTERM
	# mid-run doesn't leak it.
	gh_err=$(mktemp)
	trap 'rm -f "$gh_err"' EXIT
	if ! OWNER=$(gh api user --jq '.login' 2>"$gh_err"); then
		echo "error: cannot resolve current gh user; pass --owner explicitly" >&2
		[ -s "$gh_err" ] && cat "$gh_err" >&2
		exit 2
	fi
fi

# Fetch all items, filter to non-Done, format as: [Status] [Priority] #N title
# Phase 2 cr-cli (#653): null-coalesce content fields — draft items / malformed
# ProjectV2 items have empty content {} which would render as "#null null".
BOARD_PAGINATE_FILTER_DONE=1 board_paginate_open_items "$OWNER" "$NUMBER" |
	jq -r '
		. as $i
		| ([.fieldValues.nodes[]? | select(.field.name == "Status") | .name] | .[0] // "?") as $status
		| ([.fieldValues.nodes[]? | select(.field.name == "Priority") | .name] | .[0] // "—") as $priority
		| ($i.content.number // "?") as $num
		| ($i.content.title // "(draft item)") as $title
		| "  [\($status | (.[:12] + (" " * (12 - (.[:12] | length))))[:12])] [\($priority | (.[:6] + (" " * (6 - (.[:6] | length))))[:6])] #\($num) \($title)"
	'
