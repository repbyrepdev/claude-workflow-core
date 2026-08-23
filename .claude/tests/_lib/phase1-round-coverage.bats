#!/usr/bin/env bats
# covers: _lib/phase1-round-coverage.sh
#
# v0.34.122 (#2535): the phase-1 re-arm gate predicate. rc 0 means "the latest
# round is COMPLETE, has findings, and coverage is short" → ship-pr-cycle
# SUPPRESSES the directive re-arm so Edit is possible. rc 1 means "re-arm
# exactly as before" and is the FAIL-CLOSED answer for every undeterminable
# case — a bug here that flips the default would un-gate phase 1, which is the
# regression this whole gate must not reproduce.

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/phase1-round-coverage.sh"
	[ -f "$LIB" ] || return 1
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t p1cov.XXXXXX) || return 1
	export REPO_ROOT="$TEST_TMP"
	SHA=abc1234def5678901234567890abcdef12345678
	SHORT=abc1234
	RLOG="$TEST_TMP/.claude/review-log/$SHA.jsonl"
	AUDIT="$TEST_TMP/.claude/audit/prove-yourself.jsonl"
	mkdir -p "$TEST_TMP/.claude/review-log" "$TEST_TMP/.claude/audit"
	# shellcheck source=../../../_lib/phase1-round-coverage.sh
	. "$LIB"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */p1cov.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# Seed a round with all 7 expected agents each reporting $2 findings.
_seed_round() {
	local round=$1 per_agent=$2 a
	: >"$RLOG"
	for a in code-reviewer code-simplifier comment-analyzer pr-test-analyzer \
		silent-failure-hunter semgrep security-review; do
		printf '{"ts":"t","sha":"%s","phase":1,"round":%s,"agent":"%s","findings":%s,"status":"ok"}\n' \
			"$SHA" "$round" "$a" "$per_agent" >>"$RLOG"
	done
}

# APPEND, never truncate (#2535 r1 pr-test-analyzer). The original used `>`, so
# the audit log could only ever hold ONE coverage record — which made the
# round-2 scope bug literally unrepresentable in this fixture and is why 16
# tests reported green over it.
_cover() { # $1=source $2=covered_sha $3=covers_count
	printf '{"source":"%s","covered_sha":"%s","covers_count":%s}\n' "$1" "$2" "$3" >>"$AUDIT"
}

# Append one more round of agent rows WITHOUT truncating earlier rounds, so a
# multi-round history on a single sha can be expressed at all.
_add_round() { # $1=round $2=findings_per_agent
	local a
	for a in code-reviewer code-simplifier comment-analyzer pr-test-analyzer \
		silent-failure-hunter semgrep security-review; do
		printf '{"ts":"t","sha":"%s","phase":1,"round":%s,"agent":"%s","findings":%s,"status":"ok"}\n' \
			"$SHA" "$1" "$a" "$2" >>"$RLOG"
	done
}

@test "missing review-log → rc 1 (fail-closed, re-arm as before)" {
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "unresolvable REPO_ROOT → rc 1 (never falls back to pwd)" {
	run env -u REPO_ROOT bash -c ". '$LIB'; cd /; phase1_round_has_unapplied_findings '$SHA' 7"
	[ "$status" -eq 1 ] || return 1
}

@test "non-numeric expected_agents → rc 1 (fail-closed)" {
	_seed_round 1 1
	run phase1_round_has_unapplied_findings "$SHA" "abc"
	[ "$status" -eq 1 ] || return 1
	run phase1_round_has_unapplied_findings "$SHA" 0
	[ "$status" -eq 1 ] || return 1
}

@test "complete round with 0 findings → rc 1 (nothing to apply)" {
	_seed_round 1 0
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "complete round with findings and NO audit log → rc 0 (suppress)" {
	_seed_round 1 1
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1
}

@test "complete round fully covered → rc 1 (re-arm; findings addressed)" {
	_seed_round 1 1
	_cover phase1 "$SHORT" 7
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "complete round PARTIALLY covered → rc 0 (suppress)" {
	_seed_round 1 1
	_cover phase1 "$SHORT" 3
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1
}

@test "coverage from source=cr does NOT satisfy a phase1 round" {
	# The phase2 CR coverage lives in the same audit log; counting it here
	# would let a CR rejection silently clear a phase1 round.
	_seed_round 1 1
	_cover cr "$SHORT" 7
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1
}

@test "coverage scoped to a DIFFERENT sha does not count" {
	_seed_round 1 1
	_cover phase1 9999999 7
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1
}

@test "INCOMPLETE round (subset of agents) → rc 1 (round still in flight)" {
	# The marker is doing its job while agents are still reporting; suppressing
	# here would un-gate the round before it ever completed.
	local a
	: >"$RLOG"
	for a in code-reviewer code-simplifier comment-analyzer; do
		printf '{"ts":"t","sha":"%s","phase":1,"round":1,"agent":"%s","findings":2,"status":"ok"}\n' \
			"$SHA" "$a" >>"$RLOG"
	done
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "phase2 + accept-with-reason rows do not poison round grouping" {
	# Both share the per-sha review-log; phase2 rows have no .round and
	# accept-with-reason rows are phase==1 with neither .round nor .findings.
	_seed_round 2 1
	printf '{"ts":"t","sha":"%s","phase":2,"findings":9,"status":"ok"}\n' "$SHA" >>"$RLOG"
	printf '{"ts":"t","sha":"%s","phase":1,"kind":"accept-with-reason","reason":"x"}\n' "$SHA" >>"$RLOG"
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1
}

@test "an earlier round's UNCOVERED findings still count after a clean round" {
	# This test previously asserted the opposite ("only the LATEST round is
	# evaluated"), which encoded the very bug #2535 r1 found: scoping to the
	# latest round let a clean round 2 mask 35 unapplied findings from round 1
	# and re-arm the marker, denying Edit. Findings do not stop needing action
	# because a later round happened to come back clean — a clean round is not
	# absolution for an earlier dirty one.
	_seed_round 1 5 # round 1: 5 findings x 7 agents = 35, none covered
	_add_round 2 0  # round 2: clean
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1 # SUPPRESS — 35 findings are still outstanding
}

@test "corrupt review-log → rc 1 (fail-closed, never a crash)" {
	printf 'not json {{{\n' >"$RLOG"
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "corrupt audit log → rc 1 (fail-closed)" {
	_seed_round 1 1
	printf 'not json {{{\n' >"$AUDIT"
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "coverage_summary emits '<round> <findings> <covered>'" {
	_seed_round 3 1
	_cover phase1 "$SHORT" 2
	run phase1_round_coverage_summary "$SHA"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "3 7 2" ] || return 1
}

# --- ROUND 2+ (#2535 r1): the case the original fixture could not express ----
# The predicate compared LATEST-round findings against ALL-ROUNDS coverage, so
# coverage earned in round 1 permanently satisfied every later round and the
# gate silently reverted to always-re-arm — the exact deadlock this lib removes.

@test "round 2 with NEW uncovered findings still suppresses (the round-2 bug)" {
	# Round 1: 7 findings, fully covered. Round 2: 7 more, no new coverage.
	# Under the old latest-round-vs-all-rounds comparison this computed
	# total=7 (round 2) vs covered=7 (round 1) → 7 < 7 false → rc 1 → re-arm,
	# denying Edit while 7 findings sat unapplied.
	_seed_round 1 1
	_cover phase1 "$SHORT" 7
	_add_round 2 1
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1 # SUPPRESS — findings outstanding
}

@test "round 2 fully covered cumulatively → re-arm as normal" {
	_seed_round 1 1
	_cover phase1 "$SHORT" 7
	_add_round 2 1
	_cover phase1 "$SHORT" 7 # coverage for round 2 as well (14 total)
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 1 ] || return 1
}

@test "round 3 partial coverage across rounds → suppress" {
	_seed_round 1 1 # 7
	_add_round 2 1  # 14
	_add_round 3 1  # 21 cumulative
	_cover phase1 "$SHORT" 10
	run phase1_round_has_unapplied_findings "$SHA" 7
	[ "$status" -eq 0 ] || return 1
}

@test "coverage_summary reports the CUMULATIVE findings the gate compares" {
	# Must match the predicate's basis, or the operator readout and the gate
	# decision disagree (an earlier version could print "round 2 / 7 / 14").
	_seed_round 1 1
	_add_round 2 1
	_cover phase1 "$SHORT" 3
	run phase1_round_coverage_summary "$SHA"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "2 14 3" ] || return 1
}

@test "coverage_summary reports 'unknown', not 0, when the audit log is corrupt" {
	# "0 covered" is an affirmative claim; an unreadable ledger is an absence of
	# data and must not render as one.
	_seed_round 1 1
	printf 'not json {{{\n' >"$AUDIT"
	run phase1_round_coverage_summary "$SHA"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *unknown* ]] || return 1
}

@test "coverage_summary is silent when there is no review-log" {
	run phase1_round_coverage_summary "$SHA"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
}
