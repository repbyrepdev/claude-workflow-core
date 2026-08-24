#!/usr/bin/env bats
# covers: skills/github-pr-merge/run.sh
#
# Tests for v0.27.0 #173 Layer 2: github-pr-merge skill clears the
# phase1-directive marker for the merged PR's head ref after a
# successful merge.

bats_require_minimum_version 1.5.0

setup() {
	WRAPPER="${BATS_TEST_DIRNAME}/../../../skills/github-pr-merge/run.sh"
	[ -f "$WRAPPER" ]
	# A no-op gh on PATH keeps the run hermetic. The arg-validation tests below
	# exit before any gh call, but this guards against a future path slipping a
	# gh invocation in ahead of the arg checks.
	TEST_TMP=$(mktemp -d -t pr-merge-marker.XXXXXX) || return 1
	printf '#!/bin/bash\n' >"$TEST_TMP/gh"
	chmod +x "$TEST_TMP/gh"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */pr-merge-marker.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "Layer 2 marker rm: tests deferred to mock-gh test suite" {
	# The wrapper invokes gh (PR fetch, merge, etc.) which requires
	# network + auth to test end-to-end. Mocking gh comprehensively
	# is a larger investment; the v0.27.x manual dogfood verified
	# the Layer 2 marker rm works on real merges.
	# Track as v0.30.x followup if regression appears in production.
	skip "#176 deferred — gh-mock integration v0.30.x followup"
}

@test "marker cleanup keys on the gh-derived pinned head, never git rev-parse HEAD" {
	# v0.27.1 guarded against `git rev-parse HEAD` (wrong sha when invoked
	# from main/worktree). #2567 strengthened the property: the merge is
	# pinned via --match-head-commit to HEAD_OID (gh headRefOid from the
	# STATE fetch), and the marker rm keys on that same variable — the
	# re-query AND its rev-parse fallback are gone. Guard both halves.
	run grep -E -- '--match-head-commit[[:space:]]+"\$HEAD_OID"' "$WRAPPER"
	[ "$status" -eq 0 ]
	run grep -E 'MARKER_DIR/\$HEAD_OID\.phase1-directive' "$WRAPPER"
	[ "$status" -eq 0 ]
	# Name-independent (CR-in-CI r1): ANY code line resolving `git
	# rev-parse HEAD` is the hazard, whatever variable it lands in.
	# Comment mentions are stripped before the match.
	run ! grep -E '^[^#]*git rev-parse HEAD' "$WRAPPER"
}

# --- #2293 edge-case expansion: behavioral arg-validation (exit 2 before any
# --- gh call — these need no gh-mock, unlike the deferred Layer 2 e2e above). ---

@test "--pr without a value → arg error (exit 2)" {
	run env PATH="$TEST_TMP:$PATH" bash "$WRAPPER" --pr
	[ "$status" -eq 2 ]
	[[ $output == *"requires a value"* ]]
}

@test "missing --pr → usage error (exit 2)" {
	run env PATH="$TEST_TMP:$PATH" bash "$WRAPPER" --squash
	[ "$status" -eq 2 ]
	[[ $output == *Usage* ]]
}

@test "unknown flag → arg error (exit 2)" {
	run env PATH="$TEST_TMP:$PATH" bash "$WRAPPER" --pr 5 --bogus-flag
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}
