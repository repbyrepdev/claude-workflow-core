#!/usr/bin/env bats
# covers: hooks/_pr-cr-findings.sh
#
# v0.31 #230 (+ r1 hardening): the CR walkthrough Pre-merge-checks parse is the
# merge gate's fail-open surface (PR #302 class). It must: extract the failure
# count from the SUMMARY LINE only (not a decoy elsewhere), match the failure
# glyph as an alternation (❌|❎|⛔|🚫), validate positively (✅ N present), scope
# the ⚠-warning count to the Pre-merge region, and FAIL CLOSED on any
# unparseable / irreconcilable summary. Drives the CR_TEST_MODE harness with a
# CR_TEST_COMMENTS_FILE fixture; sources 1 (threads) + 3 (reviews) are left unset
# (⇒ empty) so only the walkthrough count is under test.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/_pr-cr-findings.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	TMP=$(mktemp -d -t prcrf.XXXXXX) || return 1
	NBSP=$(printf '\xc2\xa0') # U+00A0 for the nbsp-drift fixture
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */prcrf.* ]] && rm -rf "$TMP"
	return 0
}

# $1 = walkthrough body (may be multi-line) → one coderabbit issue-comment.
_comments_fixture() {
	jq -n --arg b "$1" '[{id:1, user:{login:"coderabbitai[bot]"}, body:$b}]' >"$TMP/comments.json"
}

_run_gate() {
	run env CR_TEST_MODE=1 CR_TEST_HEAD=abc123 CR_TEST_OWNER=o CR_TEST_REPO=r \
		CR_TEST_COMMENTS_FILE="$TMP/comments.json" bash "$HOOK" 1
}

@test "drift: ❌ marker present but no extractable count → FAIL CLOSED (#230)" {
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
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌3"
	_run_gate
	[ "$status" -ne 0 ]
}

@test "no ❌ marker at all → treated as 0 (CR omitted it), gate passes (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 5"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "nbsp drift (❌<nbsp>2) still EXTRACTS → blocks, not fail-open (#230 r1)" {
	# The PR's headline drift case; old `❌ [0-9]+` (ASCII space) would miss nbsp.
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌${NBSP}2"
	_run_gate
	[ "$status" -ne 0 ]
}

@test "alternate failure glyph (❎ 2) is recognized → blocks (#230 r1 sfh CRITICAL)" {
	# The extractor + detector match ❌|❎|⛔|🚫; a non-❌ glyph must NOT slip past
	# as 0 (the residual fail-open the first cut left).
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❎ 2"
	_run_gate
	[ "$status" -ne 0 ]
}

@test "decoy ❌ 0 BEFORE the summary line is ignored — count read from summary (#230 r1)" {
	# A bolded/legend "❌ 0" earlier in the body must not be matched; the count
	# comes from the 'Pre-merge checks' summary line (which says ❌ 3).
	_comments_fixture "$(printf 'Legend: ❌ 0 means none\n\n🚥 Pre-merge checks | ✅ 2 | ❌ 3')"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output != *"failing closed"* ]] # blocked on the real count (3), not drift
}

@test "summary line present but no ✅ N → FAIL CLOSED (positive validation) (#230 r1)" {
	_comments_fixture "🚥 Pre-merge checks (results pending)"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output == *"failing closed"* ]]
}

@test "warning-only (❌ 1 == one ⚠ Warning row) → 0 hard failures, passes (#230 r1)" {
	_comments_fixture "$(printf '🚥 Pre-merge checks | ✅ 5 | ❌ 1\n\n| Check | Status |\n| Docs | ⚠️ Warning |')"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "warnings exceed ❌ count → irreconcilable → FAIL CLOSED (#230 r1)" {
	_comments_fixture "$(printf '🚥 Pre-merge checks | ✅ 5 | ❌ 1\n\n| A | ⚠️ Warning |\n| B | ⚠️ Warning |')"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output == *"failing closed"* || $output == *"cannot reconcile"* ]]
}

@test "⚠ Warning in prose BEFORE the summary is NOT subtracted → real failure blocks (#230 r1)" {
	# Warning count is scoped to the Pre-merge region (summary onward); a prose
	# 'Warning' above must not cancel a real failure.
	_comments_fixture "$(printf '⚠️ Warning: this PR is large\n\n🚥 Pre-merge checks | ✅ 3 | ❌ 1')"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output != *"failing closed"* ]] # 1 real failure remains, not drift
}

@test "multiple CR comments → latest (highest id) walkthrough wins (#230 r1)" {
	jq -n '[
		{id:1, user:{login:"coderabbitai[bot]"}, body:"🚥 Pre-merge checks | ✅ 2 | ❌ 3"},
		{id:2, user:{login:"coderabbitai[bot]"}, body:"🚥 Pre-merge checks | ✅ 5 | ❌ 0"}
	]' >"$TMP/comments.json"
	_run_gate
	[ "$status" -eq 0 ] # reads id:2 (clean), not the stale id:1
}
