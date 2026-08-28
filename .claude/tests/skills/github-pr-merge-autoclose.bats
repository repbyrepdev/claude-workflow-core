#!/usr/bin/env bats
# covers: skills/github-pr-merge/run.sh
# shellcheck disable=SC2030,SC2031,SC2089,SC2090
#
# (#2544) The epic-rollup stanza had NO coverage, which is how it shipped
# broken and stayed broken.
#
# It scraped `Closes #N` out of the MERGE COMMIT message. GitHub composes a
# squash commit from the PR TITLE plus the constituent commit messages and
# never the PR BODY — and the body is where the trailers live, because that
# is what GitHub's own issue-linking reads. So on a squash merge the stanza
# saw an empty list.
#
# Worse, it then did nothing AT ALL: `if [ -n "$closed_nums" ]` with no else,
# so the broken path and the legitimate nothing-to-close path printed the
# same thing — nothing. Observed live on PR #2638: four sub-issues closed by
# GitHub from the body, epic left open, not a word of output.
#
# These drive the REAL wrapper with a stubbed gh and a recording stand-in for
# auto-close-parent.sh, so what is asserted is which issue numbers the
# wrapper actually hands to the rollup.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/skills/github-pr-merge/run.sh"
	[ -x "$SCRIPT" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t gh-pr-merge-autoclose.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	export APPROVAL_GATE_POLICY="$TEST_TMP/gate-off.yml"
	printf 'require_approving_review: false\n' >"$TEST_TMP/gate-off.yml"
	export AC_LOG="$TEST_TMP/autoclose-calls.log"
	: >"$AC_LOG"

	# A scratch repo whose HEAD commit carries NO trailers — the squash shape.
	WORK="$TEST_TMP/work"
	ORIGIN="$TEST_TMP/origin.git"
	mkdir -p "$WORK"
	(
		set -e
		git init -q --bare -b main "$ORIGIN"
		cd "$WORK"
		git init -q -b main
		git config user.email t@t.t
		git config user.name t
		printf 'seed\n' >f.txt
		git add -A
		git commit -qm "feat(hooks): the squash subject (#2638)

* feat(lib): a constituent commit message

No trailers anywhere in here, exactly as GitHub composes a squash."
		# A REAL origin: the wrapper does a post-merge pull, and without a
		# reachable remote it aborts before the rollup stanza is ever
		# reached — the fixture would then be testing the pull, not this.
		git remote add origin "$ORIGIN"
		git push -q -u origin main
	) || {
		echo "FATAL: fixture repo init failed" >&2
		return 1
	}
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)

	# Recording stand-in for the rollup script, at the path run.sh looks up.
	mkdir -p "$WORK/.claude/hooks"
	cat >"$WORK/.claude/hooks/auto-close-parent.sh" <<'AC'
#!/bin/bash
printf '%s\n' "$1" >>"$AC_LOG"
exit 0
AC
	chmod +x "$WORK/.claude/hooks/auto-close-parent.sh"
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	case "${TEST_TMP:-}" in
	*/gh-pr-merge-autoclose.*) rm -rf "$TEST_TMP" ;;
	esac
	return 0
}

# gh stub. FAKE_PR_BODY is what `pr view --json body` returns — the seam the
# whole file is about.
_install_gh_shim() {
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"pr view")
	case "$*" in
	*mergeCommit*) printf '%s\n' "$FAKE_MERGE_SHA" ;;
	*--json\ body*) printf '%s\n' "${FAKE_PR_BODY:-}" ;;
	*statusCheckRollup*) printf '%s\n' "$FAKE_STATE" ;;
	*) echo "{}" ;;
	esac
	;;
"pr merge") exit 0 ;;
"repo view")
	case "$*" in
	*nameWithOwner*) printf 'testowner/testrepo\n' ;;
	*) printf 'false\n' ;;
	esac
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
}

_run_merge() {
	export FAKE_MERGE_SHA="$MERGE_SHA"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$MERGE_SHA"'","checks":[]}'
	run bash -c "cd '$WORK' && APPROVE=1 AC_LOG='$AC_LOG' bash '$SCRIPT' --pr 2638 --squash --yes </dev/null"
}

_called_with() { # $1 = issue number
	grep -qx "$1" "$AC_LOG"
}

@test "autoclose: trailers in the PR BODY reach the rollup on a squash merge" {
	# The PR #2638 shape. Body has the trailers; the squash commit has none.
	# Before the fix this closed nothing and said nothing.
	_install_gh_shim
	export FAKE_PR_BODY="## Summary

Some description.

Closes #2554
Closes #2555
Closes #2556
Closes #2551"
	_run_merge
	local n
	for n in 2554 2555 2556 2551; do
		_called_with "$n" || {
			echo "auto-close-parent was never called for #$n; log: $(cat "$AC_LOG")"
			echo "output: $output"
			return 1
		}
	done
}

@test "autoclose: trailers in the MERGE COMMIT still work (the --merge shape)" {
	# The body is not a replacement for the commit message — a --merge
	# commit keeps the body, and individual commits may carry their own
	# trailers. Both sources are unioned, so neither shape regresses.
	_install_gh_shim
	(cd "$WORK" && git commit -q --allow-empty -m "chore: rollup

Fixes #4242" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
	export FAKE_PR_BODY="no trailers here at all"
	_run_merge
	_called_with 4242 || {
		echo "a trailer in the merge commit was ignored; log: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: the two sources are UNIONED, not one-or-the-other" {
	_install_gh_shim
	(cd "$WORK" && git commit -q --allow-empty -m "chore: rollup

Resolves #111" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
	export FAKE_PR_BODY="Closes #222"
	_run_merge
	_called_with 111 || {
		echo "the commit-message trailer was dropped once a body existed"
		return 1
	}
	_called_with 222 || {
		echo "the body trailer was dropped once a commit trailer existed"
		return 1
	}
}

@test "autoclose: a duplicate across both sources is passed ONCE" {
	# sort -u across the union, not per source. Calling the rollup twice for
	# one issue is harmless (it is idempotent) but it doubles the output and
	# makes the log lie about how many sub-issues closed.
	_install_gh_shim
	(cd "$WORK" && git commit -q --allow-empty -m "chore: rollup

Closes #777" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
	export FAKE_PR_BODY="Closes #777"
	_run_merge
	local n
	n=$(grep -cx 777 "$AC_LOG")
	[ "$n" = "1" ] || {
		echo "expected one call for #777, got $n"
		return 1
	}
}

@test "autoclose: finding NOTHING is announced, not silent" {
	# The silence is what hid the bug for as long as it hid: the broken path
	# and the legitimate nothing-to-close path were the same path, both
	# printing nothing. A doc-only PR closing no issues is fine; the
	# operator still has to be able to tell that from a parse that came up
	# empty.
	_install_gh_shim
	export FAKE_PR_BODY="A refactor. Nothing to close."
	_run_merge
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup was called with no trailers present: $(cat "$AC_LOG")"
		return 1
	}
	case "$output" in
	*"no Closes/Fixes/Resolves trailers found"*) ;;
	*)
		echo "an empty trailer set was silent — indistinguishable from the bug: $output"
		return 1
		;;
	esac
}

@test "autoclose: a gh failure fetching the body degrades to commit-only" {
	# This block is warn-only and runs AFTER the merge has already landed.
	# A gh outage must not abort the wrapper or lose the trailers that are
	# still readable from the commit.
	_install_gh_shim
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"pr view")
	case "$*" in
	*mergeCommit*) printf '%s\n' "$FAKE_MERGE_SHA" ;;
	*--json\ body*)
		echo "gh: API is down (HTTP 503)" >&2
		exit 1
		;;
	*statusCheckRollup*) printf '%s\n' "$FAKE_STATE" ;;
	*) echo "{}" ;;
	esac
	;;
"pr merge") exit 0 ;;
"repo view")
	case "$*" in
	*nameWithOwner*) printf 'testowner/testrepo\n' ;;
	*) printf 'false\n' ;;
	esac
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	(cd "$WORK" && git commit -q --allow-empty -m "chore: rollup

Closes #909" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
	_run_merge
	_called_with 909 || {
		echo "a body-fetch failure lost the commit-message trailers; log: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: the COUNT message matches the deduped total" {
	# The stanza announces "for N closed sub-issue(s)". If the union ever
	# double-counts, that N is the only place it shows — the rollup itself is
	# idempotent, so a duplicate would otherwise be invisible and the log
	# would simply lie about how much work happened.
	_install_gh_shim
	(cd "$WORK" && git commit -q --allow-empty -m "chore: rollup

Closes #501
Closes #502" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
	# #502 appears in BOTH sources; #503 only in the body. Deduped total: 3.
	export FAKE_PR_BODY="Closes #502
Closes #503"
	_run_merge
	case "$output" in
	*"for 3 closed sub-issue(s)"*) ;;
	*)
		echo "count message wrong (expected 3 after dedup): $output"
		return 1
		;;
	esac
	local lines
	lines=$(grep -c . "$AC_LOG")
	[ "$lines" = "3" ] || {
		echo "rollup called $lines times, expected 3: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: body-fetch failure AND no commit trailers still announces" {
	# The two degradations compose. The existing failure test has a trailer
	# in the commit to fall back on; this one has nothing anywhere, which is
	# the state where the operator most needs to be told — the epic will not
	# roll up and the reason is not visible from the merge output otherwise.
	_install_gh_shim
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"pr view")
	case "$*" in
	*mergeCommit*) printf '%s\n' "$FAKE_MERGE_SHA" ;;
	*--json\ body*)
		echo "gh: API is down (HTTP 503)" >&2
		exit 1
		;;
	*statusCheckRollup*) printf '%s\n' "$FAKE_STATE" ;;
	*) echo "{}" ;;
	esac
	;;
"pr merge") exit 0 ;;
"repo view")
	case "$*" in
	*nameWithOwner*) printf 'testowner/testrepo\n' ;;
	*) printf 'false\n' ;;
	esac
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	_run_merge
	[ ! -s "$AC_LOG" ] || {
		echo "rollup ran with no trailers anywhere: $(cat "$AC_LOG")"
		return 1
	}
	# BOTH messages: the fetch failed AND nothing was found. Either alone
	# leaves the operator with half the picture.
	case "$output" in
	*"could not read PR"*) ;;
	*)
		echo "a body-fetch failure was silent: $output"
		return 1
		;;
	esac
	case "$output" in
	*"no Closes/Fixes/Resolves trailers found"*) ;;
	*)
		echo "an empty trailer set was silent: $output"
		return 1
		;;
	esac
}

@test "autoclose: gh exits 0 but emits a MALFORMED body" {
	# Distinct from the exit-1 case: gh can succeed at the transport level
	# and still hand back something --jq turns into junk (a proxy error page,
	# a truncated response). The stanza must not treat that as trailers, must
	# not crash the wrapper, and must still fall back to the commit message.
	_install_gh_shim
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"pr view")
	case "$*" in
	*mergeCommit*) printf '%s\n' "$FAKE_MERGE_SHA" ;;
	*--json\ body*)
		printf '<html><body>502 Bad Gateway</body></html>\n'
		exit 0
		;;
	*statusCheckRollup*) printf '%s\n' "$FAKE_STATE" ;;
	*) echo "{}" ;;
	esac
	;;
"pr merge") exit 0 ;;
"repo view")
	case "$*" in
	*nameWithOwner*) printf 'testowner/testrepo\n' ;;
	*) printf 'false\n' ;;
	esac
	;;
*) exit 0 ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	(cd "$WORK" && git commit -q --allow-empty -m "chore: rollup

Closes #606" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
	_run_merge
	[ "$status" -eq 0 ] || {
		echo "a malformed body aborted the wrapper (rc=$status): $output"
		return 1
	}
	_called_with 606 || {
		echo "the commit trailer was lost when the body came back malformed: $(cat "$AC_LOG")"
		return 1
	}
	# Junk must not manufacture issue numbers.
	local lines
	lines=$(grep -c . "$AC_LOG")
	[ "$lines" = "1" ] || {
		echo "malformed body produced extra rollup calls: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: a MISSING shared library is announced, not silently skipped" {
	# The `_lib/issue-trailers.sh not found` branch had no coverage. It is
	# the branch that fires in a half-installed consumer repo, and skipping
	# the rollup quietly there would reproduce the original bug exactly:
	# sub-issues closed by GitHub, epic left open, nothing said.
	#
	# The library is hidden by pointing the wrapper at a copy of the skill
	# whose ../../_lib has no issue-trailers.sh — the real resolution rule,
	# exercised as the wrapper actually runs it.
	_install_gh_shim
	local half_installed="$TEST_TMP/half-installed-plugin"
	mkdir -p "$half_installed/skills/github-pr-merge" "$half_installed/_lib" "$half_installed/skills/_lib"
	cp "${REPO_ROOT}/skills/github-pr-merge/"*.sh "$half_installed/skills/github-pr-merge/"
	# skills/_lib/ too — the wrapper sources skill-common.sh from there
	# before it ever reaches the lookup under test, and a fixture that dies
	# earlier would "pass" this test for the wrong reason.
	cp "${REPO_ROOT}/skills/_lib/"*.sh "$half_installed/skills/_lib/" 2>/dev/null || true
	# Every sibling lib EXCEPT the one under test, so the wrapper gets far
	# enough to reach the lookup rather than failing earlier for a different
	# reason.
	for f in "${REPO_ROOT}/_lib/"*.sh; do
		case "${f##*/}" in
		issue-trailers.sh) continue ;;
		esac
		cp "$f" "$half_installed/_lib/" 2>/dev/null || true
	done
	[ ! -f "$half_installed/_lib/issue-trailers.sh" ] || {
		echo "fixture failed: the library is still present"
		return 1
	}
	export FAKE_PR_BODY="Closes #808"
	export FAKE_MERGE_SHA="$MERGE_SHA"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$MERGE_SHA"'","checks":[]}'
	run bash -c "cd '$WORK' && APPROVE=1 AC_LOG='$AC_LOG' bash '$half_installed/skills/github-pr-merge/run.sh' --pr 2638 --squash --yes </dev/null"
	case "$output" in
	*"issue-trailers.sh not found"*) ;;
	*)
		echo "a missing shared library was silent: $output"
		return 1
		;;
	esac
	# And it must say what that COSTS, not just that a file is absent.
	case "$output" in
	*"will NOT auto-close"*) ;;
	*)
		echo "the consequence of skipping the rollup was not stated: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran without the library: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: the lookup uses ONE rule, not a candidate list" {
	# The previous commit removed two copies of one regex and, in the same
	# change, introduced two different ways to LOCATE the library that
	# replaced it — a candidate list here, BASH_SOURCE-relative in
	# _lib/epic-completeness-check.sh. Phase 0.5 caught it.
	#
	# Both files now resolve relative to their own location. Asserted on the
	# source because the behaviour is identical either way until a layout
	# diverges, at which point it is a debugging session rather than a test
	# failure.
	local runsh="${REPO_ROOT}/skills/github-pr-merge/run.sh"
	grep -q '_it_lib="\$SCRIPT_DIR/\.\./\.\./_lib/issue-trailers\.sh"' "$runsh" || {
		echo "run.sh no longer resolves the library relative to SCRIPT_DIR"
		return 1
	}
	grep -q 'for _cand in' "$runsh" && {
		echo "run.sh still carries a candidate-path list for the library"
		return 1
	}
	return 0
}
