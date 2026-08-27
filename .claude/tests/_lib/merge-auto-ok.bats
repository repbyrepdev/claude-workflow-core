#!/usr/bin/env bats
# covers: _lib/merge-auto-ok.sh
#
# (#2549) The predicate that decides whether a PR is provably green enough to
# ARM auto-merge instead of holding the operator gate.
#
# Every test drives the REAL function against a captured-shape `gh pr view`
# payload, because the failure that matters is not "does it say yes when
# everything is green" — it is whether it says yes when a signal is MISSING or
# HOLLOW. Those are the fail-open shapes, and each one here is a case observed
# on a real PR:
#
#   * #2540: the CodeRabbit check reported `pass` with description "Review
#     rate limited" while having performed no review. Check state alone is
#     not evidence.
#   * #2635: CodeRabbit auto-PAUSED after too many commits; the check went
#     green while the review had stopped.
#
# rc contract: 0 arm · 1 hold (a signal is not green) · 2 hold (a signal could
# not be read). 1 and 2 are kept distinct because "not green" and "I could not
# tell" call for different operator action.

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$PLUGIN/_lib/merge-auto-ok.sh"
	[ -r "$LIB" ]
	TEST_TMP=$(mktemp -d -t merge-auto.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/bin"
	# A required-checks SSOT with exactly two entries keeps the fixtures small
	# while still exercising the per-check loop.
	cat >"$TEST_TMP/checks.yml" <<-'Y'
		required:
		  - check_name: CodeRabbit
		  - check_name: verify
	Y
	# thread helper stub: prints whatever the test puts in THREADS_OUT.
	cat >"$TEST_TMP/bin/threads.sh" <<-'T'
		#!/bin/bash
		[ -n "${THREADS_RC:-}" ] && exit "$THREADS_RC"
		printf '%s\n' "${THREADS_OUT:-0}"
	T
	chmod +x "$TEST_TMP/bin/threads.sh"
	export MERGE_AUTO_CHECKS_SSOT="$TEST_TMP/checks.yml"
	export MERGE_AUTO_THREAD_HELPER="$TEST_TMP/bin/threads.sh"
	unset MERGE_GATE_AUTO
}

teardown() {
	case "${TEST_TMP:-}" in
	*/merge-auto.*) rm -rf "$TEST_TMP" ;;
	esac
	unset MERGE_AUTO_CHECKS_SSOT MERGE_AUTO_THREAD_HELPER GH_VIEW_OUT THREADS_OUT THREADS_RC MERGE_GATE_AUTO
}

# Stub `gh` so `gh pr view` returns $1 verbatim.
_stub_gh() {
	printf '%s' "$1" >"$TEST_TMP/view.json"
	cat >"$TEST_TMP/bin/gh" <<-'G'
		#!/bin/bash
		cat "$VIEW_FILE"
	G
	chmod +x "$TEST_TMP/bin/gh"
	export VIEW_FILE="$TEST_TMP/view.json"
}

_ok_view() { # a fully green PR
	cat <<-'J'
		{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":false,"labels":[],
		 "statusCheckRollup":[
		   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"Review completed"},
		   {"name":"verify","conclusion":"SUCCESS","description":"ok"}]}
	J
}

_call() {
	run env PATH="$TEST_TMP/bin:$PATH" VIEW_FILE="$TEST_TMP/view.json" \
		MERGE_AUTO_CHECKS_SSOT="$MERGE_AUTO_CHECKS_SSOT" \
		MERGE_AUTO_THREAD_HELPER="$MERGE_AUTO_THREAD_HELPER" \
		THREADS_OUT="${THREADS_OUT:-0}" THREADS_RC="${THREADS_RC:-}" \
		MERGE_GATE_AUTO="${MERGE_GATE_AUTO:-1}" \
		bash -c ". '$LIB'; merge_auto_ok 42"
}

@test "arms when every signal is green" {
	_stub_gh "$(_ok_view)"
	_call
	[ "$status" -eq 0 ]
	case "$output" in
	*"0 unaddressed"*) ;;
	*)
		echo "expected the reason to name the signals; got: $output"
		return 1
		;;
	esac
}

@test "a check that passed WITHOUT running does not count as green (#2540)" {
	# The CodeRabbit check reported pass with "Review rate limited" while
	# having performed no review. Treating state alone as evidence would have
	# auto-merged a PR nothing reviewed.
	_stub_gh '{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":false,"labels":[],
	 "statusCheckRollup":[
	   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"Review rate limited"},
	   {"name":"verify","conclusion":"SUCCESS","description":"ok"}]}'
	_call
	[ "$status" -eq 2 ]
	case "$output" in
	*"without running"*) ;;
	*)
		echo "expected a hollow-check refusal; got: $output"
		return 1
		;;
	esac
}

@test "an auto-PAUSED review does not count as green (#2635)" {
	# CodeRabbit auto-paused after an influx of commits; the check stayed
	# green while the review had stopped.
	_stub_gh '{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":false,"labels":[],
	 "statusCheckRollup":[
	   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"review paused"},
	   {"name":"verify","conclusion":"SUCCESS","description":"ok"}]}'
	_call
	[ "$status" -eq 2 ]
}

@test "a required check ABSENT from the rollup is rc 2, not green" {
	# The dangerous shape: a check that never reported looks like nothing at
	# all. Counting only the checks present would call this PR green.
	_stub_gh '{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":false,"labels":[],
	 "statusCheckRollup":[{"name":"verify","conclusion":"SUCCESS","description":"ok"}]}'
	_call
	[ "$status" -eq 2 ]
	case "$output" in
	*absent*) ;;
	*)
		echo "expected an absent-check refusal; got: $output"
		return 1
		;;
	esac
}

@test "a failing required check holds the gate (rc 1)" {
	_stub_gh '{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":false,"labels":[],
	 "statusCheckRollup":[
	   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"Review completed"},
	   {"name":"verify","conclusion":"FAILURE","description":"boom"}]}'
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*"not green"*) ;;
	*)
		echo "expected a not-green refusal; got: $output"
		return 1
		;;
	esac
}

@test "unaddressed threads hold the gate" {
	_stub_gh "$(_ok_view)"
	THREADS_OUT=2
	export THREADS_OUT
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*"unaddressed CR thread"*) ;;
	*)
		echo "expected a thread refusal; got: $output"
		return 1
		;;
	esac
}

@test "an unreadable thread count is rc 2, never treated as zero" {
	_stub_gh "$(_ok_view)"
	THREADS_RC=2
	export THREADS_RC
	_call
	[ "$status" -eq 2 ]
}

@test "a non-numeric thread count is rc 2" {
	_stub_gh "$(_ok_view)"
	THREADS_OUT="lots"
	export THREADS_OUT
	_call
	[ "$status" -eq 2 ]
}

@test "mergeStateStatus other than CLEAN holds the gate" {
	_stub_gh '{"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","isDraft":false,"labels":[],
	 "statusCheckRollup":[
	   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"Review completed"},
	   {"name":"verify","conclusion":"SUCCESS","description":"ok"}]}'
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*BLOCKED*) ;;
	*)
		echo "expected the state to be named; got: $output"
		return 1
		;;
	esac
}

@test "the needs-operator label forces the human gate regardless" {
	_stub_gh '{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":false,
	 "labels":[{"name":"needs-operator"}],
	 "statusCheckRollup":[
	   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"Review completed"},
	   {"name":"verify","conclusion":"SUCCESS","description":"ok"}]}'
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*needs-operator*) ;;
	*)
		echo "expected the label to be named; got: $output"
		return 1
		;;
	esac
}

@test "MERGE_GATE_AUTO=0 disables auto-merge globally" {
	_stub_gh "$(_ok_view)"
	MERGE_GATE_AUTO=0
	export MERGE_GATE_AUTO
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*MERGE_GATE_AUTO*) ;;
	*)
		echo "expected the toggle to be named; got: $output"
		return 1
		;;
	esac
}

@test "a draft PR is never auto-merged" {
	_stub_gh '{"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","isDraft":true,"labels":[],
	 "statusCheckRollup":[
	   {"name":"CodeRabbit","conclusion":"SUCCESS","description":"Review completed"},
	   {"name":"verify","conclusion":"SUCCESS","description":"ok"}]}'
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*draft*) ;;
	*)
		echo "expected the draft state to be named; got: $output"
		return 1
		;;
	esac
}

@test "an unreadable required-checks SSOT is rc 2, not an empty green list" {
	# An SSOT that lists nothing must not read as "no checks required,
	# therefore all green" — that is the emptiest possible fail-open.
	_stub_gh "$(_ok_view)"
	run env PATH="$TEST_TMP/bin:$PATH" VIEW_FILE="$TEST_TMP/view.json" \
		MERGE_AUTO_CHECKS_SSOT="$TEST_TMP/does-not-exist.yml" \
		MERGE_AUTO_THREAD_HELPER="$MERGE_AUTO_THREAD_HELPER" \
		bash -c ". '$LIB'; merge_auto_ok 42"
	[ "$status" -eq 2 ]
}

@test "an EMPTY required-checks list is rc 2, not green" {
	_stub_gh "$(_ok_view)"
	printf 'required: []\n' >"$TEST_TMP/empty.yml"
	run env PATH="$TEST_TMP/bin:$PATH" VIEW_FILE="$TEST_TMP/view.json" \
		MERGE_AUTO_CHECKS_SSOT="$TEST_TMP/empty.yml" \
		MERGE_AUTO_THREAD_HELPER="$MERGE_AUTO_THREAD_HELPER" \
		bash -c ". '$LIB'; merge_auto_ok 42"
	[ "$status" -eq 2 ]
	case "$output" in
	*"refusing to call that green"*) ;;
	*)
		echo "expected an explicit refusal; got: $output"
		return 1
		;;
	esac
}
