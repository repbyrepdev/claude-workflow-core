#!/bin/bash
set -u
# v4.28-W2 (#653): shared paginated-board-fetch helper.
#
# WHY this lib exists:
# `gh project item-list --limit 500` returns at most 500 items in a single
# page. As of 2026-04-27 the Homelab board has 500+ items (capped exactly at
# 500), so the wrapper silently truncates new issues that fall beyond the
# first page. Two callers consumed the broken wrapper:
#   - .claude/skills/session-start/SKILL.md (daily hot path)
#   - .claude/hooks/board-drift-reconcile.sh
#
# Defense-in-depth fix:
#   1. FILTER at API: only fetch non-Done items (or whatever subset matters).
#      Usually keeps the result under one page.
#   2. PAGINATE via `pageInfo.hasNextPage` + `endCursor` cursor loop. Bullet-
#      proof against the rare case the OPEN/non-Done set itself exceeds 500.
#
# This file is sourced (not executed). No `set -e` here; callers own strict-
# mode setup. `set -u` is required by .claude/hooks/bash-safety-write-guard.sh.
#
# shellcheck shell=bash

# Fetch every item from a ProjectV2 board, transparently looping pages.
#
# IMPORTANT — function name vs contract:
# The name `board_paginate_open_items` is historical (from the v4.28-W2
# session-start-skill rewrite). The function actually returns ALL items
# (Done + non-Done) by default. Set `BOARD_PAGINATE_FILTER_DONE=1` to
# drop Done items client-side. Two callers depend on this:
#   - board-drift-reconcile.sh: needs ALL items (must see Done-state
#     issues to detect status drift) — calls without filter env
#   - list-non-done.sh: needs non-Done — sets BOARD_PAGINATE_FILTER_DONE=1
# Phase 1 r1 code-reviewer (#653) flagged the misleading name; we
# preserved the historical name for back-compat with existing scripts
# but documented the contract here so callers know.
#
# Phase 1 r3 critical bug fix (#653): `user(login: $owner).projectV2`
# only returns PUBLIC projects — private boards (the Homelab use case)
# return totalCount=0 with no error, silently breaking pagination for
# every authenticated-user-private-board caller. Fix: detect when
# $owner == current viewer login and route to `viewer.projectV2` which
# resolves private boards with full read access. Other-owner queries
# fall back to `user(login:)` (still public-only — org boards needed
# in future would require `organization(login:)` branch).
#
# Args:
#   $1 — project owner (user login — NOT org)
#   $2 — project number (integer)
# Optional env:
#   BOARD_PAGINATE_PAGE_SIZE — items per page (default 100, max 100 per
#                              GitHub GraphQL limit)
#   BOARD_PAGINATE_FILTER_DONE — set to 1 to skip Status=Done items
#                                client-side after fetch
#
# Output: JSONL stream on stdout, one item per line. Each line is the raw
# GraphQL ProjectV2Item shape with fields:
#   {id, content: {number, title, state}, status, priority, fieldValues: [...]}
#
# Returns 0 on success, non-zero if any page errors.
board_paginate_open_items() {
	# Phase 2 cr-cli r5 (#653): arg-count guard avoids cryptic "unbound
	# variable" under set -u when caller forgets one or both args.
	if [ $# -lt 2 ]; then
		echo "board_paginate_open_items: requires 2 args (owner, number); got $#" >&2
		return 1
	fi
	local owner=$1 number=$2
	local page_size="${BOARD_PAGINATE_PAGE_SIZE:-100}"
	local cursor='' has_next='true' resp items

	# Determine which GraphQL root to query. `viewer` reads private boards
	# of the authenticated user. `user(login:)` is public-only. If $owner
	# matches the current viewer login, use `viewer` so private boards
	# work; otherwise fall back to `user(login:)` (public-only, org
	# boards out of scope for now).
	#
	# GraphQL rejects unused variables, so when using `viewer` we omit
	# the $owner declaration entirely.
	local viewer_login query_root root_key query_signature owner_arg=()
	viewer_login=$(gh api user --jq '.login' 2>/dev/null) || {
		# Phase 2 cr-cli r3 (#653): if a token is present, fail-loud —
		# token-was-provided-but-call-failed is a real auth/network
		# error that shouldn't silently degrade. Only fall back when
		# explicitly unauthenticated (no GH_TOKEN/GITHUB_TOKEN/no gh
		# auth).
		if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ] || gh auth status >/dev/null 2>&1; then
			echo "board-paginate: ERROR: gh api user failed despite token presence — auth/network failure, refusing to silently fall back to public-only path" >&2
			return 1
		fi
		echo "board-paginate: warning: no auth token present — falling back to user(login:) which is public-only" >&2
		viewer_login=""
	}
	if [ -n "$viewer_login" ] && [ "$owner" = "$viewer_login" ]; then
		query_root='viewer'
		root_key='viewer'
		query_signature='($number: Int!)'
	else
		query_root="user(login: \$owner)"
		root_key='user'
		query_signature='($owner: String!, $number: Int!)'
		owner_arg=(-F "owner=$owner")
	fi

	while [ "$has_next" = "true" ]; do
		# `gh api graphql` with cursor parameter. First call uses null cursor
		# (fetches page 1), subsequent calls use the previous response's
		# endCursor.
		local cursor_arg='null'
		if [ -n "$cursor" ]; then
			cursor_arg="\"$cursor\""
		fi
		# Phase 1 r3 (#653): GitHub GraphQL was observed returning
		# nodes:[] hasNextPage:false intermittently for the same query
		# (3 sequential calls: 0/587/0 items). Retry up to 3 times with
		# 500ms backoff when we get an empty-nodes response. Real fix
		# beats "accept the API glitch as correct."
		local attempt=0 max_attempts="${BOARD_PAGINATE_MAX_RETRIES:-3}" got_data="false"
		while [ "$attempt" -lt "$max_attempts" ]; do
			attempt=$((attempt + 1))
			resp=$(gh api graphql -f query="
				query $query_signature {
					$query_root {
						projectV2(number: \$number) {
							items(first: $page_size, after: $cursor_arg) {
								pageInfo { hasNextPage endCursor }
								nodes {
									id
									content { ... on Issue { number title state } ... on PullRequest { number title state } }
									fieldValues(first: 20) {
										nodes {
											... on ProjectV2ItemFieldSingleSelectValue {
												field { ... on ProjectV2SingleSelectField { name } }
												name
											}
										}
									}
								}
							}
						}
					}
				}" ${owner_arg[@]+"${owner_arg[@]}"} -F number="$number" 2>&1) || {
				# Phase 1 r1 silent-failure-hunter (#653): when gh api errors,
				# stderr was captured into $resp via 2>&1 and the function
				# returned 1 silently. The error message is buried in $resp
				# and never surfaced unless a downstream jq parse also fails.
				# Surface it explicitly before returning.
				echo "board-paginate: gh api graphql failed. Response (first 500 chars):" >&2
				printf '%s\n' "${resp:0:500}" >&2
				return 1
			}
			# Validate GraphQL response structure before proceeding.
			# Check for top-level "errors" array first.
			if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
				echo "board-paginate: GraphQL returned errors. Response (first 500 chars):" >&2
				printf '%s\n' "${resp:0:500}" >&2
				return 1
			fi
			# Assert that .data.${root_key}.projectV2 exists and is non-null.
			if ! echo "$resp" | jq -e ".data.${root_key}.projectV2" >/dev/null 2>&1; then
				echo "board-paginate: GraphQL response missing .data.${root_key}.projectV2. Response (first 500 chars):" >&2
				printf '%s\n' "${resp:0:500}" >&2
				return 1
			fi
			# Assert that .data.${root_key}.projectV2.items exists and is non-null.
			if ! echo "$resp" | jq -e ".data.${root_key}.projectV2.items" >/dev/null 2>&1; then
				echo "board-paginate: GraphQL response missing .data.${root_key}.projectV2.items. Response (first 500 chars):" >&2
				printf '%s\n' "${resp:0:500}" >&2
				return 1
			fi
			# Quick check: did this response have any nodes? If yes,
			# accept; if no AND we have retries left, sleep and retry
			# (the GH API glitch returns nodes:[] but a re-call usually
			# returns the real data).
			if echo "$resp" | jq -e ".data.${root_key}.projectV2.items.nodes | length > 0" >/dev/null 2>&1; then
				got_data="true"
				break
			fi
			# Empty nodes — only retry if we haven't exhausted attempts.
			# Don't sleep on the last attempt.
			if [ "$attempt" -lt "$max_attempts" ]; then
				echo "board-paginate: got nodes:[] on attempt $attempt/$max_attempts (likely GH API transient — retrying after 500ms)" >&2
				sleep 0.5
			fi
		done
		if [ "$got_data" = "false" ]; then
			# All retries returned empty. Check if the last response
			# indicated more pages exist. If hasNextPage=true but we got
			# no nodes after all retries, that's an error condition.
			local resp_has_next
			if resp_has_next=$(echo "$resp" | jq -r ".data.${root_key}.projectV2.items.pageInfo.hasNextPage // false" 2>/dev/null) && [ "$resp_has_next" = "true" ]; then
				echo "board-paginate: ERROR: hasNextPage=true but $attempt consecutive retries returned empty nodes (API failure, not terminal exhaustion). Cursor: ${cursor:-null}" >&2
				return 1
			fi
			# hasNextPage=false or extraction failed — terminal exhaustion is
			# legitimate (board may genuinely have 0 items at this cursor).
			[ "$attempt" -gt 1 ] && echo "board-paginate: $attempt consecutive empty-nodes responses; treating as legit-empty (board may genuinely have 0 items at this cursor)" >&2
		fi
		# Extract items + paginate. Phase 0.5 #645 dogfood (2026-04-27):
		# silently returning rc=1 on jq parse failure left operators
		# guessing why pagination failed.
		# Phase 1 r3 silent-failure-hunter (#653): also capture jq's own
		# stderr (was 2>/dev/null) so operators see WHY jq failed (parse
		# error message + line/col) on top of the response-prefix preview.
		local items_err
		items_err=$(mktemp)
		if ! items=$(echo "$resp" | jq -c ".data.${root_key}.projectV2.items.nodes[]?" 2>"$items_err"); then
			echo "board-paginate: jq failed to extract .nodes from GraphQL response." >&2
			echo "  jq stderr:" >&2
			sed 's/^/    /' "$items_err" >&2
			echo "  Response prefix: ${resp:0:200}" >&2
			rm -f "$items_err"
			return 1
		fi
		rm -f "$items_err"
		if [ "${BOARD_PAGINATE_FILTER_DONE:-0}" = "1" ]; then
			# Drop items whose Status field == "Done".
			# Phase 1 r2 silent-failure-hunter (#653): when per-item jq
			# fails (broken item shape), the caller explicitly asked for
			# filtering — so emitting unfiltered would silently violate
			# the FILTER_DONE=1 contract (Done items would slip through).
			# Err on the side of DROPPING the unparseable item with a
			# loud per-item stderr diagnostic so the operator knows.
			# Phase 2 cr-cli r3 (#653): mktemp ONCE outside the loop +
			# truncate per iteration via `:>` instead of mktemp+rm per
			# item. Reduces N syscalls to ~2 for boards with 100s of items.
			# Phase 2 cr-cli r6 (#653): use here-string `<<<` instead of
			# pipe so the loop runs in current shell, not a subshell —
			# enables future state-accumulation (e.g., dropped-count) +
			# surfaces tempfile name to outer scope cleanly.
			local status_err
			status_err=$(mktemp)
			while IFS= read -r item; do
				[ -z "$item" ] && continue
				: >"$status_err"
				local status
				if ! status=$(echo "$item" | jq -r '[.fieldValues.nodes[]? | select(.field.name == "Status") | .name] | .[0] // ""' 2>"$status_err"); then
					echo "board-paginate: jq failed to extract Status field; DROPPING item to honor FILTER_DONE=1 contract. jq stderr:" >&2
					cat "$status_err" >&2
					echo "  Item shape: $(printf '%s' "$item" | head -c 200)" >&2
					continue
				fi
				[ "$status" = "Done" ] && continue
				echo "$item"
			done <<<"$items"
			rm -f "$status_err"
		else
			[ -n "$items" ] && echo "$items"
		fi
		# Phase 1 r3 silent-failure-hunter (#653): capture jq stderr on
		# pageInfo extraction failures (was 2>/dev/null). The has_next
		# fallback to "false" silently TERMINATES pagination if jq breaks
		# mid-loop — that's the exact 500-cap silent-truncation class
		# this lib was built to prevent. Surface jq's actual error so
		# operators can see that pagination ended due to parse failure
		# (not natural exhaustion).
		local pageinfo_err
		pageinfo_err=$(mktemp)
		if ! has_next=$(echo "$resp" | jq -r ".data.${root_key}.projectV2.items.pageInfo.hasNextPage // false" 2>"$pageinfo_err"); then
			echo "board-paginate: jq failed to extract pageInfo.hasNextPage — assuming no more pages (results may be truncated)." >&2
			[ -s "$pageinfo_err" ] && {
				echo "  jq stderr:" >&2
				sed 's/^/    /' "$pageinfo_err" >&2
			}
			has_next="false"
		fi
		: >"$pageinfo_err"
		if ! cursor=$(echo "$resp" | jq -r ".data.${root_key}.projectV2.items.pageInfo.endCursor // \"\"" 2>"$pageinfo_err"); then
			echo "board-paginate: jq failed to extract pageInfo.endCursor — empty cursor will trip the defensive guard below." >&2
			[ -s "$pageinfo_err" ] && {
				echo "  jq stderr:" >&2
				sed 's/^/    /' "$pageinfo_err" >&2
			}
			cursor=""
		fi
		rm -f "$pageinfo_err"
		# Defensive: if hasNextPage is true but cursor is empty, we'd loop
		# forever. Bail loud rather than infinite-loop.
		if [ "$has_next" = "true" ] && [ -z "$cursor" ]; then
			echo "board-paginate: hasNextPage=true but endCursor empty — refusing to loop" >&2
			return 1
		fi
	done
}
