#!/usr/bin/env bats
# covers: hooks/pr-lint-check.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	# Prefer the canonical `hooks/pr-lint-check.sh` path; fall back to the
	# `.claude/hooks/` symlink alias for backward compat with older
	# consumer-repo layouts where the symlink isn't present.
	if [ -f "${REPO_ROOT}/hooks/pr-lint-check.sh" ]; then
		SCRIPT="${REPO_ROOT}/hooks/pr-lint-check.sh"
	else
		SCRIPT="${REPO_ROOT}/.claude/hooks/pr-lint-check.sh"
	fi
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

@test "embedded-word keyword + #N FAILS (boundary anchor, #200 folded into #199)" {
	# discloses/fooadvances/unresolved are NOT standalone keywords — the
	# leading (^|[^[:alnum:]_]) boundary must reject them even with a real #N.
	for kw in "discloses #1" "fooadvances #7" "unresolved #7" "prefixes #3" "precloses #2"; do
		cat >"$TEST_TMP/body.md" <<BODY
## Summary

x

## Test plan

- [x] y

$kw
BODY
		run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
		[ "$status" -eq 1 ] || {
			echo "expected rc=1 (embedded word, not standalone) for: $kw (got $status)" >&2
			false
		}
	done
}

@test "standalone keyword mid-body still PASSES with boundary anchor" {
	# A keyword preceded by whitespace/newline (the normal case) must still
	# match after adding the leading boundary. ONLY one reference (Advances
	# #7) so the assertion isolates the boundary behavior — a second valid
	# ref would let the test pass even if Advances stopped matching (CR #201).
	cat >"$TEST_TMP/body.md" <<'BODY'
## Summary

Some text without a closing keyword.

## Test plan

- [x] y

Advances #7
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
	[ "$status" -eq 0 ]
}

@test "non-closing keyword + #N still FAILS (regex not too broad, #199)" {
	# Guards that adding `advance[sd]?` didn't broaden the alternation to
	# accept arbitrary verbs. A real issue-number token is present, but the
	# keyword isn't an accepted one → must still rc=1.
	for kw in "Mentions #7" "See #7" "Refs #7" "Related to #7"; do
		cat >"$TEST_TMP/body.md" <<BODY
## Summary

x

## Test plan

- [x] y

$kw
BODY
		run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
		[ "$status" -eq 1 ] || {
			echo "expected rc=1 (no valid ref) for keyword: $kw (got $status)" >&2
			false
		}
	done
}

@test "Advances #N satisfies issue-reference check (v0.30.I #199)" {
	# Partial-progress PRs reference their parent without closing it. GitHub
	# does not auto-close on Advances, so this is lint-acceptance only.
	for kw in "Advances #7" "advances #7" "Advance #7" "Advanced #7"; do
		cat >"$TEST_TMP/body.md" <<BODY
## Summary

One slice of a multi-slice issue.

## Test plan

- [x] Tests pass

$kw
BODY
		run "$SCRIPT" --body "$TEST_TMP/body.md" --labels '["area:infrastructure"]'
		[ "$status" -eq 0 ] || {
			echo "expected rc=0 for keyword: $kw (got $status)" >&2
			false
		}
	done
}

@test "PR template ships the linter's required headings (#204 SSOT lock)" {
	# Regression lock: .github/pull_request_template.md must contain every
	# heading pr-lint-check.sh requires (## Summary + ## Test plan), so a
	# contributor who fills in the template verbatim passes the linter.
	# Guards the #204 drift where the template said '## Testing' while the
	# linter required '## Test plan'. Headings are matched line-anchored, the
	# same way the linter checks them.
	TEMPLATE="${REPO_ROOT}/.github/pull_request_template.md"
	[ -f "$TEMPLATE" ]
	grep -qE '^## Summary$' "$TEMPLATE"
	grep -qE '^## Test plan$' "$TEMPLATE"
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
