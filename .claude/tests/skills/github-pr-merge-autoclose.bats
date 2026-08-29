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
#   full         — every lib present
#   no-lib       — issue-trailers.sh absent (half-installed consumer)
#   truncated    — readable but defines nothing
#   broken-re    — present with an invalid pattern
#   source-fails — defines everything, but its LAST statement returns
#                  non-zero, so `. file` itself reports failure
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
	source-fails)
		# Everything is defined; only the trailing status is non-zero.
		# `. file` returns that status, and under `set -euo pipefail` an
		# unguarded source therefore kills the wrapper — after the merge
		# has landed.
		printf '\nfalse\n' >>"$root/_lib/issue-trailers.sh"
		;;
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

@test "autoclose: the library is found relative to the SCRIPT, not the cwd" {
	# Converted from a source grep, which CodeRabbit raised twice: the
	# earlier form asserted the literal assignment text and broke on a
	# `${SCRIPT_DIR}` reformat with zero behaviour change, which trains
	# people to edit the test instead of reading it.
	#
	# The property that matters is behavioural and is asserted here: the
	# same wrapper copy, run from a DIFFERENT working directory, still
	# finds its own sibling library. A cwd-relative lookup passes when run
	# from the repo and fails from anywhere else — which is precisely the
	# shape that would ship broken to a consumer.
	_install_gh_shim
	export FAKE_CLOSING=$'4242\n'
	local root
	root=$(_plugin_copy cwdtest full)

	# Run with the WORK repo as cwd (as every other test does) — the
	# wrapper lives somewhere else entirely, so a cwd-relative lookup has
	# nothing to find.
	_run_merge "$root/skills/github-pr-merge/run.sh"
	_called_with 4242 || {
		echo "the wrapper could not find its own library when run from another directory; log: $(cat "$AC_LOG")"
		echo "output: $output"
		return 1
	}
	case "$output" in
	*"missing or unusable"*)
		echo "the library was reported missing though it sits beside the wrapper: $output"
		return 1
		;;
	esac
}

@test "autoclose: a MISSING auto-close-parent hook is announced, not skipped in silence" {
	# `if [ -x "$AUTO_CLOSE" ]` had no else, so a consumer repo without the
	# hook installed got no rollup and no word about it — "nothing happened
	# and nothing was said", sitting one level ABOVE the code written to
	# remove exactly that.
	_install_gh_shim
	export FAKE_CLOSING=$'4242\n'
	rm -f "$WORK/.claude/hooks/auto-close-parent.sh"
	_run_merge
	case "$output" in
	*"missing or not executable"*) ;;
	*)
		echo "a missing rollup hook was silent: $output"
		return 1
		;;
	esac
	case "$output" in
	*"will not auto-close"*) ;;
	*)
		echo "the consequence was not stated: $output"
		return 1
		;;
	esac
	# And the merge itself still completed — this block is warn-only.
	case "$output" in
	*"Merged PR #2638"*) ;;
	*)
		echo "a missing rollup hook broke the merge path: $output"
		return 1
		;;
	esac
}

@test "autoclose: a NON-EXECUTABLE rollup hook is treated as missing" {
	# The other half of `-x`. A file that exists but lost its bit is the
	# likelier real-world shape (a bad checkout, a copied tree), and it must
	# not read as "installed and fine".
	_install_gh_shim
	export FAKE_CLOSING=$'4242\n'
	chmod -x "$WORK/.claude/hooks/auto-close-parent.sh"
	_run_merge
	case "$output" in
	*"missing or not executable"*) ;;
	*)
		echo "a non-executable rollup hook was silent: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup somehow ran: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: library present vs absent differ in BEHAVIOUR, not just source" {
	# CodeRabbit's point on the source-grep test: pin the behaviour, not the
	# spelling. Two runs of the SAME wrapper copy, identical inputs, the
	# only difference being whether ../../_lib carries the library.
	_install_gh_shim
	export FAKE_CLOSING=$'909\n'

	local with_lib
	with_lib=$(_plugin_copy beh-with full)
	_run_merge "$with_lib/skills/github-pr-merge/run.sh"
	_called_with 909 || {
		echo "with the library present the rollup did not run; log: $(cat "$AC_LOG")"
		return 1
	}

	: >"$AC_LOG"
	local without_lib
	without_lib=$(_plugin_copy beh-without no-lib)
	_run_merge "$without_lib/skills/github-pr-merge/run.sh"
	[ ! -s "$AC_LOG" ] || {
		echo "with the library absent the rollup still ran: $(cat "$AC_LOG")"
		return 1
	}
	case "$output" in
	*"missing or unusable"*) ;;
	*)
		echo "the absent-library run did not report why it did nothing: $output"
		return 1
		;;
	esac
}

@test "autoclose: a library whose SOURCE fails does not kill the wrapper" {
	# `. file` returns the status of the file's last statement. Every other
	# call in the rollup stanza was guarded for that reason and the source
	# itself was not, so a library ending on a non-zero statement — a
	# truncated write stopping mid-conditional, a future top-level guard —
	# terminated the wrapper here, AFTER the merge, skipping the post-merge
	# deploy and tag/release chain.
	#
	# The library in this fixture defines everything correctly; only its
	# trailing status is non-zero, so nothing but the source guard can
	# distinguish it from a healthy one.
	_install_gh_shim
	export FAKE_CLOSING=$'4242\n'
	local root
	root=$(_plugin_copy srcfail source-fails)
	_run_merge "$root/skills/github-pr-merge/run.sh"
	case "$output" in
	*"Merged PR #2638"*) ;;
	*)
		echo "a failing source aborted the wrapper after the merge: $output"
		return 1
		;;
	esac
	case "$output" in
	*"returned non-zero"*) ;;
	*)
		echo "the failing source was not reported: $output"
		return 1
		;;
	esac
	# Treated as unusable rather than half-trusted.
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran on a library that failed to source: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: a library missing ISSUE_TRAILER_MAX is caught by the gate" {
	# THE REGRESSION THIS COMMIT FIXES. The previous commit removed
	# `${ISSUE_TRAILER_MAX:-50}` in favour of the bare `$ISSUE_TRAILER_MAX`
	# — correct, since the gate guarantees the library is sourced — but did
	# not add the variable to the gate. A STALE library defining all three
	# functions and not the constant therefore passed, and `set -u` aborted
	# the wrapper at the bare expansion, after the merge had landed.
	#
	# That is a real deployment shape: a consumer whose `_lib` predates the
	# shared cap. The fixture is exactly that — every function present, the
	# constant absent.
	_install_gh_shim
	local root
	root=$(_plugin_copy stalelib full)
	python3 - "$root/_lib/issue-trailers.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
out = []
for line in s.split('\n'):
    if line.startswith('ISSUE_TRAILER_MAX='):
        out.append('# (removed to simulate a library predating the shared cap)')
    else:
        out.append(line)
open(p, 'w', encoding='utf-8').write('\n'.join(out))
PY
	grep -q '^ISSUE_TRAILER_MAX=' "$root/_lib/issue-trailers.sh" && {
		echo "fixture failed: the constant is still defined"
		return 1
	}
	# Every function must still be there, or this would pass via the
	# command -v checks instead of the one under test.
	local fn
	for fn in issue_trailers_for_pr issue_trailers_extract issue_trailers_count; do
		grep -q "^$fn()" "$root/_lib/issue-trailers.sh" || {
			echo "fixture failed: $fn went missing too"
			return 1
		}
	done

	export FAKE_CLOSING=$'4242\n'
	_run_merge "$root/skills/github-pr-merge/run.sh"
	# The wrapper SURVIVED — that is the whole point — and the STATUS is
	# what proves it. The "Merged PR" line can sit in the output of a run
	# that later failed and returned non-zero, so matching on it alone
	# proves the merge happened, not that the wrapper finished.
	[ "$status" -eq 0 ] || {
		echo "a stale library made the wrapper exit $status: $output"
		return 1
	}
	case "$output" in
	*"Merged PR #2638"*) ;;
	*)
		echo "a stale library aborted the wrapper before the merge: $output"
		return 1
		;;
	esac
	case "$output" in
	*"missing or unusable"*) ;;
	*)
		echo "a stale library was not reported: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran against a stale library: $(cat "$AC_LOG")"
		return 1
	}
}

@test "autoclose: a NON-NUMERIC ISSUE_TRAILER_MAX is rejected at the gate" {
	# `ISSUE_TRAILER_MAX=abc` passes an emptiness check, and the later `-gt`
	# then ERRORS instead of comparing: its status is discarded,
	# rollup_state stays "ok", and the references are processed UNCAPPED —
	# the cap silently absent exactly when someone has tried to configure
	# it, which is worse than never having had one.
	_install_gh_shim
	local root
	root=$(_plugin_copy badmax full)
	export FAKE_CLOSING=$'4242\n'
	export FAKE_MERGE_SHA="$MERGE_SHA"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$MERGE_SHA"'","checks":[]}'
	run bash -c "cd '$WORK' && ISSUE_TRAILER_MAX=abc APPROVE=1 AC_LOG='$AC_LOG' bash '$root/skills/github-pr-merge/run.sh' --pr 2638 --squash --yes </dev/null"
	[ "$status" -eq 0 ] || {
		echo "a bad cap value made the wrapper exit $status: $output"
		return 1
	}
	case "$output" in
	*"missing or unusable"*) ;;
	*)
		echo "a non-numeric cap was accepted: $output"
		return 1
		;;
	esac
	[ ! -s "$AC_LOG" ] || {
		echo "the rollup ran UNCAPPED with a bad cap value: $(cat "$AC_LOG")"
		return 1
	}
}
