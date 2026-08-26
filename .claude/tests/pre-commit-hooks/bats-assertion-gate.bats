#!/usr/bin/env bats
# covers: pre-commit-hooks/bats-assertion-gate.sh _lib/bats-assertion-check.sh scripts/refresh-bats-assertion-baseline.sh
#
# (#2631 follow-up) The gate that stops NEW bats assertions which cannot
# fail. bats reports failure through an ERR trap, and on bash 3.2 — what
# macOS ships at /bin/bash, frozen since 2007 over the GPLv3 relicensing in
# bash 4.0 — a failing `[[ ]]` fires neither that trap nor `set -e`. So a
# bare `[[ ]]` only fails a test when it happens to be the block's LAST
# command. 749 such no-ops existed when this was found.
#
# These tests are written entirely in `[ ]` / `case` forms, for the obvious
# reason: a suite guarding this property must not depend on the property
# being fixed first.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$REPO_ROOT/_lib/bats-assertion-check.sh"
	[ -r "$LIB" ]
	TEST_TMP=$(mktemp -d -t bats-assert-gate.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */bats-assert-gate.* ]] && rm -rf "$TEST_TMP"
}

_scan() { # $1 = file contents; echoes the detector's hit count
	printf '%s' "$1" >"$TEST_TMP/probe.bats"
	run bash -c '. "$1"; bats_assertion_scan "$2" | grep -c . || true' _ "$LIB" "$TEST_TMP/probe.bats"
	[ "$status" -eq 0 ]
}

@test "a bare mid-test [[ ]] is reported" {
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
}

@test "the LAST command in a block is exempt — its status IS the test status" {
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n}\n')"
	[ "$output" -eq 0 ]
}

@test "forms that DO fail are not reported" {
	# Each of these fails the test wherever it sits, so none is a finding.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ]\n\t[[ $output == *"hi"* ]] || return 1\n\t[[ $output == *"hi"* ]] && true\n\tcase "$output" in *hi*) ;; *) return 1 ;; esac\n\tassert_output_contains "hi"\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "comments and blank lines do not occupy the last-command slot" {
	# A trailing comment must not make the real final assertion look mid-test.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n\t# trailing comment\n\n}\n')"
	[ "$output" -eq 0 ]
}

@test "multiple offenders in one block are all reported" {
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"a"* ]]\n\t[[ $output == *"b"* ]]\n\t[[ $output == *"c"* ]]\n\ttrue\n}\n')"
	[ "$output" -eq 3 ]
}

@test "each @test block is scored independently" {
	_scan "$(printf '@test "one" {\n\trun echo hi\n\t[[ $output == *"a"* ]]\n\ttrue\n}\n\n@test "two" {\n\trun echo hi\n\t[[ $output == *"b"* ]]\n}\n')"
	# One offender in the first block; the second block ends on its assertion.
	[ "$output" -eq 1 ]
}

@test "the gate REFUSES an increase over the recorded baseline" {
	cd "$REPO_ROOT" || return 1
	# A file with no baseline entry has an implicit baseline of 0, so any
	# offender refuses. Drive the real hook through a staged fixture.
	local work="$TEST_TMP/repo"
	mkdir -p "$work/.claude/tests" "$work/_lib" "$work/pre-commit-hooks"
	cp "$LIB" "$work/_lib/"
	cp "$REPO_ROOT/pre-commit-hooks/bats-assertion-gate.sh" "$work/pre-commit-hooks/"
	printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]]\n\ttrue\n}\n' \
		>"$work/.claude/tests/new.bats"
	(
		cd "$work" || exit 1
		git init -q
		git add -A
	) || return 1
	run bash -c "cd '$work' && ./pre-commit-hooks/bats-assertion-gate.sh"
	[ "$status" -eq 2 ]
	case "$output" in
	*"cannot fail"*) ;;
	*)
		echo "expected the gate to name the problem; got: $output"
		return 1
		;;
	esac
}

@test "the gate PASSES a file that is clean" {
	cd "$REPO_ROOT" || return 1
	local work="$TEST_TMP/repo2"
	mkdir -p "$work/.claude/tests" "$work/_lib" "$work/pre-commit-hooks"
	cp "$LIB" "$work/_lib/"
	cp "$REPO_ROOT/pre-commit-hooks/bats-assertion-gate.sh" "$work/pre-commit-hooks/"
	printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ]\n\ttrue\n}\n' \
		>"$work/.claude/tests/new.bats"
	(
		cd "$work" || exit 1
		git init -q
		git add -A
	) || return 1
	run bash -c "cd '$work' && ./pre-commit-hooks/bats-assertion-gate.sh"
	[ "$status" -eq 0 ]
}

@test "the recorded baseline is current (ratchet, never rises)" {
	# If this fails, someone fixed or added assertions without re-running
	# scripts/refresh-bats-assertion-baseline.sh.
	cd "$REPO_ROOT" || return 1
	run scripts/refresh-bats-assertion-baseline.sh --check
	[ "$status" -eq 0 ]
}

@test "this repo's own three OpenWiki suites are clean (ci-followup)" {
	# They were not: 34 no-op assertions were added across them during
	# #2629/#2631 before the bash 3.2 behaviour was understood. Pinned so
	# they cannot regress.
	cd "$REPO_ROOT" || return 1
	local f
	for f in .claude/tests/skills/openwiki-lane.bats \
		.claude/tests/scripts/bootstrap-machine-openwiki.bats \
		.claude/tests/scripts/bootstrap-repo-openwiki.bats; do
		run bash -c '. "$1"; bats_assertion_scan "$2" | grep -c . || true' _ "$LIB" "$REPO_ROOT/$f"
		[ "$status" -eq 0 ]
		[ "$output" -eq 0 ] || {
			echo "$f regressed: $output assertion(s) that cannot fail"
			return 1
		}
	done
}
