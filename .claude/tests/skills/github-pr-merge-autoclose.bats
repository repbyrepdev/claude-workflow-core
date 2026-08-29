#!/usr/bin/env bats
# covers: skills/github-pr-merge/run.sh
# shellcheck disable=SC2030,SC2031,SC2089,SC2090
#
# (#2544) The epic-rollup stanza: which issues does a merge close, and whose
# answer is it?
#
# THE ORIGINAL BUG. The stanza scraped `Closes #N` from the MERGE COMMIT
# message. GitHub composes a squash commit from the PR title plus the
# constituent commits and never the PR body — and the body is where the
# trailers live. So on PR #2638 the body carried four and the commit carried
# zero: the sub-issues closed, the epic did not, and the stanza printed
# nothing, because the empty case had no `else`. The broken path and the
# nothing-to-do path were byte-identical.
#
# THE FIRST FIX WAS ALSO WRONG, and worse. Reading the body with the same
# regex made the extractor markdown-blind, and Phase 1 security review
# demonstrated it: a fenced code block, an HTML comment invisible in the
# rendered PR, and the literal phrase "does not close #4010" all yielded
# numbers whose PARENT EPICS would then be closed, recursively. Trading a
# failure-to-close for closing things nobody asked to close is not progress.
#
# THE ANSWER: GitHub already publishes it — `closingIssuesReferences` — and
# it is exact, markdown-aware and already computed. The regex survives only
# as a labelled fallback over the commit message when gh cannot be reached.
#
# These drive the REAL wrapper with a stubbed gh and a recording stand-in for
# auto-close-parent.sh, so what is asserted is which issue numbers the
# wrapper actually hands to the rollup.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
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
		# A REAL origin: the wrapper pulls after the merge, and without a
		# reachable remote it aborts before the rollup stanza is reached —
		# the fixture would then be testing the pull, not this.
		git remote add origin "$ORIGIN"
		git push -q -u origin main
	) || {
		echo "FATAL: fixture repo init failed" >&2
		return 1
	}
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)

	mkdir -p "$WORK/.claude/hooks"
	cat >"$WORK/.claude/hooks/auto-close-parent.sh" <<'AC'
#!/bin/bash
printf '%s\n' "$1" >>"$AC_LOG"
exit 0
AC
	chmod +x "$WORK/.claude/hooks/auto-close-parent.sh"
	mkdir -p "$TEST_TMP/bin"
	export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	case "${TEST_TMP:-}" in
	*/gh-pr-merge-autoclose.*) rm -rf "$TEST_TMP" ;;
	esac
	return 0
}

# gh stub. FAKE_CLOSING is what `--json closingIssuesReferences` returns
# (newline-separated numbers) — the authoritative seam this file is about.
# FAKE_CLOSING_FAIL=1 makes that one query fail so the fallback runs.
_install_gh_shim() {
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"pr view")
	case "$*" in
	*closingIssuesReferences*)
		if [ "${FAKE_CLOSING_FAIL:-0}" = "1" ]; then
			echo "gh: could not resolve PR" >&2
			exit 1
		fi
		printf '%s' "${FAKE_CLOSING:-}"
		exit 0
		;;
	*mergeCommit*) printf '%s\n' "$FAKE_MERGE_SHA" ;;
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
}

_run_merge() { # $1 = wrapper path (default: the real one)
	export FAKE_MERGE_SHA="$MERGE_SHA"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$MERGE_SHA"'","checks":[]}'
	run bash -c "cd '$WORK' && APPROVE=1 AC_LOG='$AC_LOG' bash '${1:-$SCRIPT}' --pr 2638 --squash --yes </dev/null"
}

_called_with() { grep -qx "$1" "$AC_LOG"; }

_commit_with() { # $1 = message
	(cd "$WORK" && git commit -q --allow-empty -m "$1" && git push -q origin main) || return 1
	MERGE_SHA=$(git -C "$WORK" rev-parse HEAD)
}

# Builds a copy of the plugin under $TEST_TMP. $1 = dir name, $2 = mode:
#   full      — every lib present
#   no-lib    — issue-trailers.sh absent (half-installed consumer)
#   truncated — issue-trailers.sh readable but defines nothing
#   broken-re — issue-trailers.sh present with an invalid pattern
_plugin_copy() {
	local root="$TEST_TMP/$1" mode="$2" f
	mkdir -p "$root/skills/github-pr-merge" "$root/_lib" "$root/skills/_lib"
	# NO `|| true` on the copies. A fixture that half-builds and then runs
	# anyway is how a test ends up asserting on a wrapper that died for an
	# unrelated reason — the "never arrived" failure this suite has already
	# produced twice. If the fixture cannot be built, say so and stop.
	cp "${REPO_ROOT}/skills/github-pr-merge/"*.sh "$root/skills/github-pr-merge/" || {
		echo "fixture: could not copy the skill" >&2
		return 1
	}
	# skills/_lib/ too — the wrapper sources skill-common.sh before it ever
	# reaches the library lookup, and a fixture that died earlier would
	# "pass" these tests for the wrong reason.
	cp "${REPO_ROOT}/skills/_lib/"*.sh "$root/skills/_lib/" || {
		echo "fixture: could not copy skills/_lib" >&2
		return 1
	}
	for f in "${REPO_ROOT}/_lib/"*.sh; do
		case "${f##*/}" in
		issue-trailers.sh) [ "$mode" = "no-lib" ] && continue ;;
		esac
		cp "$f" "$root/_lib/" || {
			echo "fixture: could not copy ${f##*/}" >&2
			return 1
		}
	done
	case "$mode" in
	truncated) printf '#!/bin/bash\nset -u\n# truncated mid-write\n' >"$root/_lib/issue-trailers.sh" ;;
	broken-re)
		python3 - "$root/_lib/issue-trailers.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace(
    "ISSUE_TRAILER_RE='(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+'",
    "ISSUE_TRAILER_RE='['")
open(p, 'w', encoding='utf-8').write(s)
PY
		;;
	esac
	printf '%s' "$root"
}

# ---- the authoritative path ---------------------------------------------

@test "autoclose: GitHub's answer drives the rollup (the PR #2638 shape)" {
	# The squash commit carries no trailers; GitHub still knows what the PR
	# closes, because it links from the body. This is the case the original
	# bug silently dropped.
	_install_gh_shim
	export FAKE_CLOSING=$'2551\n2554\n2555\n2556\n'
	_run_merge
	local n
	for n in 2551 2554 2555 2556; do
		_called_with "$n" || {
			echo "auto-close-parent was never called for #$n; log: $(cat "$AC_LOG")"
			echo "output: $output"
			return 1
		}
	done
}

@test "autoclose: markdown that GitHub does NOT link is not closed" {
	# THE SECURITY FINDING. The regex-over-body design closed issues named
	# in fenced code blocks, in HTML comments invisible in the rendered PR,
	# and in the phrase "does not close #N" — verified: it emitted
	# 7, 4010, 4242 and 9999 for exactly that text, against GitHub's 7.
	#
	# Asking GitHub removes the whole class, because GitHub is the thing
	# that decides. Nothing here parses markdown, which is the point.
	_install_gh_shim
	export FAKE_CLOSING=$'7\n'
	_commit_with 'chore: rollup

```
Closes #4242
```
<!-- Closes #9999 -->
This does not close #4010'
	_run_merge
	_called_with 7 || {
		echo "the real closing reference was lost; log: $(cat "$AC_LOG")"
		return 1
	}
	local bad
	for bad in 4242 9999 4010; do
		grep -qx "$bad" "$AC_LOG" && {
			echo "closed #$bad, which GitHub does not link — from markdown a regex cannot read"
			return 1
		}
	done
	true
}

@test "autoclose: GitHub reporting NONE is stated as authoritative" {
	# A PR that genuinely closes nothing is ordinary. But the message has to
	# distinguish it from the fallback coming back empty, which proves
	# nothing — that conflation is the original bug in miniature.
	_install_gh_shim
	export FAKE_CLOSING=""
	_run_merge
	[ ! -s "$AC_LOG" ] || {
		echo "rolled up something when GitHub reported none: $(cat "$AC_LOG")"
		return 1
	}
	case "$output" in
	*"GitHub reports PR #2638 closes no issues"*) ;;
	*)
		echo "an empty authoritative answer was not announced as authoritative: $output"
		return 1
		;;
	esac
}

@test "autoclose: a duplicate in GitHub's answer is passed ONCE" {
	_install_gh_shim
	export FAKE_CLOSING=$'30\n31\n30\n'
	_run_merge
	local n
	n=$(grep -cx 30 "$AC_LOG")
	[ "$n" = "1" ] || {
		echo "expected one call for #30, got $n"
		return 1
	}
	case "$output" in
	*"for 2 closed sub-issue(s)"*) ;;
	*)
		echo "the count message does not reflect the deduped total: $output"
		return 1
		;;
	esac
}

# ---- the fallback -------------------------------------------------------

@test "autoclose: gh failure falls back to the commit message, LABELLED" {
	# The fallback is a guess at GitHub's answer and must say so. Silently
	# substituting a weaker source for an authoritative one is how a wrong
	# result gets trusted.
	_install_gh_shim
	export FAKE_CLOSING_FAIL=1
	_commit_with "chore: rollup

Fixes #4242"
	_run_merge
	_called_with 4242 || {
		echo "the fallback did not read the commit message; log: $(cat "$AC_LOG")"
		return 1
	}
	case "$output" in
	*"could not ask GitHub"*) ;;
	*)
		echo "the fallback was silent about not being authoritative: $output"
		return 1
		;;
	esac
	case "$output" in
	*"GUESS at GitHub"*) ;;
	*)
		echo "the fallback does not describe itself as a guess: $output"
		return 1
		;;
	esac
}

@test "autoclose: an EMPTY fallback is not reported as 'closes nothing'" {
	# On a squash merge the commit carries no trailers, so an empty fallback
	# is the EXPECTED outcome and proves nothing. Announcing it the way the
	# authoritative path announces none would be exactly the false negative
	# this branch exists to remove.
	_install_gh_shim
	export FAKE_CLOSING_FAIL=1
	_run_merge
	[ ! -s "$AC_LOG" ] || {
		echo "rolled up on an empty fallback: $(cat "$AC_LOG")"
		return 1
	}
	case "$output" in
	*"NOT evidence the PR closes nothing"*) ;;
	*)
		echo "an empty fallback was presented as proof: $output"
		return 1
		;;
	esac
	case "$output" in
	*"GitHub reports PR #2638 closes no issues"*)
		echo "the fallback borrowed the authoritative wording: $output"
		return 1
		;;
	esac
}

@test "autoclose: a git-log failure does not abort the stanza" {
	# git log used to skip the ENTIRE stanza via its else. The commit
	# message is now only the fallback's input, so a git failure must not
	# stop GitHub's answer being used.
	_install_gh_shim
	export FAKE_CLOSING=$'5150\n'
	export FAKE_MERGE_SHA="0000000000000000000000000000000000000000"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$MERGE_SHA"'","checks":[]}'
	run bash -c "cd '$WORK' && APPROVE=1 AC_LOG='$AC_LOG' bash '$SCRIPT' --pr 2638 --squash --yes </dev/null"
	case "$output" in
	*"git log failed"*) ;;
	*)
		echo "the git-log failure was silent: $output"
		return 1
		;;
	esac
	_called_with 5150 || {
		echo "GitHub's answer was abandoned because git log failed; log: $(cat "$AC_LOG")"
		return 1
	}
}

# ---- the guards ---------------------------------------------------------

@test "autoclose: an implausible number of closing refs is REFUSED" {
	# The fallback scans a commit message with no bound, and each number
	# costs several API calls in a script that recurses upward through
	# parents — a 65k-char body was measured at ~6,000 numbers and ~24,000
	# calls against a 5,000/hr budget. A merge closing hundreds of issues is
	# a malformed input, not a big epic.
	_install_gh_shim
	local many="" i=1
	while [ "$i" -le 60 ]; do
		many="$many$i"$'\n'
		i=$((i + 1))
	done
	export FAKE_CLOSING="$many"
	_run_merge
	[ ! -s "$AC_LOG" ] || {
		echo "spent API calls on an implausible list: $(grep -c . "$AC_LOG") calls"
		return 1
	}
	case "$output" in
	*"implausible"*) ;;
	*)
		echo "the cap was applied silently: $output"
		return 1
		;;
	esac
}

@test "autoclose: a MISSING shared library is announced, not silently skipped" {
	# The half-installed consumer repo. Skipping quietly here reproduces the
	# original bug exactly: issues closed by GitHub, epic left open, nothing
	# said. The library is hidden by running a copy of the skill whose
	# ../../_lib lacks it — the real resolution rule, as the wrapper runs it.
	_install_gh_shim
	local root
	root=$(_plugin_copy half-installed no-lib)
	[ ! -f "$root/_lib/issue-trailers.sh" ] || {
		echo "fixture failed: the library is still present"
		return 1
	}
	export FAKE_CLOSING=$'808\n'
	_run_merge "$root/skills/github-pr-merge/run.sh"
	case "$output" in
	*"missing or unusable"*) ;;
	*)
		echo "a missing shared library was silent: $output"
		return 1
		;;
	esac
	case "$output" in
	*"will not auto-close"*) ;;
	*)
		echo "the consequence of skipping the rollup was not stated: $output"
		return 1
		;;
	esac
	# CRUCIALLY it must not ALSO claim an answer was obtained. As separate
	# `if` tests this path fell through and printed the empty-result message
	# too — conflating "could not look" with "found nothing".
	case "$output" in
	*"closes no issues"*)
		echo "the no-library path also claimed GitHub answered: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran without the library: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: a TRUNCATED library is caught, and the wrapper survives" {
	# `-r` says readable, not usable. A truncated library passes the
	# readability gate, defines nothing, and then — under `set -euo
	# pipefail` — an undefined function kills the wrapper AFTER the merge
	# has landed. Replacing the `command -v` guard with `if false` broke no
	# test until this one existed.
	_install_gh_shim
	local root
	root=$(_plugin_copy truncated truncated)
	[ -r "$root/_lib/issue-trailers.sh" ] || {
		echo "fixture failed: the stub is not readable, so -r would have caught it"
		return 1
	}
	export FAKE_CLOSING=$'8008\n'
	_run_merge "$root/skills/github-pr-merge/run.sh"
	case "$output" in
	*"Merged PR #2638"*) ;;
	*)
		echo "an unusable library aborted the wrapper after the merge: $output"
		return 1
		;;
	esac
	case "$output" in
	*"missing or unusable"*) ;;
	*)
		echo "a truncated library was not reported: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran with no extractor defined: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: a fallback extraction FAILURE refuses and does not abort" {
	# Two defects in one fixture, both invisible to the library's own test,
	# which exercises the extractor in isolation and never a caller:
	#   1. the assignment was UNGUARDED under `set -euo pipefail`, so the
	#      library's rc>1 path killed the wrapper after the merge, skipping
	#      the post-merge deploy and tag/release blocks;
	#   2. the failure then fell through and announced "no trailers", a
	#      broken parse reported as a PR that closes nothing.
	_install_gh_shim
	local root
	root=$(_plugin_copy shadow broken-re)
	grep -q "ISSUE_TRAILER_RE='\['" "$root/_lib/issue-trailers.sh" || {
		echo "fixture failed: the pattern was not shadowed"
		return 1
	}
	export FAKE_CLOSING_FAIL=1
	_commit_with "chore: rollup

Closes #4242"
	_run_merge "$root/skills/github-pr-merge/run.sh"
	case "$output" in
	*"Merged PR #2638"*) ;;
	*)
		echo "the wrapper aborted before reporting the merge: $output"
		return 1
		;;
	esac
	case "$output" in
	*"trailer extraction failed"*) ;;
	*)
		echo "an extraction failure was not reported as one: $output"
		return 1
		;;
	esac
	case "$output" in
	*"UNKNOWN, not empty"*) ;;
	*)
		echo "the message does not distinguish unknown from empty: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran on an unreliable extraction: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: the lookup resolves relative to the script, not a candidate list" {
	# Removing two copies of one regex while introducing two ways to LOCATE
	# its replacement was the same drift one layer up. Asserted on the
	# source: the behaviour is identical either way until a layout diverges,
	# at which point it is a debugging session rather than a test failure.
	# Matched on the PATH FRAGMENT, not the exact variable spelling —
	# `$SCRIPT_DIR` vs `${SCRIPT_DIR}` is a zero-behaviour edit that broke a
	# more literal earlier form, and a test that breaks on reformatting
	# trains people to edit the test instead of reading it.
	local runsh="${REPO_ROOT}/skills/github-pr-merge/run.sh"
	grep -qE '_it_lib=.*SCRIPT_DIR.*\.\./\.\./_lib/issue-trailers\.sh' "$runsh" || {
		echo "run.sh no longer resolves the library relative to SCRIPT_DIR"
		return 1
	}
	grep -q 'for _cand in' "$runsh" && {
		echo "run.sh still carries a candidate-path list for the library"
		return 1
	}
	true
}
