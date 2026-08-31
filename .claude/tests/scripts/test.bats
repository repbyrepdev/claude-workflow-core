#!/usr/bin/env bats
# covers: scripts/test.sh
#
# Regression tests for scripts/test.sh (#53). The script is the meta-tool
# every downstream gate trusts — silent failures here corrupt the
# .claude/logs/bats-run.jsonl audit. Both bugs locked in below survived
# in main for multiple versions and were only caught by CR-CLI on PR #51.
#   - find rc=1 on missing roots → set -o pipefail abort
#     (exercised by "--coverage exits 0 with all roots missing" and
#      "--coverage exits 0 when only some roots exist (plugin-shape)")
#   - grep rc=1 on empty TAP match → set -o pipefail abort in FAIL summary
#     (exercised by "FAIL summary path runs end-to-end")

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/test.sh"
	# TEST_TMP (NOT $TMPDIR — that's the POSIX scratch-dir var consulted
	# by mktemp + many child processes; clobbering would silently redirect
	# their temp files into our fixture tree). Repo standard form
	# `mktemp -d -t pfx.XXXXXX` (memory: feedback_check_existing_test_patterns).
	# Capture rc explicitly so an mktemp failure (ENOSPC, unwritable TMPDIR,
	# sandbox deny) fails loudly — test.sh's TEST_REPO_ROOT '+set' check
	# would catch a silent TEST_TMP="" leak, but failing here is cleaner.
	TEST_TMP=$(mktemp -d -t test-bats.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	[ -d "$TEST_TMP" ] || {
		echo "FATAL: TEST_TMP='$TEST_TMP' not a directory after mktemp" >&2
		return 1
	}
	# Unset env that test.sh reads, so parent-shell leakage can't bleed
	# into fixture runs (a developer or CI runner with BATS_LOG=/some/path
	# exported would silently redirect our isolated logging).
	unset BATS_LOG SHA256_WARNED
	export TEST_REPO_ROOT="$TEST_TMP"
	# (#2642) The fixture is a GIT REPO now, because --coverage asks git
	# which shell files exist rather than walking the filesystem. That is
	# the point of the change: `find` over directories counts untracked
	# files and, on a consumer where .claude/hooks is a real directory
	# rather than the symlink it is here, counts the same file twice.
	#
	# Every assertion below keeps its meaning: an empty repo has zero
	# tracked .sh, so "Shell scripts in scope: 0" and "Coverage: N/A" still
	# describe the missing-roots case they were written for (#53).
	git -C "$TEST_TMP" init -q
	git -C "$TEST_TMP" config user.email t@t
	git -C "$TEST_TMP" config user.name t
}

# Stage whatever the test just created, so git can see it. Coverage counts
# TRACKED files; an unstaged fixture is invisible by design, not by accident.
_track() {
	# NO `|| true`. A silently failed `git add` leaves zero tracked files,
	# and "Shell scripts in scope: 0" is exactly what two of these tests
	# assert — so a broken fixture would satisfy them while proving
	# nothing about the code.
	git -C "$TEST_TMP" add -A || {
		echo "fixture staging failed — the coverage assertions below would pass on an empty repo"
		return 1
	}
}

teardown() {
	unset TEST_REPO_ROOT
	# Defensive: only rm a tmpdir that matches our prefix. Catches
	# upstream-setup-failure cases where TEST_TMP could be empty/unset.
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */test-bats.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "test.sh exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "TEST_REPO_ROOT='' (set + empty) exits 2 with explicit error" {
	# Guards the +set distinction from a future plain `[ -n "${TEST_REPO_ROOT:-}" ]`
	# regression. If empty silently falls back to production REPO_ROOT, bats
	# fixture runs would corrupt the real .claude/logs/bats-run.jsonl audit.
	TEST_REPO_ROOT='' run "$SCRIPT" --coverage
	[ "$status" -eq 2 ]
	[[ $output == *"TEST_REPO_ROOT is set but empty"* ]]
}

@test "TEST_REPO_ROOT=/nonexistent exits 2 with not-a-directory error" {
	# Guards the [ -d ] check from regressing to a less actionable cd failure.
	TEST_REPO_ROOT="$TEST_TMP/does-not-exist" run "$SCRIPT" --coverage
	[ "$status" -eq 2 ]
	[[ $output == *"is not a directory"* ]]
}

@test "--coverage exits 0 with all roots missing (find rc=1 case)" {
	# #53: find rc=1 on missing starting paths + set -o pipefail aborted
	# the script. With ALL roots missing, --coverage must still emit
	# Coverage: N/A and exit 0.
	_track
	run "$SCRIPT" --coverage
	[ "$status" -eq 0 ]
	[[ $output == *"Shell scripts in scope: 0"* ]] || return 1
	[[ $output == *"Coverage: N/A"* ]]
}

@test "--coverage exits 0 when only some roots exist (plugin-shape)" {
	# Plugin repo ships scripts/ + .claude/tests/ but NOT .claude/scripts/
	# or .claude/hooks/ — exactly the case CR-CLI flagged. Also asserts
	# the success-branch NOTE so a future bug in the REPO_ROOT swap line
	# (e.g. typo'd self-assign) is caught.
	mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/.claude/tests"
	cat >"$TEST_TMP/scripts/foo.sh" <<-'EOF'
		#!/bin/bash
		set -euo pipefail
		echo hi
	EOF
	chmod +x "$TEST_TMP/scripts/foo.sh"
	cat >"$TEST_TMP/.claude/tests/foo.bats" <<-'EOF'
		#!/usr/bin/env bats
		# covers: scripts/foo.sh
		@test "noop" { true; }
	EOF
	_track
	run "$SCRIPT" --coverage
	[ "$status" -eq 0 ]
	[[ $output == *"TEST_REPO_ROOT override active"* ]] || return 1
	[[ $output == *"Shell scripts in scope: 1"* ]] || return 1
	[[ $output == *"Bats test files:"*"1"* ]] || return 1
	[[ $output == *"Coverage: 100%"* ]]
}

@test "--coverage 50% partial coverage (1 of 2 .sh covered)" {
	# Exercises the integer-arithmetic path pct=$((covered*100/sh_count)).
	# Boundary tests cover 0%/100%/N/A — without this case, a refactor
	# that flipped numerator/denominator or used floor-only division would
	# pass at the boundaries while silently corrupting partial reports.
	mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/.claude/tests"
	echo "#!/bin/bash" >"$TEST_TMP/scripts/a.sh"
	echo "#!/bin/bash" >"$TEST_TMP/scripts/b.sh"
	cat >"$TEST_TMP/.claude/tests/cover.bats" <<-'EOF'
		#!/usr/bin/env bats
		# covers: scripts/a.sh
		@test "x" { true; }
	EOF
	_track
	run "$SCRIPT" --coverage
	[ "$status" -eq 0 ]
	[[ $output == *"Shell scripts in scope: 2"* ]] || return 1
	[[ $output == *"Coverage: 50%"* ]]
}

@test "--coverage exits 0 with existing root containing zero .sh files" {
	# Edge: scripts/ dir exists but is empty. find produces no output,
	# the while-loop must iterate zero times (no spurious covered/uncovered++).
	mkdir -p "$TEST_TMP/scripts"
	_track
	run "$SCRIPT" --coverage
	[ "$status" -eq 0 ]
	[[ $output == *"Shell scripts in scope: 0"* ]] || return 1
	[[ $output == *"Covered"*"0"* ]] || return 1
	[[ $output == *"Uncovered:"*"0"* ]] || return 1
	[[ $output == *"Coverage: N/A"* ]]
}

@test "--coverage exits 0 with .claude/tests missing" {
	# Symmetric: scripts/ populated but no .bats test dir.
	mkdir -p "$TEST_TMP/scripts"
	echo "#!/bin/bash" >"$TEST_TMP/scripts/foo.sh"
	chmod +x "$TEST_TMP/scripts/foo.sh"
	_track
	run "$SCRIPT" --coverage
	[ "$status" -eq 0 ]
	[[ $output == *"Bats test files:"*"0"* ]] || return 1
	[[ $output == *"Coverage: 0%"* ]]
}

@test "--coverage handles every .sh root populated (no missing-dir bug)" {
	# Sanity: all 5 .sh-scan roots exist + .claude/tests for bats-count.
	# Only the 5 .sh roots seed a sample.sh; .claude/tests gets a .bats
	# (the script's find for *.sh ignores .claude/tests by directory split).
	# The sample.bats deliberately omits a `# covers:` header so the
	# COVERED_PATHS scan runs with zero matches — a no-match smoke test.
	for r in .claude/scripts .claude/hooks .claude/skills .claude/local-backups scripts; do
		mkdir -p "$TEST_TMP/$r"
		echo "#!/bin/bash" >"$TEST_TMP/$r/sample.sh"
	done
	mkdir -p "$TEST_TMP/.claude/tests"
	echo '@test "x" { true; }' >"$TEST_TMP/.claude/tests/sample.bats"
	_track
	run "$SCRIPT" --coverage
	[ "$status" -eq 0 ]
	[[ $output == *"Shell scripts in scope: 5"* ]] || return 1
	# Locks in that the script reached the end of the coverage block
	# without aborting (the COVERED_PATHS pipeline runs successfully here
	# because no .bats has a `# covers:` header).
	[[ $output == *"Coverage: 0%"* ]]
}

@test "FAIL summary path runs end-to-end (#53)" {
	# #53: the FAIL-DETAILS recap pipeline `... | grep -E '^(not ok |# )'
	# | head | sed ...` could return rc=1 from grep on a no-match, aborting
	# the script under set -o pipefail mid-run. The fix is `|| true` on
	# both recap pipelines in the FAIL branch (`grep -E '^(not ok |# )'
	# ... | sed ... || true` — direct print + the FAIL_DETAILS command
	# substitution form). Line numbers intentionally omitted — they drift.
	#
	# This test drives a failing target through the full FAIL path: the
	# runner must NOT abort, must reach '=== Summary ===', must render the
	# per-file '✗' line, and must emit the FAILURE DETAILS recap block.
	# All three assertions are downstream of the pipefail abort — any
	# regression that re-introduces it will fail at least one.
	#
	# Note: bats output for `return 1` contains 'not ok' + '#' lines that
	# DO match the recap-grep, so this test doesn't directly drive grep
	# rc=1. The `|| true` in the FAIL branch is the static guard for the
	# empty-match case; this test is the dynamic guard for the full FAIL
	# path reaching the recap block under pipefail.
	mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/.claude/tests" "$TEST_TMP/.claude/logs"
	cat >"$TEST_TMP/.claude/tests/fail.bats" <<-'EOF'
		#!/usr/bin/env bats
		@test "intentional fail" { return 1; }
	EOF
	run "$SCRIPT" --no-log "$TEST_TMP/.claude/tests/fail.bats"
	[ "$status" -eq 1 ]
	[[ $output == *"=== Summary ==="* ]] || return 1
	[[ $output == *"✗ "*"fail.bats"* ]] || return 1
	[[ $output == *"FAILURE DETAILS"* ]]
}

# --- #2631 follow-up: harness trust -------------------------------------
#
# Three defects found by the phase-1 panel on the branch that added --shell.
# Each is locked in below, because each made the runner REPORT something it
# had not done — the one failure mode a test runner must never have.

@test "a non-bash TEST_BASH is REFUSED, not run as a green suite of zero tests" {
	# `TEST_BASH=/usr/bin/true scripts/test.sh <file>` printed
	# '✓ file (0 passed)', exited 0, and appended {"status":"pass"} to
	# bats-run.jsonl — which pre-commit bats-gate.sh and the pre-push
	# pipeline gate both read as "this file's tests ran and held". Zero tests
	# executed. TEST_BASH is not matched by the skip-approval hook's `*_SKIP`
	# pattern, so it needed no operator approval either.
	mkdir -p "$TEST_TMP/.claude/tests"
	printf '#!/usr/bin/env bats\n@test "t" { true; }\n' >"$TEST_TMP/.claude/tests/ok.bats"
	TEST_BASH=/usr/bin/true run "$SCRIPT" --no-log "$TEST_TMP/.claude/tests/ok.bats"
	[ "$status" -eq 2 ] || {
		echo "expected refusal (2), got $status: $output"
		return 1
	}
	case "$output" in
	*BASH_VERSION*) ;;
	*)
		echo "expected the refusal to name why; got: $output"
		return 1
		;;
	esac
}

@test "a run that executes ZERO tests cannot report pass" {
	# Belt and braces behind the check above: whatever the cause, rc=0 with
	# nothing executed must not reach the log as 'pass'. One verdict feeds the
	# console line, the exit code and the JSONL entry, so they cannot diverge.
	mkdir -p "$TEST_TMP/.claude/tests"
	printf '#!/usr/bin/env bats\n# no tests here\n' >"$TEST_TMP/.claude/tests/empty.bats"
	run "$SCRIPT" --no-log "$TEST_TMP/.claude/tests/empty.bats"
	[ "$status" -ne 0 ] || {
		echo "a zero-test file reported success: $output"
		return 1
	}
	case "$output" in
	*"no tests executed"*) ;;
	*)
		echo "expected the reason in the output; got: $output"
		return 1
		;;
	esac
}

@test "--shell selects the shell the TEST BODY runs under, not just the front-end" {
	# `bats` re-execs bats-exec-test and friends, each `#!/usr/bin/env bash`,
	# so `<shell> $(command -v bats)` overrode only the front-end and the
	# assertions still ran under whatever PATH resolved. An acceptance run
	# reported 'bash 3.2' and executed under 5. The fixture below asserts the
	# major version it actually sees, so it can only pass if --shell reached
	# the test body.
	# Two bashes of DIFFERENT major versions, discovered by asking each
	# candidate rather than assuming /bin/bash is 3.x — true on macOS, false
	# on Linux runners, where /bin/bash is 5 and this test would have been
	# comparing a shell against itself and passing vacuously.
	local cand maj a="" a_maj="" b="" b_maj=""
	for cand in /bin/bash /usr/bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
		[ -n "$cand" ] && [ -x "$cand" ] || continue
		maj=$("$cand" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null) || continue
		[ -n "$maj" ] || continue
		if [ -z "$a" ]; then
			a=$cand
			a_maj=$maj
		elif [ "$maj" != "$a_maj" ]; then
			b=$cand
			b_maj=$maj
			break
		fi
	done
	[ -n "$a" ] || skip "no usable bash found"
	[ -n "$b" ] || skip "only one bash major version available ($a_maj) — nothing to contrast"

	mkdir -p "$TEST_TMP/.claude/tests"
	cat >"$TEST_TMP/.claude/tests/probe.bats" <<-'PROBE'
		#!/usr/bin/env bats
		@test "the body sees the requested bash" {
			[ "${BASH_VERSINFO[0]}" = "$WANT_MAJOR" ]
		}
	PROBE
	# Positive: ask for A's major, run under A.
	WANT_MAJOR="$a_maj" run "$SCRIPT" --no-log --shell "$a" "$TEST_TMP/.claude/tests/probe.bats"
	[ "$status" -eq 0 ] || {
		echo "--shell $a ($a_maj) did not reach the test body: $output"
		return 1
	}
	# Negative control: ask for A's major while running B. This must FAIL —
	# it is what proves the assertion above is load-bearing rather than
	# passing because the probe never ran.
	WANT_MAJOR="$a_maj" run "$SCRIPT" --no-log --shell "$b" "$TEST_TMP/.claude/tests/probe.bats"
	[ "$status" -ne 0 ] || {
		echo "--shell $b ($b_maj) still reported major $a_maj — the shim is not selecting"
		return 1
	}
}

@test "--shell is parsed BEFORE the gate that advertises it as the remedy" {
	# The gate exited before the option loop that sets TEST_BASH, so the flag
	# printed in its own error message could not lift it. --help was likewise
	# unreachable. Ordering, not logic — and nothing exercised --shell at all.
	run "$SCRIPT" --shell /nonexistent/bash --no-log
	[ "$status" -eq 2 ]
	case "$output" in
	*"not executable"*) ;;
	*)
		echo "expected a validated --shell path; got: $output"
		return 1
		;;
	esac
}

@test "--shell reaches the test body even where only ONE bash exists" {
	# The two-major test above skips on a standard Linux runner, where
	# /bin/bash, /usr/bin/bash and `command -v bash` all resolve to the same
	# bash 5 — so the invariant went unverified precisely in CI, which is
	# where the regression would land. This checks the same property without
	# needing a second bash: --shell points at a WRAPPER that execs the real
	# bash after setting a marker. If the shim reaches the test body, the
	# marker is visible inside it; if bats re-execs some other `bash` from
	# PATH — the original defect — it is not.
	mkdir -p "$TEST_TMP/wrap" "$TEST_TMP/.claude/tests"
	# NOT `|| skip`. bats itself runs under bash, so "no bash on PATH" is not
	# a missing optional tool — it is a broken environment, and skipping would
	# turn the one CI-observable check of this invariant into a silent pass.
	local real
	real=$(command -v bash) || {
		echo "no bash on PATH — bats cannot have run without one; environment is broken"
		return 1
	}
	cat >"$TEST_TMP/wrap/bash" <<-WRAP
		#!/bin/sh
		SHELL_SHIM_MARKER=reached-the-body
		export SHELL_SHIM_MARKER
		exec "$real" "\$@"
	WRAP
	chmod +x "$TEST_TMP/wrap/bash"

	cat >"$TEST_TMP/.claude/tests/marker.bats" <<-'PROBE'
		#!/usr/bin/env bats
		@test "the body was interpreted by the requested shell" {
			[ "${SHELL_SHIM_MARKER:-}" = "reached-the-body" ]
		}
	PROBE

	run "$SCRIPT" --no-log --shell "$TEST_TMP/wrap/bash" "$TEST_TMP/.claude/tests/marker.bats"
	[ "$status" -eq 0 ] || {
		echo "--shell did not reach the test body: $output"
		return 1
	}

	# Negative control: without --shell the marker must be absent, which is
	# what proves the assertion above is load-bearing rather than passing
	# because the variable leaked in from this process.
	run "$SCRIPT" --no-log "$TEST_TMP/.claude/tests/marker.bats"
	[ "$status" -ne 0 ] || {
		echo "the marker was set without --shell — the probe proves nothing"
		return 1
	}
}

@test "#2642: --coverage REFUSES when the scope library cannot load" {
	# The dangerous default. Without the predicate, the old code would have
	# produced a denominator from whatever roots happened to exist — a
	# coverage figure over an unknown scope, which is the exact defect this
	# issue documents (~60% printed over 22% of the repo, near enough to the
	# true 58.5% that nobody looked twice).
	#
	# A copy of the script with no library beside it is the shape a broken
	# plugin install actually takes.
	local fake="$TEST_TMP/fakeplugin"
	mkdir -p "$fake/scripts" "$fake/_lib"
	cp "$SCRIPT" "$fake/scripts/test.sh"
	chmod +x "$fake/scripts/test.sh"
	# Deliberately NOT copying _lib/bats-scope.sh.
	run bash -c "cd '$TEST_TMP' && TEST_SH_FULL_OK=1 '$fake/scripts/test.sh' --coverage"
	[ "$status" -eq 2 ] || {
		echo "a missing scope library produced a coverage figure anyway (rc $status): $output"
		return 1
	}
	[[ $output == *"bats-scope"* ]] || {
		echo "the refusal does not name the missing library: $output"
		return 1
	}
	[[ $output != *"Coverage:"* ]] || {
		echo "it printed a percentage despite refusing: $output"
		return 1
	}
}
