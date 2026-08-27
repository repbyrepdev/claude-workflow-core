#!/usr/bin/env bats
# covers: _lib/merge-auto-ok.sh
#
# (#2549) The predicate that decides whether a PR is provably green enough to
# ARM auto-merge instead of holding the operator gate. rc 0 here means a merge
# happens with no human, so the interesting question is never "does it say yes
# when everything is green" — it is whether it says yes when a signal is
# MISSING, HOLLOW, or SIMPLY NOT CHECKED.
#
# WHY THE FIXTURES LOOK LIKE THIS. The first version of this suite stubbed
# `gh pr view --json statusCheckRollup` and hand-injected a `description` key
# into the rows. gh never emits that field there — verified against live PR
# #2635, where a CheckRun row carries only {__typename, completedAt,
# conclusion, detailsUrl, name, startedAt, status, workflowName}. So the
# hollow-check the suite "covered" was dead code in production: `desc` was
# always empty, the regex never fired, and the #2540 shape it exists to refuse
# returned rc 0. The tests proved the fixture, not the system.
#
# Descriptions come from `gh pr checks --json name,state,description`, which
# does carry them ("Review completed" for CodeRabbit on that same PR). These
# fixtures stub THAT.
#
# Incidents encoded below:
#   #2540 — CodeRabbit check `pass`, description "Review rate limited", no
#           review actually performed.
#   #2635 — CodeRabbit auto-PAUSED after an influx of commits; check stayed
#           green while the review had stopped.

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$PLUGIN/_lib/merge-auto-ok.sh"
	[ -r "$LIB" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t merge-auto.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/checks.yml" <<-'Y'
		required:
		  - check_name: CodeRabbit
		  - check_name: verify
	Y
	# Stands in for hooks/_pr-cr-findings.sh: rc 0 = clean, rc 1 = findings.
	cat >"$TEST_TMP/bin/findings.sh" <<-'F'
		#!/bin/bash
		echo "TOTAL needing cleanup: ${FINDINGS_N:-0}"
		exit "${FINDINGS_RC:-0}"
	F
	chmod +x "$TEST_TMP/bin/findings.sh"
	export MERGE_AUTO_CHECKS_SSOT="$TEST_TMP/checks.yml"
	export MERGE_AUTO_FINDINGS_HELPER="$TEST_TMP/bin/findings.sh"
}

teardown() {
	case "${TEST_TMP:-}" in
	*/merge-auto.*) rm -rf "$TEST_TMP" ;;
	esac
	unset MERGE_AUTO_CHECKS_SSOT MERGE_AUTO_FINDINGS_HELPER FINDINGS_RC FINDINGS_N MERGE_GATE_AUTO
}

# $1 = `gh pr view` JSON, $2 = `gh pr checks` JSON.
_stub_gh() {
	printf '%s' "$1" >"$TEST_TMP/view.json"
	printf '%s' "$2" >"$TEST_TMP/checks.json"
	cat >"$TEST_TMP/bin/gh" <<-'G'
		#!/bin/bash
		case "$*" in
		*"pr checks"*) cat "$CHECKS_FILE" ;;
		*) cat "$VIEW_FILE" ;;
		esac
	G
	chmod +x "$TEST_TMP/bin/gh"
}

_ok_view() {
	printf '%s' '{"mergeStateStatus":"CLEAN","isDraft":false,"labels":[]}'
}
_ok_checks() {
	printf '%s' '[{"name":"CodeRabbit","state":"SUCCESS","description":"Review completed"},
	              {"name":"verify","state":"SUCCESS","description":""}]'
}

_call() {
	run env PATH="$TEST_TMP/bin:$PATH" \
		VIEW_FILE="$TEST_TMP/view.json" CHECKS_FILE="$TEST_TMP/checks.json" \
		MERGE_AUTO_CHECKS_SSOT="$MERGE_AUTO_CHECKS_SSOT" \
		MERGE_AUTO_FINDINGS_HELPER="$MERGE_AUTO_FINDINGS_HELPER" \
		FINDINGS_RC="${FINDINGS_RC:-0}" FINDINGS_N="${FINDINGS_N:-0}" \
		MERGE_GATE_AUTO="${MERGE_GATE_AUTO:-1}" \
		bash -c ". '$LIB'; merge_auto_ok 42"
}

@test "auto-merge is OPT-IN — unset MERGE_GATE_AUTO holds the gate" {
	# #2549 specified default-on. Phase-1 review then found four independent
	# ways this returned rc 0 on a PR that should have held, and they compose.
	# A predicate that merges without a human earns default-on by being
	# trusted; it has not been yet.
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	unset MERGE_GATE_AUTO
	run env PATH="$TEST_TMP/bin:$PATH" \
		VIEW_FILE="$TEST_TMP/view.json" CHECKS_FILE="$TEST_TMP/checks.json" \
		MERGE_AUTO_CHECKS_SSOT="$MERGE_AUTO_CHECKS_SSOT" \
		MERGE_AUTO_FINDINGS_HELPER="$MERGE_AUTO_FINDINGS_HELPER" \
		bash -c ". '$LIB'; merge_auto_ok 42"
	[ "$status" -eq 1 ]
	case "$output" in
	*opt-in*) ;;
	*)
		echo "expected the opt-in refusal; got: $output"
		return 1
		;;
	esac
}

@test "arms when every signal is green and it is enabled" {
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	_call
	[ "$status" -eq 0 ] || {
		echo "expected rc 0; got $status: $output"
		return 1
	}
	case "$output" in
	*4-source*) ;;
	*)
		echo "the reason should name the 4-source check; got: $output"
		return 1
		;;
	esac
}

@test "#2540: a check that passed WITHOUT running is rc 2, read from the REAL field" {
	# The description now comes from `gh pr checks`, which actually carries
	# it. Reading it from statusCheckRollup made this branch unreachable.
	_stub_gh "$(_ok_view)" '[{"name":"CodeRabbit","state":"SUCCESS","description":"Review rate limited"},
	                         {"name":"verify","state":"SUCCESS","description":""}]'
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

@test "#2635: an auto-PAUSED review is rc 2" {
	_stub_gh "$(_ok_view)" '[{"name":"CodeRabbit","state":"SUCCESS","description":"review paused"},
	                         {"name":"verify","state":"SUCCESS","description":""}]'
	_call
	[ "$status" -eq 2 ]
}

@test "a SKIPPED required check is NOT green" {
	# Previously accepted as green while this file's own hollow-regex listed
	# "skipped" as disqualifying — the same word treated both ways. GitHub
	# counts a skipped required check as satisfied for branch protection, so
	# mergeStateStatus stays CLEAN and nothing else catches it.
	_stub_gh "$(_ok_view)" '[{"name":"CodeRabbit","state":"SUCCESS","description":"Review completed"},
	                         {"name":"verify","state":"SKIPPED","description":""}]'
	_call
	[ "$status" -eq 2 ]
	case "$output" in
	*"without running"*) ;;
	*)
		echo "expected SKIPPED to be treated as not-run; got: $output"
		return 1
		;;
	esac
}

@test "a required check ABSENT from the rollup is rc 2, not green" {
	_stub_gh "$(_ok_view)" '[{"name":"verify","state":"SUCCESS","description":""}]'
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

@test "a FAILING required check holds the gate (rc 1, not 2)" {
	_stub_gh "$(_ok_view)" '[{"name":"CodeRabbit","state":"SUCCESS","description":"Review completed"},
	                         {"name":"verify","state":"FAILURE","description":""}]'
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

@test "an in-progress check is rc 2 (unreadable), not rc 1 (failing)" {
	# The rc 1 / rc 2 split is the file's stated thesis: "not green" and "I
	# could not tell" want different operator action.
	_stub_gh "$(_ok_view)" '[{"name":"CodeRabbit","state":"","description":""},
	                         {"name":"verify","state":"SUCCESS","description":""}]'
	_call
	[ "$status" -eq 2 ]
}

@test "CR findings delegate to the FOUR-SOURCE helper, not a thread count" {
	# merge_auto_ok previously counted unresolved threads itself — one of the
	# gate's four sources. A PR with a failed CR walkthrough check or an
	# outside-diff-range finding was "provably green" here while
	# pre-merge-cr-comments-gate.sh would have refused it. And the gate could
	# not catch it afterwards: the auto path merges from a grandchild process
	# where no PreToolUse hook fires.
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	FINDINGS_RC=1
	FINDINGS_N=3
	export FINDINGS_RC FINDINGS_N
	_call
	[ "$status" -eq 1 ]
	case "$output" in
	*"CR findings outstanding"*) ;;
	*)
		echo "expected the findings refusal; got: $output"
		return 1
		;;
	esac
}

@test "a missing findings helper is rc 2 — never assumed clean" {
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	run env PATH="$TEST_TMP/bin:$PATH" \
		VIEW_FILE="$TEST_TMP/view.json" CHECKS_FILE="$TEST_TMP/checks.json" \
		MERGE_AUTO_CHECKS_SSOT="$MERGE_AUTO_CHECKS_SSOT" \
		MERGE_AUTO_FINDINGS_HELPER="$TEST_TMP/nope.sh" \
		MERGE_GATE_AUTO=1 \
		bash -c ". '$LIB'; merge_auto_ok 42"
	[ "$status" -eq 2 ]
}

@test "mergeStateStatus other than CLEAN holds the gate" {
	_stub_gh '{"mergeStateStatus":"BLOCKED","isDraft":false,"labels":[]}' "$(_ok_checks)"
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
	_stub_gh '{"mergeStateStatus":"CLEAN","isDraft":false,"labels":[{"name":"needs-operator"}]}' "$(_ok_checks)"
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

@test "MERGE_GATE_AUTO=0 disables it explicitly" {
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	MERGE_GATE_AUTO=0
	export MERGE_GATE_AUTO
	_call
	[ "$status" -eq 1 ]
}

@test "a draft PR is never auto-merged" {
	_stub_gh '{"mergeStateStatus":"CLEAN","isDraft":true,"labels":[]}' "$(_ok_checks)"
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

@test "an EMPTY required-checks list is rc 2, not 'nothing required, all green'" {
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	printf 'required: []\n' >"$TEST_TMP/empty.yml"
	run env PATH="$TEST_TMP/bin:$PATH" \
		VIEW_FILE="$TEST_TMP/view.json" CHECKS_FILE="$TEST_TMP/checks.json" \
		MERGE_AUTO_CHECKS_SSOT="$TEST_TMP/empty.yml" \
		MERGE_AUTO_FINDINGS_HELPER="$MERGE_AUTO_FINDINGS_HELPER" \
		MERGE_GATE_AUTO=1 \
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

@test "an unreadable required-checks SSOT is rc 2" {
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	run env PATH="$TEST_TMP/bin:$PATH" \
		VIEW_FILE="$TEST_TMP/view.json" CHECKS_FILE="$TEST_TMP/checks.json" \
		MERGE_AUTO_CHECKS_SSOT="$TEST_TMP/does-not-exist.yml" \
		MERGE_AUTO_FINDINGS_HELPER="$MERGE_AUTO_FINDINGS_HELPER" \
		MERGE_GATE_AUTO=1 \
		bash -c ". '$LIB'; merge_auto_ok 42"
	[ "$status" -eq 2 ]
}

@test "no PR number is rc 2" {
	_stub_gh "$(_ok_view)" "$(_ok_checks)"
	run env PATH="$TEST_TMP/bin:$PATH" MERGE_GATE_AUTO=1 \
		bash -c ". '$LIB'; merge_auto_ok"
	[ "$status" -eq 2 ]
}
