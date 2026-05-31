#!/usr/bin/env bats
# covers: hooks/_pr-cr-findings.sh
#
# v0.31 #230: the CR walkthrough Pre-merge-checks parse must FAIL-CLOSED on
# ❌-count format drift — the lone fail-open in this merge gate (PR #302 class).
# Drives the existing CR_TEST_MODE harness with a CR_TEST_COMMENTS_FILE fixture;
# sources 1 (review threads) + 3 (outside-diff reviews) are left unset (⇒ empty)
# so only the walkthrough Pre-merge count is under test.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/_pr-cr-findings.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	TMP=$(mktemp -d -t prcrf.XXXXXX) || return 1
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */prcrf.* ]] && rm -rf "$TMP"
	return 0
}

# $1 = walkthrough summary body → one coderabbit issue-comment fixture.
_comments_fixture() {
	jq -n --arg b "$1" '[{id:1, user:{login:"coderabbitai[bot]"}, body:$b}]' >"$TMP/comments.json"
}

_run_gate() {
	run env CR_TEST_MODE=1 CR_TEST_HEAD=abc123 CR_TEST_OWNER=o CR_TEST_REPO=r \
		CR_TEST_COMMENTS_FILE="$TMP/comments.json" bash "$HOOK" 1
}

@test "drift: ❌ marker present but no extractable count → FAIL CLOSED (#230)" {
	# A ❌ with no digit within reach (e.g. count moved past 'Failed') must NOT be
	# silently read as 0 — the gate cannot certify clean, so it fails closed.
	_comments_fixture "🚥 Pre-merge checks | ✅ 5 | ❌ Failed checks listed below"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output == *"failing closed"* || $output == *"format drift"* ]]
}

@test "clean: ❌ 0 → zero findings, gate passes (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 5 | ❌ 0"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "failures: ❌ 2 → gate blocks on the COUNT (not drift) (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌ 2"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output != *"failing closed"* ]]
}

@test "no-space drift (❌3) still EXTRACTS → blocks, not fail-open (#230)" {
	# The old `❌ [0-9]+` (required ASCII space) would MISS this and report 0 — a
	# fail-open. The broadened extractor reads 3 and the gate blocks.
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌3"
	_run_gate
	[ "$status" -ne 0 ]
}

@test "no ❌ marker at all → treated as 0 (CR omitted it), gate passes (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 5"
	_run_gate
	[ "$status" -eq 0 ]
}
