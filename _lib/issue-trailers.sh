#!/bin/bash
set -u
# auto-register: false
#
# (#2544) SSOT for GitHub's issue-closing trailers — `Closes #N` and its
# variants — and for turning text containing them into a list of numbers.
#
# WHY THIS FILE EXISTS. The pattern was written twice, independently:
# `_lib/epic-completeness-check.sh` used it to find which epics a PR claims
# to close, and `skills/github-pr-merge/run.sh` used it to decide which
# sub-issues to roll up after a merge. Two copies of one contract, in two
# files, with no test tying them together.
#
# ON THE `set -u` ABOVE: it runs in the CALLER's shell, because that is what
# a top-level `set` in a sourced file does. Phase 1 flagged that as a helper
# mutating its caller's options — correctly — but it is not removable here:
# `pre-commit-hooks/bash-safety.sh` requires `set -u*` in the first 20 lines
# of every .sh in this repo, and the Write path enforces the same rule. The
# leak is benign in practice because both real callers already run
# `set -euo pipefail`. Recorded rather than silently accepted, since the next
# reader will otherwise re-raise it.
#
# The keyword set is GitHub's, not ours. It is what `gh` and the GitHub UI
# act on when linking a PR to an issue, so widening it here without GitHub
# widening it would make this repo believe an issue closes when it will not.

# The one pattern. ERE, matched case-insensitively and WORD-BOUNDED.
#
# The `-w` at the point of use is load-bearing, not decoration. Unanchored,
# this pattern matches INSIDE other words: `postfixes #12`, `unclosed #34`
# and `prefix #56` all produced numbers (verified), and GitHub links none of
# them. That made the extractor strictly wider than the contract the comment
# above claims it implements — it would have rolled up epics a PR never said
# it closed, which is worse than the under-matching bug this branch started
# from.
ISSUE_TRAILER_RE='(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+'

# Emit the issue NUMBERS referenced by closing trailers in the given text,
# one per line, sorted numerically and de-duplicated.
#
# Takes any number of text arguments and considers them TOGETHER — a merge
# commit message and a PR body are two sources for one answer, and deduping
# per source rather than across the union would hand a caller the same issue
# twice when a trailer appears in both.
#
# RETURN CODES ARE PART OF THE CONTRACT, and callers must honour them:
#   0 + output    — trailers found
#   0 + no output — no trailers. Ordinary: a doc-only PR closes nothing.
#   >1            — a REAL failure (grep could not run). The result is not
#                   "no trailers", it is "unknown", and treating those two
#                   the same is the defect this whole file exists to remove.
#
# Both greps are status-checked. Only the first can legitimately return 1
# (no match); an earlier revision checked the first and let `sort` swallow
# the second, which reintroduced exactly the silent-empty result the
# paragraph above forbids.
#
# The second check is UNREACHABLE BY CONSTRUCTION and deliberately kept.
# `matched` is non-empty here, and every string the first pattern can
# produce ends in `#[0-9]+`, so `grep -oE '[0-9]+'` cannot return 1 and has
# just demonstrated it can run. Phase 1 confirmed no mutation reaches it.
# It stays because the invariant it depends on lives in a DIFFERENT
# variable — change ISSUE_TRAILER_RE to something without a digit group and
# this becomes live — and because the cost of the branch is one comparison
# on a path that decides which issues get closed. Recorded as untestable
# defence rather than left looking like covered code.
issue_trailers_extract() { # $@ = text blocks to scan
	[ "$#" -gt 0 ] || return 0

	local matched rc=0
	matched=$(printf '%s\n' "$@" | grep -owiE "$ISSUE_TRAILER_RE") || rc=$?
	if [ "$rc" -gt 1 ]; then
		echo "issue_trailers_extract: trailer match failed (grep rc=$rc) — extraction is UNRELIABLE; treat as unknown, not as empty" >&2
		return "$rc"
	fi
	[ -n "$matched" ] || return 0

	local nums nrc=0
	nums=$(printf '%s\n' "$matched" | grep -oE '[0-9]+') || nrc=$?
	if [ "$nrc" -ne 0 ]; then
		echo "issue_trailers_extract: number extraction failed (grep rc=$nrc) on non-empty matches — UNRELIABLE" >&2
		return 2
	fi

	printf '%s\n' "$nums" | sort -u -n
}

# --- the AUTHORITATIVE source ---------------------------------------------
#
# GitHub already computes which issues a PR closes, and publishes it as
# `closingIssuesReferences`. Re-deriving it with a regex over the PR body is
# strictly worse, and Phase 1 security review demonstrated how:
#
#     body:  Real: Closes #7
#            ```
#            Closes #4242        <- fenced code block
#            ```
#            <!-- Closes #9999 -->   <- invisible in the rendered PR
#            This does not close #4010
#
#     regex ->  7 4010 4242 9999
#     GitHub ->  7
#
# All three extras would have had their PARENT EPICS CLOSED, recursively.
# The body is free-form text written by whoever opened the PR, and this
# feeds a destructive action, so guessing at markdown semantics with a
# regex is not a defensible way to decide it. GitHub's answer is exact,
# markdown-aware, and already computed.
#
# Verified on the merged PR #2638: the field returns 2551/2554/2555/2556 —
# precisely the four sub-issues — while the regex over the same body plus
# the squash commit returns those and more.
#
# rc 0 with output  — the issues GitHub says this PR closes
# rc 0 no output    — GitHub says it closes none
# rc 1              — could not ask. NOT "closes none"; the caller must
#                     treat it as unknown and say so.
issue_trailers_for_pr() { # $1 = PR number
	local pr=${1:-}
	[ -n "$pr" ] || return 1
	command -v gh >/dev/null 2>&1 || return 1
	# gh's stderr is SURFACED, not discarded. The caller announces this
	# function's empty result as authoritative ("GitHub reports PR #N closes
	# no issues"), so the one thing it must never do is fail quietly — and
	# an operator told the query failed still needs to know why.
	local out rc=0 err
	err=$(mktemp "${TMPDIR:-/tmp}/it-gh-err.XXXXXX") || err=""
	out=$(gh pr view "$pr" --json closingIssuesReferences \
		--jq '.closingIssuesReferences[].number' 2>"${err:-/dev/null}") || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "issue_trailers_for_pr: could not ask GitHub about PR #$pr (gh rc=$rc)" >&2
		[ -n "$err" ] && cat "$err" >&2
		[ -n "$err" ] && rm -f "$err"
		return 1
	fi
	[ -n "$err" ] && rm -f "$err"

	# Digits only, deduped, numerically sorted — same output contract as the
	# text extractor, so callers can treat the two identically.
	#
	# NO BLANKET `|| true`. grep rc 1 is the ordinary no-match case (GitHub
	# genuinely closes none); anything above that is a real failure, and
	# suppressing it would hand the caller rc 0 with no output, which run.sh
	# then announces as GitHub's authoritative "closes no issues". Same
	# distinction issue_trailers_extract enforces, and it was missing here —
	# the new function reintroduced the exact defect the old one was fixed
	# for, on the path that carries more authority.
	local nums nrc=0
	nums=$(printf '%s\n' "$out" | grep -oE '^[0-9]+$') || nrc=$?
	if [ "$nrc" -gt 1 ]; then
		echo "issue_trailers_for_pr: number filter failed (grep rc=$nrc) — the closing set is UNKNOWN, not empty" >&2
		return 1
	fi
	[ -n "$nums" ] || return 0
	printf '%s\n' "$nums" | sort -u -n
}
