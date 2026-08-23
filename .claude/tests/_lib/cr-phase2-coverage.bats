#!/usr/bin/env bats
# covers: _lib/cr-phase2-coverage.sh
#
# #238: cr_phase2_clean_for_sha is the SSOT "is this sha's Phase 2 review clean
# OR fully addressed?" check, shared by the pre-push-gate AND ship-pr-cycle's
# round-cap. These unit-tests lock its contract: findings=0 → clean; findings>0
# → clean iff source=cr prove-yourself records scoped to the sha cover them
# (sum covers_count >= findings, default 1); and FAIL-CLOSED on missing
# log / missing audit / non-numeric findings (never whitewash).
#
# Each test also asserts `[ -z "$output" ]`: the function is documented SILENT
# (callers emit their own messages — see the lib header), so any stray
# stdout/stderr is a contract regression. `run` merges both streams into
# $output, so this single assertion covers stdout AND stderr — bats has no
# $error var, so do NOT assert on one. [#238 phase2 r1, CR major]

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
# A run that was KILLED before completing. local-review.sh writes exactly this
# shape on the exit-4 timeout path: findings is what was SEEN, not what EXISTS.
_log_partial() {
	printf '{"sha":"abc1234","findings":%s,"timeout":true,"partial":true}\n' "$1" >>"$CR_LOG"
}

@test "findings=0 → clean (rc 0)" {
	_log 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2552 partial/timeout run with findings=0 is NOT clean (laundering guard)" {
	# THE BUG: a review killed before emitting anything logs findings:0 —
	# "0 findings were SEEN", not "0 findings EXIST". Reading only .findings
	# made that CLEAN, so the pre-push gate accepted a SHA whose local review
	# never ran. Observed live on PR #2540's f21b3d1.
	_log_partial 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "a timed-out review with 0 findings was accepted as CLEAN"
		return 1
	}
}

@test "#2552 partial/timeout run is NOT clean even with findings>0 and full coverage" {
	# A partial run cannot certify the SHA on its own: the findings it salvaged
	# are the ones it happened to see before dying, so covering them proves
	# nothing about the rest. Only a COMPLETE run can be coverage-cleared.
	_log_partial 2
	_cover 2
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "a timed-out review was coverage-cleared as CLEAN"
		return 1
	}
}

@test "#2552 a COMPLETE run after a partial one still clears (partial is not sticky)" {
	# The guard keys on the LATEST entry only. A partial run followed by a real
	# completed run must clear — otherwise one timeout would poison the SHA
	# forever and strand the branch.
	_log_partial 0
	_log 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ] || {
		echo "a completed run following a partial one was wrongly refused"
		return 1
	}
}

@test "findings>0 fully covered (covers_count >= findings) → clean" {
	_log 2
	_cover 2
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "findings>0 under-covered (covers_count < findings) → NOT clean" {
	_log 2
	_cover 1
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "findings>0 with NO prove-yourself audit log → NOT clean (fail-closed)" {
	_log 2
	# no $AUDIT file written
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "covers_count defaults to 1 when absent (pre-#238 records still count 1)" {
	_log 1
	printf '{"source":"cr","covered_sha":"%s"}\n' "$SHA" >>"$AUDIT" # no covers_count
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "latest entry wins (oscillation): last findings>covered → NOT clean" {
	_log 0 # earlier clean run
	_log 4 # latest run has 4
	_cover 2
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "coverage scoped by sha: a record for a DIFFERENT sha does not count" {
	_log 2
	printf '{"source":"cr","covered_sha":"deadbeefdeadbeef","covers_count":5}\n' >>"$AUDIT"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "no cr-local-review.jsonl at all → NOT clean (fail-closed)" {
	rm -f "$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "non-numeric latest findings → NOT clean (fail-closed, no whitewash)" {
	printf '{"sha":"abc1234","findings":"oops"}\n' >>"$CR_LOG"
	_cover 9
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}
