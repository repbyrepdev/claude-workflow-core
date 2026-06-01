#!/usr/bin/env bats
# covers: _lib/cr-phase2-coverage.sh
#
# #238: cr_phase2_clean_for_sha is the SSOT "is this sha's Phase 2 review clean
# OR fully addressed?" check, shared by the pre-push-gate AND ship-pr-cycle's
# round-cap. These unit-tests lock its contract: findings=0 → clean; findings>0
# → clean iff source=cr prove-yourself records scoped to the sha cover them
# (sum covers_count >= findings, default 1); and FAIL-CLOSED on missing
# log / missing audit / non-numeric findings (never whitewash).

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/cr-phase2-coverage.sh"
	[ -f "$LIB" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t crp2cov.XXXXXX) || return 1
	export REPO_ROOT="$TEST_TMP"
	mkdir -p "$TEST_TMP/.claude/logs" "$TEST_TMP/.claude/audit"
	CR_LOG="$TEST_TMP/.claude/logs/cr-local-review.jsonl"
	AUDIT="$TEST_TMP/.claude/audit/prove-yourself.jsonl"
	SHA="abc1234def5678901234567890123456789012ab" # short = abc1234
	# shellcheck source=../../../_lib/cr-phase2-coverage.sh
	. "$LIB"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */crp2cov.* ]] && rm -rf "$TEST_TMP"
	return 0
}

_log() { printf '{"sha":"abc1234","findings":%s}\n' "$1" >>"$CR_LOG"; }
_cover() { printf '{"source":"cr","covered_sha":"%s","covers_count":%s}\n' "$SHA" "$1" >>"$AUDIT"; }

@test "findings=0 → clean (rc 0)" {
	_log 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
}

@test "findings>0 fully covered (covers_count >= findings) → clean" {
	_log 2
	_cover 2
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
}

@test "findings>0 under-covered (covers_count < findings) → NOT clean" {
	_log 2
	_cover 1
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
}

@test "findings>0 with NO prove-yourself audit log → NOT clean (fail-closed)" {
	_log 2
	# no $AUDIT file written
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
}

@test "covers_count defaults to 1 when absent (pre-#238 records still count 1)" {
	_log 1
	printf '{"source":"cr","covered_sha":"%s"}\n' "$SHA" >>"$AUDIT" # no covers_count
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
}

@test "latest entry wins (oscillation): last findings>covered → NOT clean" {
	_log 0 # earlier clean run
	_log 4 # latest run has 4
	_cover 2
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
}

@test "coverage scoped by sha: a record for a DIFFERENT sha does not count" {
	_log 2
	printf '{"source":"cr","covered_sha":"deadbeefdeadbeef","covers_count":5}\n' >>"$AUDIT"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
}

@test "no cr-local-review.jsonl at all → NOT clean (fail-closed)" {
	rm -f "$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
}

@test "non-numeric latest findings → NOT clean (fail-closed, no whitewash)" {
	printf '{"sha":"abc1234","findings":"oops"}\n' >>"$CR_LOG"
	_cover 9
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
}
