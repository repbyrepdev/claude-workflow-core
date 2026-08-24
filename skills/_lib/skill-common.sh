#!/bin/bash
set -euo pipefail
# v4.20 (#519): shared helpers for `.claude/skills/*/run.sh` wrappers.
#
# WHY this exists: each wrapper needs the same 6-8 helpers (repo owner/name,
# version prefix extraction, milestone matching, label resolution from
# labeler.yml, template reading, sub-issue GraphQL linking, user approval
# gate). Extracting them into one source prevents drift (e.g. one wrapper's
# milestone matcher diverging from another's) and keeps the wrappers short
# enough to audit at a glance.
#
# Usage: source "$(dirname "$0")/../_lib/skill-common.sh"
#
# IMPORTANT: functions exit non-zero on error. Callers should `set -e` so
# helper failures propagate without silent-continuation.

# Resolve repo owner/name from the active remote. Used by GraphQL mutations
# that require the canonical owner/name (not path-munged slugs).
# Prints "owner/name" on stdout; exits 2 on failure.
skc_repo_owner_name() {
	local slug
	if ! slug=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null); then
		echo "skc: gh repo view failed — is gh authed and are you in a repo?" >&2
		return 2
	fi
	if [ -z "$slug" ]; then
		echo "skc: empty nameWithOwner from gh repo view" >&2
		return 2
	fi
	printf '%s' "$slug"
}

# Extract version prefix from a branch name like `feat/v4.20/wrappers-...`
# or `v4.20.G`. Prints "v4.20" on stdout; empty string if no version found.
# Never exits non-zero — absent version is a valid case (main, no-version
# branches) that the caller decides how to handle.
skc_extract_version_prefix() {
	local input="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')}"
	# Match v<major>.<minor> (without patch/letter). feat/v4.20/... → v4.20.
	# head -n1 picks the first match for branches containing multiple
	# version-shaped substrings (e.g. "feat/v4.20/v3.9-compat-shim" returns v4.20).
	printf '%s' "$input" | grep -oE 'v[0-9]+\.[0-9]+' | head -n1 || true
}

# Escape regex metacharacters in a version-prefix string for safe embedding
# in a jq regex (literal "." matters: otherwise prefix "v4.1" matches
# milestone "v4.10" because "." matches any char). Only escapes chars
# version-prefix strings ('vN.M') can plausibly contain — NOT a general-
# purpose regex escaper; do not reuse for arbitrary input.
# Extracted from skc_match_milestone so the escape logic is unit-testable
# without a jq-evaluating stub.
skc_escape_version_prefix() {
	printf '%s' "${1:-}" | sed 's/[.[\*^$/]/\\&/g'
}

# Find the open milestone whose title contains the given version prefix.
# Prints the milestone title on stdout (exact match as returned by gh).
# Exits 2 if no match or multiple matches (ambiguous).
# Empty-version input is treated as "no milestone wanted" and prints empty.
skc_match_milestone() {
	local prefix="${1:-}"
	[ -z "$prefix" ] && return 0
	# Escape regex metacharacters via the extracted helper (testable unit).
	# The helper returns single-backslash (regex-level, e.g. `v4\.1`). We
	# embed that into a jq STRING literal via `--jq`, and jq's string
	# grammar rejects `\.` as an invalid escape — so double every `\` for
	# the jq string layer. Trying to parse `"v4\.1"` in jq raises
	# "invalid escape sequence \."; we need `"v4\\.1"` which jq reads as
	# regex `v4\.1`. Shell param expansion `${v//\\/\\\\}` does the doubling.
	local escaped
	escaped=$(skc_escape_version_prefix "$prefix")
	local jq_escaped="${escaped//\\/\\\\}"
	local matches
	matches=$(gh api "repos/:owner/:repo/milestones?state=open&per_page=100" \
		--jq "[.[] | select(.title | test(\"(^| )${jq_escaped}(\\\\.|$| )\")) | .title]") || return 2
	# Defensive: ensure jq returned a JSON array before calling length.
	if ! printf '%s' "$matches" | jq -e 'type == "array"' >/dev/null 2>&1; then
		echo "skc: milestone query returned non-array — gh or jq failed" >&2
		return 2
	fi
	local count
	count=$(printf '%s' "$matches" | jq 'length')
	if [ "$count" = "0" ]; then
		echo "skc: no open milestone matches prefix '$prefix'" >&2
		return 2
	fi
	if [ "$count" != "1" ]; then
		echo "skc: $count open milestones match prefix '$prefix' — ambiguous:" >&2
		printf '%s' "$matches" | jq -r '.[] | "  - " + .' >&2
		return 2
	fi
	printf '%s' "$matches" | jq -r '.[0]'
}

# NOTE: label resolution from paths is NOT done client-side. The repo's
# `pr-labeler.yml` workflow + the `labeler.yml` path globs apply area:*
# labels server-side on PR open. Duplicating that logic in bash risks
# drift (labeler.yml glob semantics ≠ bash regex). Wrappers pass no
# default labels and rely on pr-labeler.yml.

# Read a GitHub issue template and extract the "description" YAML field as
# the body starter. Returns empty for missing name or missing template file;
# fatals (via set -e) on yq invocation failure so yq-missing / schema-change
# surfaces instead of silently becoming empty.
# Arg: template name (e.g. "bug", "feature", "task", "epic").
skc_read_template() {
	local name="${1:-}"
	[ -z "$name" ] && return 0
	local path=".github/ISSUE_TEMPLATE/${name}.yml"
	[ -f "$path" ] || return 0
	# Let yq stderr through so yq-missing / schema-change surfaces. Exit
	# code 0 only when yq truly returned empty (no textarea bodies).
	yq -r '.body[] | select(.type == "textarea") | .attributes.value // empty' "$path"
}

# Link a newly-created issue to a parent via GraphQL addSubIssue mutation.
# Args: $1 = new issue number, $2 = parent issue number.
# Exits 2 on any GraphQL error or if either issue can't be found.
skc_graphql_add_sub_issue() {
	local new_num="${1:-}"
	local parent_num="${2:-}"
	if ! [[ $new_num =~ ^[0-9]+$ ]] || ! [[ $parent_num =~ ^[0-9]+$ ]]; then
		echo "skc: skc_graphql_add_sub_issue <new-num> <parent-num>" >&2
		return 2
	fi
	# Resolve node IDs via GraphQL (not REST node_id — legacy node_ids pre-date
	# the new global-relay-id format that addSubIssue requires).
	local owner_name owner name
	owner_name=$(skc_repo_owner_name) || return 2
	owner="${owner_name%/*}"
	name="${owner_name#*/}"
	local new_node parent_node
	# GraphQL-Features: sub_issues header required for addSubIssue mutation
	# (feature is still GA-gated; without the header gh returns a schema error).
	new_node=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query="{ repository(owner: \"$owner\", name: \"$name\") { issue(number: $new_num) { id } } }" --jq '.data.repository.issue.id' 2>/dev/null) || {
		echo "skc: could not resolve GraphQL id for issue $new_num" >&2
		return 2
	}
	parent_node=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query="{ repository(owner: \"$owner\", name: \"$name\") { issue(number: $parent_num) { id } } }" --jq '.data.repository.issue.id' 2>/dev/null) || {
		echo "skc: could not resolve GraphQL id for issue $parent_num" >&2
		return 2
	}
	if [ -z "$new_node" ] || [ -z "$parent_node" ]; then
		echo "skc: empty GraphQL id for issue $new_num or $parent_num" >&2
		return 2
	fi
	local result
	result=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query="mutation { addSubIssue(input: {issueId: \"$parent_node\", subIssueId: \"$new_node\"}) { issue { number } } }" 2>&1) || {
		echo "skc: addSubIssue mutation failed: $result" >&2
		return 2
	}
	# Explicit .errors check — GraphQL returns HTTP 200 + errors JSON for
	# partial/stale failures (not caught by the `||` above).
	if printf '%s' "$result" | jq -e '.errors' >/dev/null 2>&1; then
		echo "skc: addSubIssue returned errors: $(printf '%s' "$result" | jq -c '.errors')" >&2
		return 2
	fi
	# Success if the parent number comes back.
	printf '%s' "$result" | jq -e '.data.addSubIssue.issue.number' >/dev/null || {
		echo "skc: addSubIssue returned no parent number: $result" >&2
		return 2
	}
}

# Prompt user for go/no-go approval on an action. Reads a single line from
# stdin. Accepts "y"/"yes" (case-insensitive) → return 0. Anything else →
# print cancel message and return 2 (caller should exit). If stdin is not
# a TTY (non-interactive run), requires either the `--yes` flag (preferred)
# or APPROVE=1 in the environment.
#
# #2544 — WHY `--yes` EXISTS. `APPROVE=1 <cmd>` is an env-var-PREFIX
# invocation, which is byte-identical in shape to the `BASH_ENV=<payload>
# <cmd>` arbitrary-code-execution pattern. Agent tool-call classifiers block
# that shape on sight, and they are right to. The consequence was absurd: our
# own approval mechanism was written in the one syntax an agent is
# structurally forbidden from typing, so every issue / PR / merge required a
# human to paste the command — in a workflow whose entire purpose is running
# without one.
#
# `SKC_ASSUME_YES` is set by the wrapper AFTER it parses `--yes` from its own
# argv. It is an ordinary shell variable assigned inside the script, never an
# env prefix on the command line, so it carries none of that shape.
# APPROVE=1 is retained for humans and existing scripts.
#
# An INHERITED value is discarded at source time (#2544 phase2): a parent
# process exporting SKC_ASSUME_YES=1 auto-approved every wrapper without
# --yes ever being typed — the same env-prefix bypass the flag exists to
# replace, and the log line even claimed "via --yes". Every wrapper sources
# this lib BEFORE parsing argv, so clearing here can never clobber a real
# --yes. `unset` (not =0) also drops an inherited export attribute, so the
# stale value cannot ride into child processes either.
unset SKC_ASSUME_YES

skc_approve_or_exit() {
	local prompt="${1:-Proceed?}"
	if [ "${SKC_ASSUME_YES:-0}" = "1" ]; then
		echo "skc: auto-approved via --yes" >&2
		return 0
	fi
	if [ ! -t 0 ]; then
		if [ "${APPROVE:-0}" = "1" ]; then
			echo "skc: auto-approved via APPROVE=1 (non-interactive)" >&2
			return 0
		fi
		echo "skc: non-interactive run without --yes (or APPROVE=1) — refusing" >&2
		return 2
	fi
	printf '%s [yes/no] ' "$prompt"
	local answer
	# Handle EOF explicitly — bare `read -r` returns non-zero on EOF,
	# which under `set -e` terminates the caller instead of routing to
	# the cancel path. Treat EOF / empty input as refusal.
	if ! read -r answer; then
		echo "" >&2
		echo "skc: EOF on prompt — treating as decline" >&2
		return 2
	fi
	# Lowercase via tr for bash 3.2 compat (macOS default) — ${var,,} is bash 4+.
	case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
	y | yes) return 0 ;;
	*)
		echo "skc: user declined — aborting" >&2
		return 2
		;;
	esac
}
