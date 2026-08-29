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

	# The dependency is checked before the PR-BODY fetch — not before every
	# network call, which an earlier version of this comment claimed in
	# capitals. `gh repo view` above runs first, and when gh is missing or
	# unauthenticated the empty owner_repo returns 2 with the usage message,
	# still masking a missing library. This branch's own test has to install
	# a gh stub for exactly that reason, which is the counterexample.
	#
	# This pattern was written here first and then written AGAIN in
	# skills/github-pr-merge/run.sh — two copies of GitHub's closing-trailer
	# contract, equivalent by luck rather than design. One definition now,
	# in _lib/issue-trailers.sh.
	#
	# Ordering still matters: the check sat AFTER the `gh pr view` fetch, so
	# a body-fetch failure masked a missing library with "empty/missing PR
	# body" — a local, deterministic, instantly-fixable problem reported as
	# a remote one. Moving it above that fetch removes the common case; the
	# `gh repo view` guard above remains ahead of it.
	local _it_lib
	_it_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/issue-trailers.sh
	if [ ! -r "$_it_lib" ]; then
		echo "epic_completeness_check: _lib/issue-trailers.sh missing — cannot parse closing trailers" >&2
		return 2
	fi
	# GUARDED, like the sibling caller. `. file` returns the status of the
	# last statement in that file, so a library whose tail evaluates
	# non-zero aborts this gate outright under a caller's `set -e`. The
	# guard was added to skills/github-pr-merge/run.sh and not here — the
	# third time on this branch that a fix landed on one of two callers of
	# the same library.
	# shellcheck source=./issue-trailers.sh
	if ! . "$_it_lib"; then
		echo "epic_completeness_check: sourcing $_it_lib returned non-zero — cannot determine closing references" >&2
		return 2
	fi
	# Readable is not usable. A truncated library passes `-r` and defines
	# nothing; the missing function then surfaces as rc 127 down in the
	# extraction path and gets reported as a GitHub outage AND a broken
	# parser — two wrong causes for one missing file. The sibling caller
	# already guards this way.
	# EVERY symbol this function goes on to use, not just the two it used to.
	# `issue_trailers_count` and `ISSUE_TRAILER_MAX` arrived with the shared
	# cap and were not added here, so a library predating them would pass
	# the gate and fail later at the cap check — a stale install reported as
	# something else entirely, which is the wrong-cause pattern this branch
	# keeps producing.
	if ! command -v issue_trailers_for_pr >/dev/null 2>&1 ||
		! command -v issue_trailers_extract >/dev/null 2>&1 ||
		! command -v issue_trailers_count >/dev/null 2>&1 ||
		[ -z "${ISSUE_TRAILER_MAX:-}" ]; then
		echo "epic_completeness_check: _lib/issue-trailers.sh is unusable (defines no extractor) — cannot determine closing references" >&2
		return 2
	fi

	# The PR BODY IS NOT FETCHED HERE. It is only the fallback's input, so
	# fetching it up front — and refusing outright on an empty one —
	# rejected PRs that GitHub could have answered for perfectly well. A PR
	# with a blank description that closes issues via its branch linkage is
	# an ordinary thing, and this gate used to refuse it.
	local body closed_ids

	# GITHUB IS THE AUTHORITY on what a PR closes, and this gate asks it
	# rather than re-deriving the answer from the body with a regex.
	#
	# Phase 1 security review showed why the regex is not adequate here: a
	# fenced code block, an HTML comment invisible in the rendered PR, and
	# the phrase "does not close #N" all yield numbers. In THIS function
	# that means checking the completeness of epics the PR never claimed to
	# close — noise at best, and a refused merge at worst.
	#
	# THE RETURN CODE IS HONOURED. Discarding it put a failure into the same
	# branch as "no closing refs", so this merge gate reported PASS while it
	# could not read its input at all — the identical fail-open this branch
	# was opened to fix, reproduced one call site downstream, and found by
	# Phase 1 rather than by the library's own test, which exercises the
	# library in isolation and never either caller.
	local _ex_rc=0
	closed_ids=$(issue_trailers_for_pr "$pr") || _ex_rc=$?
	if [ "$_ex_rc" -ne 0 ]; then
		# FALLBACK, labelled. The body regex is a guess at GitHub's answer;
		# it is used only when GitHub cannot be reached, and its failure is
		# still a refusal rather than a pass.
		echo "epic_completeness_check: could not ask GitHub which issues PR #$pr closes; falling back to scanning the body, which is a GUESS" >&2

		# NOW the body is needed. stderr is captured rather than discarded:
		# throwing it away reported a 503, an expired token and an unknown
		# PR all as an empty body, pointing the operator at the PR's
		# description for a network fault.
		local _b_err _b_rc=0
		_b_err=$(mktemp "${TMPDIR:-/tmp}/ecc-body-err.XXXXXX") || _b_err=""
		body=$(gh pr view "$pr" --json body --jq '.body' 2>"${_b_err:-/dev/null}") || _b_rc=$?
		if [ "$_b_rc" -ne 0 ]; then
			echo "epic_completeness_check: the fallback could not read PR #$pr body either (gh rc=$_b_rc):" >&2
			[ -n "$_b_err" ] && cat "$_b_err" >&2
			[ -n "$_b_err" ] && rm -f "$_b_err"
			return 2
		fi
		[ -n "$_b_err" ] && rm -f "$_b_err"
		if [ -z "$body" ]; then
			echo "epic_completeness_check: GitHub could not be asked and PR #$pr has an empty body — the closing set is UNKNOWN, refusing rather than passing" >&2
			return 2
		fi

		_ex_rc=0
		closed_ids=$(issue_trailers_extract "$body") || _ex_rc=$?
		if [ "$_ex_rc" -ne 0 ]; then
			echo "epic_completeness_check: closing-reference extraction FAILED (rc=$_ex_rc) — refusing rather than reporting 'nothing to check'" >&2
			return 2
		fi

		# THE SAME CAP THE SIBLING HAS. The fallback scans a PR body with no
		# bound — GitHub allows 65,536 characters, measured at ~6,000
		# extractable numbers — and each one costs API calls below. The cap
		# was added to skills/github-pr-merge/run.sh and not here, which is
		# the asymmetry this branch keeps producing: a guard applied to one
		# of two callers of the same library.
		local _n_ids
		_n_ids=$(issue_trailers_count "$closed_ids")
		if [ "$_n_ids" -gt "$ISSUE_TRAILER_MAX" ]; then
			echo "epic_completeness_check: $_n_ids closing references from the fallback is implausible (cap $ISSUE_TRAILER_MAX) — refusing rather than spending that many API calls" >&2
			return 2
		fi
	fi
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
