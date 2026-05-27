#!/usr/bin/env bats
# covers: .claude/hooks/pr-lint-check.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/.claude/hooks/pr-lint-check.sh"
	TEST_TMP=$(mktemp -d -t pr-lint-check.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */pr-lint-check.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_good_body() {
	cat >"$TEST_TMP/body.md" <<'BODY'
## Summary

Test PR.

## Test plan

- [x] Tests pass

Closes #1
BODY
}

@test "happy path: good body + valid label → rc=0" {
	_write_good_body
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
	[ "$status" -eq 0 ]
}

@test "body missing Closes/Fixes/Resolves → rc=1 with remediation" {
	cat >"$TEST_TMP/body.md" <<'BODY'
## Summary

No issue link.

## Test plan

- [x] Tests pass
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
	[ "$status" -eq 1 ]
	[[ $output == *"must reference an issue"* ]]
}

@test "body missing ## Summary → rc=1 names the heading" {
	cat >"$TEST_TMP/body.md" <<'BODY'
## Test plan

- [x] Tests pass

Closes #1
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
	[ "$status" -eq 1 ]
	[[ $output == *"## Summary"* ]]
}

@test "body missing ## Test plan → rc=1 names the heading" {
	cat >"$TEST_TMP/body.md" <<'BODY'
## Summary

Test PR.

Closes #1
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
	[ "$status" -eq 1 ]
	[[ $output == *"## Test plan"* ]]
}

@test "labels lacking area:* → rc=1 lists allowed options" {
	_write_good_body
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["enhancement"]'
	[ "$status" -eq 1 ]
	[[ $output == *"area:*"* ]]
	[[ $output == *"area:infrastructure"* ]]
}

@test "--skip-label-check bypasses the area:* check (pre-create mode)" {
	_write_good_body
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '[]' --skip-label-check
	[ "$status" -eq 0 ]
}

@test "multiple violations: all reported in one run (no short-circuit)" {
	cat >"$TEST_TMP/body.md" <<'BODY'
No headings, no issue link.
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '[]'
	[ "$status" -eq 1 ]
	[[ $output == *"must reference an issue"* ]]
	[[ $output == *"## Summary"* ]]
	[[ $output == *"## Test plan"* ]]
	[[ $output == *"area:*"* ]]
}

@test "Fixes #N also satisfies issue-reference check (case-insensitive)" {
	cat >"$TEST_TMP/body.md" <<'BODY'
## Summary

Test PR.

## Test plan

- [x] Tests pass

fixes #42
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
	[ "$status" -eq 0 ]
}

@test "missing --body flag → rc=2 argparse" {
	run "$SCRIPT" --labels '[]'
	[ "$status" -eq 2 ]
	[[ $output == *"--body is required"* ]]
}

@test "non-existent --body file → rc=3 internal" {
	run "$SCRIPT" --body "$TEST_TMP/does-not-exist.md" --labels '[]'
	[ "$status" -eq 3 ]
	[[ $output == *"file not found"* ]]
}

@test "unknown flag → rc=2 argparse" {
	_write_good_body
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '[]' --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}
