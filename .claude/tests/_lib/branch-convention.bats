#!/usr/bin/env bats
# covers: _lib/branch-convention.sh
#
# #2416 branch-name convention SSOT. ONE canonical definition consumed by every
# enforcer (creation gate, PR-time verify, pre-push) so the rule cannot drift.
# These tests lock the pure string contract:
#   - canonical <type>/vX.Y.Z/<issue>-<slug> for ALL 10 conventional types → rc 0;
#   - the exact case that bit #2289 (`chore/labels/2289-x`) → rc 2 (malformed);
#   - the OLD divergent dash form (`feat/v0.34-W/...`) → rc 2 (converged out);
#   - scratch names (no <type>/ prefix) → rc 1 (allowed, no issue check);
#   - issue extraction: canonical path-segment + `#NNN` fallback;
#   - re/expected accessors emit the single source.
#
# Each test sources the lib fresh inside a `bash -c` subshell so the lib's
# `set -u` is contained and the real `#!/bin/bash` interpreter is exercised
# (not the test runner's zsh, where [[ =~ ]] populates $match not $BASH_REMATCH).

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/branch-convention.sh"
	[ -f "$LIB" ]
	TEST_TMP=$(mktemp -d -t bcv.XXXXXX) || return 1
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */bcv.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# --- branch_convention_validate: valid canonical (rc 0) ---

@test "validate: canonical feat branch → rc 0" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "feat/v0.34.73/2416-branch-convention-ssot"
	[ "$status" -eq 0 ]
}

@test "validate: chore with dotted version → rc 0" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "chore/v0.34.72/2289-area-infra-normalize"
	[ "$status" -eq 0 ]
}

@test "validate: version with -suffix (vX.Y.Z-W4) → rc 0" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "feat/v4.28.0-W4/708-foo-bar"
	[ "$status" -eq 0 ]
}

@test "validate: minimal slug + single-digit version → rc 0" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "fix/v0.0.1/1-a"
	[ "$status" -eq 0 ]
}

@test "validate: all 10 conventional types accepted" {
	for t in feat fix chore docs refactor perf test build ci revert; do
		run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "$t/v1.2.3/5-x"
		[ "$status" -eq 0 ] || {
			echo "type '$t' should be valid but status=$status"
			return 1
		}
	done
}

# --- branch_convention_validate: malformed work branch (rc 2 → block) ---

@test "validate: REGRESSION #2289 — chore/labels/2289-x → rc 2 (malformed, blocked)" {
	# 'labels' sits where vX.Y.Z must be. This is the exact branch that slipped
	# past the feat-only creation gate and only failed at PR time. Must block.
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "chore/labels/2289-area-infra-normalize"
	[ "$status" -eq 2 ]
}

@test "validate: OLD dash version form (vX.Y-Z) → rc 2 (converged out)" {
	# The pre-#2416 issue-before-code form was feat/vX.Y-Z/NNN (dash, feat-only).
	# The SSOT converged to dotted vX.Y.Z — the dash form is now malformed.
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "feat/v0.34-W/708-x"
	[ "$status" -eq 2 ]
}

@test "validate: type prefix but no version/issue → rc 2" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "feat/incomplete"
	[ "$status" -eq 2 ]
}

@test "validate: uppercase slug → rc 2 (slug must be lowercase-kebab)" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "feat/v1.2.3/5-Foo"
	[ "$status" -eq 2 ]
}

@test "validate: missing issue number segment → rc 2" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "feat/v1.2.3/no-issue-num"
	[ "$status" -eq 2 ]
}

# --- branch_convention_validate: scratch (rc 1 → allow, no issue check) ---

@test "validate: bare scratch name → rc 1" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "wip"
	[ "$status" -eq 1 ]
}

@test "validate: slashed scratch with non-type prefix → rc 1" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "myname/scratch-thing"
	[ "$status" -eq 1 ]
}

@test "validate: 'main' → rc 1 (scratch, not a work branch)" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" "main"
	[ "$status" -eq 1 ]
}

@test "validate: empty string → rc 1" {
	run bash -c '. "$1"; branch_convention_validate "$2"' _ "$LIB" ""
	[ "$status" -eq 1 ]
}

# --- branch_convention_extract_issue ---

@test "extract: canonical branch → path-segment issue number" {
	run bash -c '. "$1"; branch_convention_extract_issue "$2"' _ "$LIB" "feat/v0.34.73/2416-branch-convention-ssot"
	[ "$status" -eq 0 ]
	[ "$output" = "2416" ]
}

@test "extract: version-suffix branch → issue after version" {
	run bash -c '. "$1"; branch_convention_extract_issue "$2"' _ "$LIB" "feat/v4.28.0-W4/708-foo-bar"
	[ "$output" = "708" ]
}

@test "extract: non-canonical with #NNN → fallback issue number" {
	run bash -c '. "$1"; branch_convention_extract_issue "$2"' _ "$LIB" "hotfix-for-#1234-thing"
	[ "$output" = "1234" ]
}

@test "extract: scratch name with no issue → empty" {
	run bash -c '. "$1"; branch_convention_extract_issue "$2"' _ "$LIB" "myname/scratch-thing"
	[ -z "$output" ]
}

@test "extract: malformed work branch with no number → empty" {
	run bash -c '. "$1"; branch_convention_extract_issue "$2"' _ "$LIB" "feat/incomplete"
	[ -z "$output" ]
}

# --- accessors: the single source is emittable ---

@test "branch_convention_re: emits one regex with all types + dotted version" {
	run bash -c '. "$1"; branch_convention_re' _ "$LIB"
	[ "$status" -eq 0 ]
	[[ $output == *'feat|fix|chore'* ]]
	[[ $output == *'revert'* ]]
	[[ $output == *'v[0-9]+\.[0-9]+\.[0-9]+'* ]]
}

@test "branch_convention_expected: emits human-readable form" {
	run bash -c '. "$1"; branch_convention_expected' _ "$LIB"
	[ "$status" -eq 0 ]
	[[ $output == *'<type>/vX.Y.Z/<issue-num>-<slug>'* ]]
}
