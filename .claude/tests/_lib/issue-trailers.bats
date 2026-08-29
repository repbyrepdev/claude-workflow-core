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
	# A scratch dir for the epic-completeness dependency tests below, which
	# build small lib trees rather than touching the real one. Created
	# BEFORE the source: the library sets `set -u` at top level and that
	# persists into the caller, so an unbound TEST_TMP afterwards is fatal
	# rather than empty.
	TEST_TMP=$(mktemp -d -t issue-trailers.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# shellcheck source=../../../_lib/issue-trailers.sh
	source "$LIB"
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	case "${TEST_TMP:-}" in
	*/issue-trailers.*) rm -rf "$TEST_TMP" ;;
	esac
	true
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
	# NOTE ON WHAT THIS DOES NOT COVER, since Phase 1 proved it: deleting
	# the `[ "$#" -gt 0 ] || return 0` guard leaves this green, because
	# `printf` with no arguments feeds grep an empty line, grep returns 1,
	# and the function reaches the same rc-0-and-empty result by the longer
	# route. The guard is an early exit, not a behavioural boundary.
	#
	# The test is kept because the CONTRACT — no arguments is not an error —
	# is worth pinning against a future change that makes it one. It is
	# labelled here so nobody mistakes it for coverage of the guard itself.
	local got rc=0
	got=$(_extract) || rc=$?
	[ "$rc" -eq 0 ] || {
		echo "no arguments returned rc $rc; the contract says it is not an error"
		return 1
	}
	[ -z "$got" ] || {
		echo "no arguments produced output: $got"
		return 1
	}
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

@test "trailers: a keyword INSIDE another word does not count" {
	# The gap Phase 1 proved rather than asserted. The pattern was
	# unanchored, so it matched substrings: `postfixes #12`, `unclosed #34`
	# and `prefix #56` all yielded numbers, and GitHub links none of them.
	#
	# That made the extractor strictly WIDER than the contract the library
	# header claims — it would have rolled up epics a PR never said it
	# closed, which is worse than the under-matching bug this branch started
	# from. The file's negatives covered non-keywords but never a substring,
	# so nothing enforced the stated invariant.
	local got
	got=$(_extract "This postfixes #12 and unclosed #34 and prefix #56 and refixes #78")
	[ -z "$got" ] || {
		echo "a keyword embedded in another word was treated as a closure: $got"
		return 1
	}
}

@test "trailers: a real keyword adjacent to punctuation STILL counts" {
	# The other half of word-boundary matching. Bullets, parentheses and
	# list markers are the normal way these appear in a PR body, and an
	# anchor that rejected them would silently stop closing real epics —
	# trading an over-match for an under-match.
	local got
	got=$(_extract "- Closes #1
(closes #2)
* Fixes #3
  Resolves #4
Closes #5.")
	[ "$got" = "$(printf '1\n2\n3\n4\n5')" ] || {
		echo "punctuation-adjacent keywords were rejected; got: $got"
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
		# Matched on `#[0-9]`, the ONE thing any inline copy must contain.
		#
		# Two earlier forms failed here, both by being too specific about
		# spelling: `\(close\[[sd]{2}\]\?\|fix` required that exact
		# bracket class, and an alternation-based version required the
		# keywords in that exact ORDER — mutation-verified, a copy written
		# `(closes?|closed|fixes?|fixed|resolves?|resolved)` walked past
		# both. A decoy that only catches the spelling it was written
		# against is not a decoy.
		#
		# The issue-number fragment is unavoidable: a trailer pattern that
		# does not match a number is not a trailer pattern. Measured zero
		# occurrences in both clean callers and one in a reintroduced copy.
		grep -qF '#[0-9]' "$f" && {
			echo "$f still contains an inline copy of the trailer regex"
			return 1
		}
	done
	true
}

@test "trailers: a REAL grep failure is reported, not returned as empty" {
	# The branch added to stop a blanket `|| true` swallowing everything.
	# grep rc 1 is no-match and ordinary; rc above 1 is grep reporting a
	# genuine failure, and returning empty for that is indistinguishable
	# from "this PR closes nothing" — the exact confusion this change
	# exists to remove.
	#
	# Forced with an invalid ERE, the realistic shape: a broken pattern or
	# a locale that makes the character class unparseable.
	local rc=0 out
	out=$(ISSUE_TRAILER_RE='[' issue_trailers_extract "Closes #1" 2>&1) || rc=$?
	[ "$rc" -gt 1 ] || {
		echo "a hard grep failure returned rc $rc — indistinguishable from no-match"
		return 1
	}
	case "$out" in
	*"UNRELIABLE"*) ;;
	*)
		echo "the failure was not reported to the operator: $out"
		return 1
		;;
	esac
}

# ---- epic_completeness_check: the new external dependency ----------------
#
# The refactor gave this previously self-contained function a dependency on
# a sibling library, and a new error path when that library is absent.
# Neither was covered. A dependency nobody tests is a dependency that breaks
# in a consumer repo and not here.

_ecc_fixture() { # builds a lib dir; $1 = "with-lib" | "without-lib"
	local root="$TEST_TMP/ecc-$1"
	mkdir -p "$root"
	# GUARDED. The sibling fixture in github-pr-merge-autoclose.bats was
	# fixed for this a commit ago and this one was not — the same
	# one-of-two pattern as the production guards. A fixture that
	# half-builds and runs anyway is how a test ends up asserting on a
	# function that failed for an unrelated reason.
	cp "$REPO_ROOT/_lib/epic-completeness-check.sh" "$root/" || {
		echo "fixture: could not copy epic-completeness-check.sh" >&2
		return 1
	}
	if [ "$1" = "with-lib" ]; then
		cp "$REPO_ROOT/_lib/issue-trailers.sh" "$root/" || {
			echo "fixture: could not copy issue-trailers.sh" >&2
			return 1
		}
	fi
	printf '%s' "$root"
}

# A gh stub that answers the OWNER lookup and fails the BODY fetch.
#
# Without it the function never gets past its usage guard: `gh repo view`
# fails outside a repo, `owner_repo` comes back empty, and it returns 2 with
# the usage message — before reaching the library check or the fetch. The
# foreign-cwd test passed on exactly that for one revision, asserting only
# that a message was ABSENT while the function died two checks earlier.
# Adding the positive assertion is what exposed it.
_ecc_gh_stub() {
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"repo view") printf 'testowner/testrepo\n' ;;
"pr view")
	case "$*" in
	*closingIssuesReferences*)
		# The AUTHORITATIVE query, asked before the body. Failed by default so
		# these fixtures travel the labelled fallback, which is where the
		# body-scanning behaviour they were written for now lives.
		if [ "${ECC_CLOSING_FAIL:-1}" = "1" ]; then
			echo "gh: closingIssuesReferences unavailable" >&2
			exit 1
		fi
		printf '%s' "${ECC_CLOSING:-}"
		exit 0
		;;
	esac
	# Empty body: the function refuses with "body is empty", the downstream
	# failure these tests use as proof everything before it succeeded.
	printf '\n'
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	PATH="$TEST_TMP/bin:$PATH"
	export PATH
}

@test "epic-completeness: a MISSING issue-trailers.sh fails closed with a named reason" {
	# return 2, not a silent 0 and not a crash. This function gates a merge,
	# so an unreadable dependency has to refuse rather than report "nothing
	# to check" — which is what an empty closed_ids means and would be
	# indistinguishable from success.
	local root
	_ecc_gh_stub
	root=$(_ecc_fixture without-lib)
	[ ! -f "$root/issue-trailers.sh" ] || {
		echo "fixture failed: the library is present"
		return 1
	}
	run bash -c "source '$root/epic-completeness-check.sh' && epic_completeness_check 123"
	[ "$status" -eq 2 ] || {
		echo "expected rc 2 for a missing dependency, got $status: $output"
		return 1
	}
	case "$output" in
	*"issue-trailers.sh missing"*) ;;
	*)
		echo "the refusal does not name the missing file: $output"
		return 1
		;;
	esac
}

@test "epic-completeness: sourcing the extractor turns nounset ON in the caller" {
	# WHAT THIS USED TO ASSERT was unfalsifiable: it checked that `body` and
	# `closed_ids` survived the dot-source, but those are declared `local`
	# in epic_completeness_check AFTER the source, so the collision it
	# guarded against cannot happen. Only an absurd mutation killed it.
	#
	# The REAL, documented side effect is the option leak: a top-level
	# `set -u` in a sourced file runs in the caller's shell. The library
	# header explains why it cannot be removed (bash-safety.sh mandates it),
	# so the behaviour should be pinned rather than described — a future
	# reader deciding it is safe to drop needs a test to argue with.
	local root
	root=$(_ecc_fixture with-lib)
	run bash -c "
		set +u
		unset MAYBE_UNSET
		source '$root/issue-trailers.sh'
		printf 'still-here:%s\n' \"\${MAYBE_UNSET}\"
		echo NOTREACHED
	"
	# nounset is now ON in the caller, so reading an unset variable aborts.
	[ "$status" -ne 0 ] || {
		echo "the library did NOT turn nounset on in the caller — the documented leak is gone, so the header explaining it is now wrong: $output"
		return 1
	}
	case "$output" in
	*NOTREACHED*)
		echo "execution continued past an unset read; nounset did not take effect"
		return 1
		;;
	esac
}

@test "epic-completeness: the extractor resolves from a FOREIGN cwd" {
	# The rule is BASH_SOURCE-relative, so it must hold when the function is
	# called from an arbitrary directory — a consumer invoking it from a repo
	# subdirectory is the normal case, not the exotic one.
	#
	# Asserted by WHICH refusal comes back: with the library present the
	# dependency check passes and the function proceeds to the gh fetch,
	# which fails in this fixture. Getting the BODY error rather than the
	# LIBRARY error is the proof that resolution succeeded.
	local root
	_ecc_gh_stub
	root=$(_ecc_fixture with-lib)
	mkdir -p "$TEST_TMP/elsewhere"
	run bash -c "cd '$TEST_TMP/elsewhere' && source '$root/epic-completeness-check.sh' && epic_completeness_check 123"
	case "$output" in
	*"issue-trailers.sh missing"*)
		echo "the extractor was not resolvable from a foreign cwd: $output"
		return 1
		;;
	esac
	# POSITIVE half. Asserting only the ABSENCE of one message would pass if
	# the function died for some third reason before reaching either — the
	# same shape of hole as a test that checks a command "did not fail".
	# The downstream marker moved again, and the move was the point: the
	# body is no longer fetched before the authoritative query, so an empty
	# body is only fatal once GitHub has already failed to answer. The
	# refusal that proves resolution succeeded is now the fallback's.
	case "$output" in
	*"the closing set is UNKNOWN"*) ;;
	*)
		echo "did not reach the expected downstream failure; got: $output"
		return 1
		;;
	esac
}

@test "epic-completeness: an extraction FAILURE refuses, it does not report 'nothing to check'" {
	# THE FAIL-OPEN. `closed_ids=$(issue_trailers_extract "$body")` discarded
	# the return code, so the rc>1 the library deliberately raises for a
	# broken parse landed in the `[ -z "$closed_ids" ]` branch and returned
	# 0 — this merge gate reported PASS while its parser was broken.
	#
	# That is the identical fail-open the whole branch exists to fix,
	# reproduced one call site downstream. It survived because the library's
	# own hard-failure test exercises the library in ISOLATION and never
	# either caller — the same isolation gap that has produced four vacuous
	# tests on this work already.
	local root
	_ecc_gh_stub
	root=$(_ecc_fixture with-lib)
	# gh returns a body WITH a real trailer, so an empty closed_ids can only
	# come from the extractor failing — not from there being nothing to find.
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"repo view") printf 'testowner/testrepo\n' ;;
"pr view")
	case "$*" in
	*closingIssuesReferences*)
		# Force the FALLBACK. The body-scanning path is the only one where
		# a broken pattern can be reached at all, so the authoritative
		# query has to fail for this test to exercise anything.
		echo "gh: closingIssuesReferences unavailable" >&2
		exit 1
		;;
	esac
	printf 'Closes #4242\n'
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	# Break the pattern in the fixture's copy so the real rc>1 path runs.
	python3 - "$root/issue-trailers.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace(
    "ISSUE_TRAILER_RE='(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+'",
    "ISSUE_TRAILER_RE='['")
open(p, 'w', encoding='utf-8').write(s)
PY
	grep -q "ISSUE_TRAILER_RE='\['" "$root/issue-trailers.sh" || {
		echo "fixture failed: the pattern was not broken"
		return 1
	}

	run bash -c "source '$root/epic-completeness-check.sh' && epic_completeness_check 123"
	[ "$status" -ne 0 ] || {
		echo "a broken parser returned SUCCESS — the gate is fail-open: $output"
		return 1
	}
	case "$output" in
	*"extraction FAILED"*) ;;
	*)
		echo "the refusal does not name the extraction failure: $output"
		return 1
		;;
	esac
}

@test "epic-completeness: a gh FAILURE is reported as a gh failure" {
	# Every network, auth and permission fault used to surface as
	# "empty/missing PR body", pointing the operator at the PR description
	# for a 503 or an expired token. The sibling in github-pr-merge/run.sh
	# was fixed for this in the same branch; this caller was missed.
	local root
	_ecc_gh_stub
	root=$(_ecc_fixture with-lib)
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"repo view") printf 'testowner/testrepo\n' ;;
"pr view")
	echo "gh: API rate limit exceeded (HTTP 403)" >&2
	exit 1
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	run bash -c "source '$root/epic-completeness-check.sh' && epic_completeness_check 123"
	[ "$status" -eq 2 ]
	# The CAUSE must reach the operator, not a guess about the body.
	case "$output" in
	*"rate limit exceeded"*) ;;
	*)
		echo "gh's own error was discarded: $output"
		return 1
		;;
	esac
	case "$output" in
	*"empty/missing PR body"*)
		echo "a gh failure was still reported as an empty body: $output"
		return 1
		;;
	esac
}

@test "trailers: the extractor answers identically however it is sourced" {
	# SCOPE, stated honestly: this compares the extractor called directly
	# against the extractor reached through a sourced copy. It does NOT
	# drive either production caller, so it cannot prove the two callers
	# agree — an earlier title claimed that and was wrong. What it does
	# pin is that sourcing the library does not change its answers, which
	# is the property a divergent or partially-installed copy would break.
	# The callers are compared behaviourally in
	# .claude/tests/skills/github-pr-merge-autoclose.bats.
	local input='Closes #11
Refs #12
postfixes #13
Fixes #15'
	local direct
	direct=$(_extract "$input")
	[ "$direct" = "$(printf '11\n15')" ] || {
		echo "the extractor answer changed: $direct"
		return 1
	}

	# Through a sourced copy, as epic-completeness-check.sh reaches it.
	local root viaLib
	root=$(_ecc_fixture with-lib)
	viaLib=$(bash -c "source '$root/issue-trailers.sh' && issue_trailers_extract \"\$1\"" _ "$input")
	[ "$viaLib" = "$direct" ] || {
		echo "a sourced copy disagreed with the direct call: '$viaLib' vs '$direct'"
		return 1
	}

	# The rejections are the load-bearing half: a divergent copy would show
	# up first as a non-keyword or a substring surviving.
	case "$direct" in
	*12* | *13*)
		echo "a substring or non-keyword reference survived: $direct"
		return 1
		;;
	esac
}

@test "epic-completeness: a library whose SOURCE fails refuses, it does not abort" {
	# The same guard on the OTHER caller. It was added to
	# skills/github-pr-merge/run.sh and not here — the third time on this
	# branch that a fix landed on one of two callers of the same library,
	# which is why this one is tested rather than assumed.
	local root
	_ecc_gh_stub
	root=$(_ecc_fixture with-lib)
	# Defines everything; only the trailing status is non-zero.
	printf '\nfalse\n' >>"$root/issue-trailers.sh"
	run bash -c "set -euo pipefail; source '$root/epic-completeness-check.sh' && epic_completeness_check 123"
	[ "$status" -eq 2 ] || {
		echo "expected a refusal (rc 2), got $status: $output"
		return 1
	}
	case "$output" in
	*"returned non-zero"*) ;;
	*)
		echo "the failing source was not named as the cause: $output"
		return 1
		;;
	esac
}

@test "trailers: the cap constant and counter live in the LIBRARY" {
	# The cap started in run.sh, was copied into epic-completeness-check.sh
	# when Phase 2 flagged the asymmetry, and a third copy is exactly how
	# the regex duplication that created this library began.
	# Asserted in a CLEAN environment. The library reads
	# `${ISSUE_TRAILER_MAX:-50}`, so an exported value inherited from the
	# shell — or from another test — would make this assert the environment
	# rather than the default.
	local default_max
	default_max=$(env -u ISSUE_TRAILER_MAX bash -c "source '$REPO_ROOT/_lib/issue-trailers.sh'; printf '%s' \"\$ISSUE_TRAILER_MAX\"")
	[ "$default_max" = "50" ] || {
		echo "the shared cap default is not 50: $default_max"
		return 1
	}
	# And it is overridable, which is what the :- form is for.
	local override_max
	override_max=$(ISSUE_TRAILER_MAX=7 bash -c "source '$REPO_ROOT/_lib/issue-trailers.sh'; printf '%s' \"\$ISSUE_TRAILER_MAX\"")
	[ "$override_max" = "7" ] || {
		echo "the cap is not overridable: $override_max"
		return 1
	}
	[ "$(issue_trailers_count "$(printf '1\n2\n3')")" = "3" ] || {
		echo "counter miscounted three ids"
		return 1
	}
	# The single-line case is why this is not `wc -l`: a command
	# substitution has already stripped the trailing newline, so wc would
	# report 0 for one id.
	[ "$(issue_trailers_count '7')" = "1" ] || {
		echo "counter miscounted a single id"
		return 1
	}
	[ "$(issue_trailers_count '')" = "0" ] || {
		echo "counter miscounted the empty case"
		return 1
	}
}

@test "trailers: the counter returns ONE number, not two" {
	# `grep -c .` PRINTS its count and THEN exits 1 when that count is zero,
	# so a `|| printf '0'` fallback appended a second zero and the function
	# returned "0\n0" — which fails every numeric comparison it feeds, and
	# it feeds the plausibility cap on both callers. Verified before the
	# fix; pinned here because the shape is invisible in a passing
	# `[ "$n" = "0" ]` written the obvious way.
	# THE INPUT MATTERS, and my first attempt at this test got it wrong:
	# both `""` and `"$(printf '\n')"` take the EARLY EXIT — command
	# substitution strips the trailing newline, so the second is also the
	# empty string — and neither ever reached the grep the bug lives in.
	# Mutation-verified: restoring the broken form left that version green.
	#
	# A bare newline assigned directly is non-empty (so it passes the early
	# exit) and contains no non-empty lines (so grep counts 0 and exits 1),
	# which is exactly the branch.
	local n nl
	nl=$'\n'
	n=$(issue_trailers_count "$nl")
	[ "$n" = "0" ] || {
		echo "counter returned [$n] where a single 0 was expected — the classic shape here is the two-line '0' that fails every numeric test it feeds"
		return 1
	}
	# Usable in arithmetic, which "0\n0" is not.
	[ "$n" -eq 0 ] 2>/dev/null || {
		echo "counter result is not usable in arithmetic: [$n]"
		return 1
	}
	# And the ordinary early-exit case still answers 0.
	[ "$(issue_trailers_count "")" = "0" ] || {
		echo "empty input did not answer 0"
		return 1
	}
}
