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

@test "PR template passes pr-lint's own heading check (#204 SSOT lock)" {
	# Bidirectional regression lock: feed the ACTUAL template through the
	# ACTUAL linter (not a re-implemented grep), so drift on EITHER side —
	# template loses a required heading, or the linter renames/adds one —
	# fails here. Guards the #204 drift (template said '## Testing' while the
	# linter required '## Test plan'). Invoking the linter also avoids
	# duplicating the heading list + matcher in the test (the prior grep
	# version was stricter than the linter's whitespace-tolerant anchor).
	# The template ships a placeholder 'Closes #<...>', so append a real ref
	# to isolate the heading check; --skip-label-check drops the label
	# requirement (the bare template carries no labels).
	TEMPLATE="${REPO_ROOT}/.github/pull_request_template.md"
	[ -f "$TEMPLATE" ]
	{
		cat "$TEMPLATE"
		echo "Closes #1"
	} >"$TEST_TMP/tmpl-body.md"
	run "$SCRIPT" --body "$TEST_TMP/tmpl-body.md" --skip-label-check
	[ "$status" -eq 0 ] || {
		echo "template fails pr-lint heading check (status=$status): $output" >&2
		false
	}
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

@test "heading as a prose substring (not a standalone line) is rejected (#205 line-anchor)" {
	# The local check is line-anchored (^## Test plan[[:space:]]*$), so a
	# '## Test plan' that appears only as a substring inside prose is NOT a
	# valid heading. A substring matcher (grep -qF) would wrongly accept it.
	# Pins the contract the server pr-lint.yml check now shares (#205 parity).
	cat >"$TEST_TMP/body.md" <<'BODY'
## Summary

Real summary heading present.

This line only mentions ## Test plan inline as prose, not as a heading.

Closes #1
BODY
	run "$SCRIPT" --body "$TEST_TMP/body.md" --skip-label-check
	[ "$status" -eq 1 ]
	[[ $output == *"## Test plan"* ]]
}

@test "neither local hook nor server workflow uses grep -qF for the heading check (#205 parity)" {
	# #205: the server used 'grep -qF \"\$heading\"' (substring) while the local
	# hook used a line-anchored ERE — they accepted different bodies. Lock both
	# to the anchored form so neither side can reintroduce the substring matcher
	# (workflows-source/pr-lint.yml stays in sync via the workflow-source-pin
	# gate, so checking the live workflow suffices).
	WF="${REPO_ROOT}/.github/workflows/pr-lint.yml"
	[ -f "$WF" ]
	# Build the old divergent source line at runtime so no single-quoted '$'
	# token appears here (keeps shellcheck clean) — the literal we forbid is
	# grep -qF "<dollar>heading". Assert neither file still contains it; the
	# line-anchored behavioral test above proves the replacement matcher works.
	local dollar='$'
	local bad="grep -qF \"${dollar}heading\""
	run grep -F "$bad" "$SCRIPT"
	[ "$status" -ne 0 ]
	run grep -F "$bad" "$WF"
	[ "$status" -ne 0 ]
}
