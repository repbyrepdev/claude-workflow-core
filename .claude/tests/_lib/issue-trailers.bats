#!/usr/bin/env bats
# covers: _lib/issue-trailers.sh
# audits: _lib/epic-completeness-check.sh
#
# (#2544) The SSOT for GitHub's issue-closing trailers, extracted after the
# pattern turned out to exist twice: once in _lib/epic-completeness-check.sh
# and once, written independently, in skills/github-pr-merge/run.sh.
#
# The two copies were equivalent — `[ds]?` in one, `[sd]?` in the other, same
# language — which is luck rather than design, and neither had a test. This
# file is the test the contract never had.
#
# The keyword set is GITHUB'S. Widening it here without GitHub widening it
# would make this repo believe an issue closes when it will not, so the
# negative cases below are as load-bearing as the positive ones.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	LIB="$REPO_ROOT/_lib/issue-trailers.sh"
	[ -r "$LIB" ]
	# shellcheck source=../../../_lib/issue-trailers.sh
	source "$LIB"
}

_extract() { issue_trailers_extract "$@"; }

@test "trailers: every GitHub keyword and inflection is recognised" {
	local got
	got=$(_extract "Closes #1
Close #2
Closed #3
Fixes #4
Fix #5
Fixed #6
Resolves #7
Resolve #8
Resolved #9")
	[ "$got" = "$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9')" ] || {
		echo "missed a keyword inflection; got: $got"
		return 1
	}
}

@test "trailers: matching is CASE-INSENSITIVE" {
	# GitHub does not care, and PR bodies are written by hand.
	local got
	got=$(_extract "CLOSES #10
closes #11
ClOsEs #12")
	[ "$got" = "$(printf '10\n11\n12')" ] || {
		echo "case sensitivity crept in; got: $got"
		return 1
	}
}

@test "trailers: MULTIPLE sources are scanned together" {
	# The reason the function takes varargs at all: a merge commit message
	# and a PR body are two sources for one answer. Scanning them separately
	# and concatenating would dedupe per source, not across the union.
	local got
	got=$(_extract "Closes #20" "Fixes #21")
	[ "$got" = "$(printf '20\n21')" ] || {
		echo "a second source was ignored; got: $got"
		return 1
	}
}

@test "trailers: a number in BOTH sources is emitted once" {
	# github-pr-merge/run.sh prints "for N closed sub-issue(s)" from this
	# count. The rollup is idempotent, so a duplicate would not break
	# anything — it would just make that log line untrue.
	local got
	got=$(_extract "Closes #30
Closes #31" "Closes #30")
	[ "$got" = "$(printf '30\n31')" ] || {
		echo "a cross-source duplicate survived; got: $got"
		return 1
	}
}

@test "trailers: NO trailers is empty and rc 0, not an error" {
	# A doc-only PR closes nothing. That is ordinary, so it is not this
	# function's job to complain — the CALLER decides whether empty is worth
	# announcing, and in run.sh it is, because there an empty result used to
	# be indistinguishable from a broken parse.
	local got rc=0
	got=$(_extract "A refactor. Nothing to see.") || rc=$?
	[ "$rc" -eq 0 ] || {
		echo "empty input returned rc $rc"
		return 1
	}
	[ -z "$got" ] || {
		echo "manufactured a number from nothing: $got"
		return 1
	}
}

@test "trailers: NO ARGUMENTS at all is rc 0 and empty" {
	local got rc=0
	got=$(_extract) || rc=$?
	[ "$rc" -eq 0 ]
	[ -z "$got" ]
}

@test "trailers: a bare '#123' is NOT a closing reference" {
	# The single most important negative. Issue bodies and commit messages
	# reference issues constantly without closing them — "see #123",
	# "follow-up to #456", "Refs #789". Treating those as closures would
	# roll up epics whose work is not done.
	local got
	got=$(_extract "This relates to #123 and follows #456.
Refs #789
See also #999")
	[ -z "$got" ] || {
		echo "a non-closing reference was treated as a closure: $got"
		return 1
	}
}

@test "trailers: 'Refs' and 'See' are not closing keywords" {
	# Stated separately from the bare-# case because these read like
	# keywords and are the likeliest thing for someone to add by mistake.
	local got
	got=$(_extract "Refs #1
References #2
See #3
Addresses #4
Part of #5")
	[ -z "$got" ] || {
		echo "a non-GitHub keyword was accepted: $got"
		return 1
	}
}

@test "trailers: output is NUMERIC-sorted, not lexical" {
	# `sort -u` alone puts 10 before 9. The order is cosmetic for the
	# rollup, but the count message and the log read in this order and a
	# lexical jumble makes a long list hard to check by eye.
	local got
	got=$(_extract "Closes #9
Closes #10
Closes #100
Closes #2")
	[ "$got" = "$(printf '2\n9\n10\n100')" ] || {
		echo "not numerically sorted; got: $got"
		return 1
	}
}

@test "trailers: whitespace between keyword and # may be a tab or multiple" {
	local got
	got=$(_extract "$(printf 'Closes\t#40\nFixes   #41')")
	[ "$got" = "$(printf '40\n41')" ] || {
		echo "whitespace variation broke matching; got: $got"
		return 1
	}
}

@test "trailers: the two former call sites now share ONE pattern" {
	# The point of the extraction. Both files must reference the library
	# rather than carrying their own regex — a second copy is how the drift
	# started, and it would be invisible again the moment it reappears.
	local runsh="$REPO_ROOT/skills/github-pr-merge/run.sh"
	local epic="$REPO_ROOT/_lib/epic-completeness-check.sh"
	grep -q 'issue_trailers_extract' "$runsh" || {
		echo "github-pr-merge/run.sh does not use the shared extractor"
		return 1
	}
	grep -q 'issue_trailers_extract' "$epic" || {
		echo "epic-completeness-check.sh does not use the shared extractor"
		return 1
	}
	# And neither carries an inline copy of the keyword alternation.
	local f
	for f in "$runsh" "$epic"; do
		grep -qE "\(close\[[sd]{2}\]\?\|fix" "$f" && {
			echo "$f still contains an inline copy of the trailer regex"
			return 1
		}
	done
	return 0
}
