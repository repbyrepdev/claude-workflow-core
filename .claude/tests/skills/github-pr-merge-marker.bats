#!/usr/bin/env bats
# covers: skills/github-pr-merge/run.sh
#
# Tests for v0.27.0 #173 Layer 2: github-pr-merge skill clears the
# phase1-directive marker for the merged PR's head ref after a
# successful merge.

setup() {
	WRAPPER="${BATS_TEST_DIRNAME}/../../../skills/github-pr-merge/run.sh"
	[ -f "$WRAPPER" ]
}

@test "Layer 2 marker rm: tests deferred to mock-gh test suite" {
	# The wrapper invokes gh (PR fetch, merge, etc.) which requires
	# network + auth to test end-to-end. Mocking gh comprehensively
	# is a larger investment; the v0.27.x manual dogfood verified
	# the Layer 2 marker rm works on real merges.
	# Track as v0.30.x followup if regression appears in production.
	skip "#176 deferred — gh-mock integration v0.30.x followup"
}

@test "BRANCH_HEAD_SHA via gh headRefOid resolution syntax is in run.sh" {
	# Sanity check that the v0.27.1 Phase 1 r1 fix (gh pr view --jq headRefOid)
	# is present in the wrapper — guards against accidental revert.
	grep -q 'gh pr view "\$PR" --json headRefOid' "$WRAPPER"
}
