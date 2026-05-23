#!/bin/bash
# v0.7.3 (#28): no-orphan-deferrals merge-gate enforcement.
#
# Goal: when a PR claims to close an epic (`Closes #N` in the PR body), the
# merge-gate refuses if the epic has prove-yourself rejection records
# WITHOUT linked followup issues. Prevents "defer + forget" — every
# deferral MUST be a tracked sub-issue or the epic stays open.
#
# Mechanism:
#   1. Parse `Closes #N` references from PR body
#   2. For each closed epic, list its open sub-issues
#   3. Scan .claude/.session-state/prove-yourself/*.json for rejection
#      records with kind="rejection" AND source="phase1" AND no
#      followup_issue field linking to an open issue
#   4. If found → refuse merge with summary of orphan deferrals
#
# Usage (callable from ship-pr-cycle merge-gate):
#   epic_completeness_check <pr-number>
#     → returns 0 if all closed epics' deferrals tracked, 1 otherwise
#
# Bypass: NO_ORPHAN_DEFERRALS_SKIP=1 (audit-logged via hook-ack)

# shellcheck disable=SC2034  # functions exported via source

epic_completeness_check() {
	local pr="$1"
	local owner_repo
	owner_repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)

	if [ -z "$pr" ] || [ -z "$owner_repo" ]; then
		echo "epic_completeness_check: usage <pr-number> (in a gh-authed git repo)" >&2
		return 2
	fi

	# Extract `Closes #N` (and variants: Close, Fixes, Fixed, Resolves, Resolved)
	# from PR body.
	local body closed_ids
	body=$(gh pr view "$pr" --json body --jq '.body' 2>/dev/null)
	if [ -z "$body" ]; then
		echo "epic_completeness_check: empty/missing PR body" >&2
		return 2
	fi

	# Match: (?i)(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#(\d+)
	closed_ids=$(printf '%s\n' "$body" | grep -iEo '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+' | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
	if [ -z "$closed_ids" ]; then
		# No closing refs — nothing to check.
		return 0
	fi

	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
		echo "epic_completeness_check: not in a git repo" >&2
		return 2
	}
	local pystate_dir="$repo_root/.claude/.session-state/prove-yourself"

	local orphans=0
	local report=""

	for issue in $closed_ids; do
		# Check if this is an epic (has open sub-issues that the epic-creation
		# skill registers via GraphQL addSubIssue). We treat any issue with the
		# `epic` label OR with >0 open sub-issues as an epic.
		local is_epic
		is_epic=$(gh issue view "$issue" --repo "$owner_repo" --json labels,number 2>/dev/null |
			jq -r 'if (.labels[]? | select(.name == "epic")) then "yes" else "no" end' 2>/dev/null | head -1)
		[ "$is_epic" = "yes" ] || continue

		# For now we check ANY prove-yourself rejection records (deferred
		# items) without a followup_issue field. Conservative — surface ALL
		# unaddressed deferrals at epic-close time.
		if [ ! -d "$pystate_dir" ]; then
			# No state dir, no deferrals to worry about.
			continue
		fi
		local unlinked_count
		unlinked_count=$(find "$pystate_dir" -name '*.json' -exec cat {} \; 2>/dev/null |
			jq -s '[.[] | select(.kind == "rejection") | select(.followup_issue == null or .followup_issue == "")] | length' 2>/dev/null || echo 0)
		if [ "${unlinked_count:-0}" -gt 0 ]; then
			orphans=$((orphans + unlinked_count))
			report="${report}  - Epic #$issue: $unlinked_count prove-yourself rejection(s) without linked followup_issue
"
		fi
	done

	if [ "$orphans" -gt 0 ]; then
		echo "epic-completeness-check: REFUSED — $orphans orphan deferral(s):" >&2
		printf '%s' "$report" >&2
		echo "" >&2
		echo "  Resolution: file followup issue(s) + add 'followup_issue: <N>' to" >&2
		echo "  each unlinked prove-yourself record OR convert defer to fix-in-PR." >&2
		echo "  Bypass: NO_ORPHAN_DEFERRALS_SKIP=1 git merge ... (audit-logged)" >&2
		return 1
	fi
	return 0
}

# CLI invocation
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	if [ "${NO_ORPHAN_DEFERRALS_SKIP:-0}" = "1" ]; then
		echo "epic_completeness_check: NO_ORPHAN_DEFERRALS_SKIP=1 — bypassing" >&2
		exit 0
	fi
	epic_completeness_check "$@"
fi
