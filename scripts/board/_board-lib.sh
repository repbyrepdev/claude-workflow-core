#!/bin/bash
# v4.21 (#520): shared GraphQL helpers for board/*.sh scripts. Avoids
# copy-pasting the "resolve project number → field IDs" dance across
# five scripts (which guaranteed drift the first time the board fields
# changed shape).
#
# NB: bash 3.2 compatible (macOS default) — no associative arrays.
# Option-name → option-ID lookup is via jq invocation against a cached
# JSON blob rather than shell arrays.

BOARD_PROJECT_NUMBER=2

BOARD_PROJECT_ID=""
BOARD_STATUS_FIELD_ID=""
BOARD_TYPE_FIELD_ID=""
BOARD_AREA_FIELD_ID=""
BOARD_PRIORITY_FIELD_ID=""
BOARD_FIELDS_JSON=""

# Resolve project ID + field IDs in one GraphQL round-trip. Populates
# BOARD_PROJECT_ID, BOARD_*_FIELD_ID, and BOARD_FIELDS_JSON. Call once
# before any field-update mutation.
scm_board_resolve_ids() {
	[ -n "$BOARD_PROJECT_ID" ] && return 0

	local data
	data=$(gh api graphql -f query='
query($num: Int!) {
  viewer {
    projectV2(number: $num) {
      id
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options { id name }
          }
        }
      }
    }
  }
}' -F "num=$BOARD_PROJECT_NUMBER" 2>&1) || {
		echo "scm-board: graphql field-resolve failed: $data" >&2
		return 2
	}
	# Surface GraphQL .errors (HTTP 200 + partial failure) before the
	# null-coerce silently yields "could not resolve project ID".
	if printf '%s' "$data" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
		echo "scm-board: graphql returned .errors: $(printf '%s' "$data" | jq -c .errors)" >&2
		return 2
	fi

	BOARD_PROJECT_ID=$(printf '%s' "$data" | jq -r '.data.viewer.projectV2.id')
	if [ -z "$BOARD_PROJECT_ID" ] || [ "$BOARD_PROJECT_ID" = "null" ]; then
		echo "scm-board: could not resolve project ID for board #$BOARD_PROJECT_NUMBER" >&2
		return 2
	fi
	BOARD_FIELDS_JSON=$(printf '%s' "$data" | jq -c '.data.viewer.projectV2.fields.nodes')

	local field
	for field in Status Type Area Priority; do
		local field_id
		field_id=$(printf '%s' "$BOARD_FIELDS_JSON" | jq -r --arg n "$field" \
			'.[] | select(.name == $n) | .id')
		if [ -z "$field_id" ] || [ "$field_id" = "null" ]; then
			echo "scm-board: field '$field' not found on board" >&2
			return 2
		fi
		# shellcheck disable=SC2034  # exported via name, consumed by sourcing scripts
		case "$field" in
		Status) BOARD_STATUS_FIELD_ID="$field_id" ;;
		Type) BOARD_TYPE_FIELD_ID="$field_id" ;;
		Area) BOARD_AREA_FIELD_ID="$field_id" ;;
		Priority) BOARD_PRIORITY_FIELD_ID="$field_id" ;;
		esac
	done
}

# Look up the option ID for a single-select field value. Caller passes
# the field name (Status/Type/Area/Priority) + the option name
# ("In Progress", "Bug", "Infrastructure", "p1", etc).
#
# Prints option ID on stdout; exits 2 with diagnostic if not found.
scm_board_option_id() {
	local field="${1:?field name required}"
	local value="${2:?option value required}"
	if [ -z "$BOARD_FIELDS_JSON" ]; then
		echo "scm-board: fields not resolved — call scm_board_resolve_ids first" >&2
		return 2
	fi
	local opt_id
	opt_id=$(printf '%s' "$BOARD_FIELDS_JSON" | jq -r \
		--arg f "$field" --arg v "$value" \
		'.[] | select(.name == $f) | .options[] | select(.name == $v) | .id')
	if [ -z "$opt_id" ] || [ "$opt_id" = "null" ]; then
		local valid
		valid=$(printf '%s' "$BOARD_FIELDS_JSON" | jq -r --arg f "$field" \
			'.[] | select(.name == $f) | .options | map(.name) | join(", ")')
		echo "scm-board: option '$value' not valid for field '$field'. Valid: $valid" >&2
		return 2
	fi
	printf '%s' "$opt_id"
}

# Look up an issue's project-item ID on the Homelab board. Returns the
# item node ID on stdout, or empty + exit 1 if the issue isn't on the
# board. Needed for every field-update mutation.
scm_board_item_id_for_issue() {
	local issue_num="${1:?issue number required}"
	# Resolve owner/repo dynamically from gh context — hardcoding breaks
	# on forks/renames. Single `gh repo view` gives both.
	local owner_repo owner repo
	owner_repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>&1) || {
		echo "scm-board: gh repo view failed: $owner_repo" >&2
		return 2
	}
	owner="${owner_repo%/*}"
	repo="${owner_repo#*/}"
	local data
	data=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $num: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $num) {
      projectItems(first: 10) {
        nodes { id project { number } }
      }
    }
  }
}' -f "owner=$owner" -f "repo=$repo" -F "num=$issue_num" 2>&1) || {
		echo "scm-board: graphql item-id lookup failed: $data" >&2
		return 2
	}
	if printf '%s' "$data" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
		echo "scm-board: graphql returned .errors: $(printf '%s' "$data" | jq -c .errors)" >&2
		return 2
	fi
	local item_id
	# `| head -1`: if the issue somehow appears on the board twice (manual
	# duplicate add, migration artifact), downstream GraphQL mutations
	# can't accept a newline-separated ID — take the first and treat
	# the duplicate as an operator problem to clean up separately.
	item_id=$(printf '%s' "$data" | jq -r --argjson num "$BOARD_PROJECT_NUMBER" \
		'.data.repository.issue.projectItems.nodes[] | select(.project.number == $num) | .id' | head -1)
	if [ -z "$item_id" ] || [ "$item_id" = "null" ]; then
		echo "scm-board: issue #$issue_num not found on board #$BOARD_PROJECT_NUMBER" >&2
		return 1
	fi
	printf '%s' "$item_id"
}
