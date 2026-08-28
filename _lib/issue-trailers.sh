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
# files, with no test tying them together — the drift this repo keeps
# finding, and the drift that is only ever noticed after it has already
# cost something.
#
# The two copies were equivalent when this was written (`[ds]?` vs `[sd]?`
# in the character class, same language) but that is luck, not design: the
# next author adding a keyword to one has no reason to know about the other.
#
# The keyword set is GitHub's, not ours. It is what `gh` and the GitHub UI
# act on when linking a PR to an issue, so widening it here without GitHub
# widening it would make this repo believe an issue closes when it will not.

# The one pattern. ERE, case-insensitive at the point of use.
ISSUE_TRAILER_RE='(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+'

# Emit the issue NUMBERS referenced by closing trailers in the given text,
# one per line, sorted and de-duplicated.
#
# Takes any number of text arguments and considers them TOGETHER — a merge
# commit message and a PR body are two sources for one answer, and deduping
# per source rather than across the union would hand a caller the same issue
# twice when a trailer appears in both.
#
# Emits nothing (rc 0) when there are no trailers. That is an ordinary
# outcome — a doc-only PR closes nothing — so it is not an error here. The
# CALLER decides whether an empty result is worth announcing, and in
# github-pr-merge/run.sh it emphatically is: an empty result there was
# indistinguishable from the parse being broken, which is exactly how the
# squash-commit bug survived.
issue_trailers_extract() { # $@ = text blocks to scan
	[ "$#" -gt 0 ] || return 0
	# `|| true` ONLY absorbs grep's rc 1, which means "no match" and is the
	# ordinary case — a PR that closes nothing. A blanket `|| true` on the
	# whole pipeline would also swallow rc 2, which is grep reporting a real
	# error (an unreadable pattern, a broken locale), and this file exists
	# because a silently-empty result was indistinguishable from a working
	# one. So the first grep's status is inspected rather than discarded.
	local matched rc=0
	matched=$(printf '%s\n' "$@" | grep -oiE "$ISSUE_TRAILER_RE") || rc=$?
	if [ "$rc" -gt 1 ]; then
		echo "issue_trailers_extract: grep failed (rc=$rc) — trailer extraction is UNRELIABLE for this input" >&2
		return "$rc"
	fi
	[ -n "$matched" ] || return 0
	printf '%s\n' "$matched" | grep -oE '[0-9]+' | sort -u -n
}
