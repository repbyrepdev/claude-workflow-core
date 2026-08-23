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
# The guard ORs two INDEPENDENT flags. _log_partial sets both, so on its own it
# would leave either branch free to be deleted with the suite still green. These
# two write exactly one flag each so each disjunct is pinned by its own test.
_log_timeout_only() {
	printf '{"sha":"abc1234","findings":%s,"timeout":true}\n' "$1" >>"$CR_LOG"
}
_log_partial_only() {
	printf '{"sha":"abc1234","findings":%s,"partial":true}\n' "$1" >>"$CR_LOG"
}

@test "findings=0 → clean (rc 0)" {
	_log 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 partial/timeout run with findings=0 is NOT clean (laundering guard)" {
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
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 timeout:true ALONE (no partial flag) is NOT clean" {
	# Pins the first disjunct: deleting the .timeout test from the guard must
	# turn this red even though .partial is absent from the entry.
	_log_timeout_only 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "an entry flagged timeout:true (partial absent) was accepted as CLEAN"
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 partial:true ALONE (no timeout flag) is NOT clean" {
	# Pins the second disjunct, symmetrically.
	_log_partial_only 0
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "an entry flagged partial:true (timeout absent) was accepted as CLEAN"
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 a non-boolean truthy partial flag is still NOT clean (fail-closed)" {
	# A strict `== true` would let the string "true" through and silently
	# re-open the laundering hole. We control the only writer today, but the
	# gate must not depend on that staying true.
	printf '{"sha":"abc1234","findings":0,"partial":"true"}\n' >>"$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo 'an entry flagged partial:"true" (string) was accepted as CLEAN'
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 a non-boolean truthy TIMEOUT flag is still NOT clean (fail-closed)" {
	# Symmetric to the partial:"true" case — both disjuncts get the same
	# non-boolean treatment, so neither can regress to strict equality alone.
	printf '{"sha":"abc1234","findings":0,"timeout":"true"}\n' >>"$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo 'an entry flagged timeout:"true" (string) was accepted as CLEAN'
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 a NUMERIC 1 flag is still NOT clean (fail-closed)" {
	# The lib comment names `1` specifically as a value that must not slip
	# past the guard. Pin the claim so the comment cannot go stale.
	printf '{"sha":"abc1234","findings":0,"partial":1}\n' >>"$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "an entry flagged partial:1 (numeric) was accepted as CLEAN"
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 mixed flags (partial:false, timeout:true) is NOT clean" {
	# The flags are independent: one being explicitly false must not vouch
	# for the other. A naive `and` — or reading only the first flag — passes
	# every other test in this file but fails this one.
	printf '{"sha":"abc1234","findings":0,"partial":false,"timeout":true}\n' >>"$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "partial:false alongside timeout:true was accepted as CLEAN"
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 an explicit partial:false is clean (no over-rejection)" {
	# The other side of `!= false`: a completed run that spells the flag out
	# must not be caught by the guard.
	printf '{"sha":"abc1234","findings":0,"partial":false,"timeout":false}\n' >>"$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -eq 0 ] || {
		echo "an explicit partial:false/timeout:false run was wrongly refused"
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 partial/timeout run is NOT clean even with findings>0 and full coverage" {
	# A partial run cannot certify the SHA on its own: the findings it salvaged
	# are the ones it happened to see before dying, so covering them proves
	# nothing about the rest. Only a COMPLETE run can be coverage-cleared.
	# This is the test that pins the mapping as UNCONDITIONAL — it must ignore
	# .findings entirely rather than fall through to the coverage path.
	_log_partial 2
	_cover 2
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "a timed-out review was coverage-cleared as CLEAN"
		return 1
	}
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
}

@test "#2544 a COMPLETE run after a partial one still clears (partial is not sticky)" {
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
	[ -z "$output" ] # silent-contract: no stdout/stderr leak
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

@test "#2544 a CORRUPT ledger fails closed AND explains why (not silently)" {
	# The one documented exception to the silent contract. A malformed ledger
	# is not a verdict — it means the input is broken. Returning the same mute
	# rc 1 as a real finding left the operator unable to tell a refused push
	# caused by CR findings from one caused by a torn log write.
	printf '{"sha":"abc1234","findings":0}\n{"sha":"abc12\n' >>"$CR_LOG"
	run cr_phase2_clean_for_sha "$SHA"
	[ "$status" -ne 0 ] || {
		echo "a corrupt ledger was accepted as CLEAN"
		return 1
	}
	# `run` merges stdout+stderr into $output.
	[[ $output == *"jq failed reading"* ]] || {
		echo "corrupt ledger refused SILENTLY — no diagnostic. output: '$output'"
		return 1
	}
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
