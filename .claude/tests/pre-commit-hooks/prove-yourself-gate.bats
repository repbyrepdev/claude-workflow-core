#!/usr/bin/env bats
# covers: pre-commit-hooks/prove-yourself-gate.sh
#
# #2291: pre-commit gate enforcing per-finding prove-yourself coverage +
# graduation. It delegates record-shape validation to the skill (check-commit),
# then enforces that the latest Phase 1 round's findings are all covered by
# prove-yourself records before allowing the commit, and writes a graduation
# marker on success. bash-3.2 compatible (no mapfile).
#
# Injection points exercised: PROVE_YOURSELF_GATE_SKIP[_REASON] (bypass),
# PROVE_YOURSELF_SKILL (stub skill / fail-closed path), and the review-log +
# prove-yourself state-file fixtures for the coverage math.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/prove-yourself-gate.sh"
	[ -f "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t prove-yourself-gate.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m seed
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/.claude/review-log" \
		"$TEST_TMP/.claude/.session-state/prove-yourself" \
		"$TEST_TMP/.claude/logs"
	# Stub skill: `check-commit` exits ${STUB_RC:-0}. Wired via the
	# PROVE_YOURSELF_SKILL override so tests never touch the real skill.
	STUB="$TEST_TMP/stub-skill.sh"
	cat >"$STUB" <<'EOF'
#!/bin/bash
[ "${1:-}" = "check-commit" ] && exit "${STUB_RC:-0}"
exit 0
EOF
	chmod +x "$STUB"
	HEAD_SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Write a Phase 1 round-1 review-log entry with <findings> findings.
_seed_round() {
	printf '{"phase":1,"round":1,"agent":"code-reviewer","findings":%s,"ts":"2020-01-01T00:00:00Z","status":"ok"}\n' \
		"$1" >"$TEST_TMP/.claude/review-log/${HEAD_SHA}.jsonl"
}

# _seed_cover <covers_count> [source=phase1] [ts=2020-01-02T00:00:00Z]
# Default ts is AFTER the round start; default source is phase1.
_seed_cover() {
	_COVER_N=$((${_COVER_N:-0} + 1))
	printf '{"source":"%s","covers_count":%s,"ts":"%s"}\n' \
		"${2:-phase1}" "$1" "${3:-2020-01-02T00:00:00Z}" \
		>"$TEST_TMP/.claude/.session-state/prove-yourself/cover-${_COVER_N}.json"
}

_run_gate() {
	run bash -c "cd '$TEST_TMP' && PROVE_YOURSELF_SKILL='$STUB' '$SCRIPT'"
}

@test "no review log → passes (exit 0)" {
	_run_gate
	[ "$status" -eq 0 ]
}

@test "PROVE_YOURSELF_GATE_SKIP=1 with reason → passes + audit-logged" {
	run bash -c "cd '$TEST_TMP' && PROVE_YOURSELF_GATE_SKIP=1 PROVE_YOURSELF_GATE_SKIP_REASON='ci hotfix' PROVE_YOURSELF_SKILL='$STUB' '$SCRIPT'"
	[ "$status" -eq 0 ]
	[ -f "$TEST_TMP/.claude/logs/prove-yourself-gate-skip.jsonl" ]
	# Key assertion last: the reason reached the audit log.
	grep -q 'ci hotfix' "$TEST_TMP/.claude/logs/prove-yourself-gate-skip.jsonl"
}

@test "PROVE_YOURSELF_GATE_SKIP=1 without reason → still passes, logs no-reason" {
	# Documented behaviour: the bypass exits 0 regardless of reason. The #2275
	# plan's 'deny without reason' is NOT what the hook does (dogfooded).
	run bash -c "cd '$TEST_TMP' && PROVE_YOURSELF_GATE_SKIP=1 PROVE_YOURSELF_SKILL='$STUB' '$SCRIPT'"
	[ "$status" -eq 0 ]
	grep -q 'no-reason' "$TEST_TMP/.claude/logs/prove-yourself-gate-skip.jsonl"
}

@test "skill not found / not executable → fail-closed (exit 1)" {
	run bash -c "cd '$TEST_TMP' && PROVE_YOURSELF_SKILL='$TEST_TMP/does-not-exist' '$SCRIPT'"
	[ "$status" -eq 1 ]
	[[ $output == *"not found or not executable"* ]]
}

@test "skill check-commit non-zero → forwards the exit code" {
	run bash -c "cd '$TEST_TMP' && STUB_RC=3 PROVE_YOURSELF_SKILL='$STUB' '$SCRIPT'"
	[ "$status" -eq 3 ]
}

@test "round findings fully covered → passes + graduation marker written" {
	_seed_round 2
	_seed_cover 1
	_seed_cover 1
	_run_gate
	[ "$status" -eq 0 ]
	# Key assertions last: the marker exists AND records this round (not just any
	# stray .json), proving graduation_mark wrote a well-formed marker.
	marker=$(find "$TEST_TMP/.claude/.session-state/phase-graduation" -name '*.json' 2>/dev/null | head -1)
	[ -n "$marker" ]
	[ "$(jq -r '.phase1_round' "$marker")" = "1" ]
}

@test "round findings under-covered → BLOCKED (exit 1)" {
	_seed_round 2
	_seed_cover 1
	_run_gate
	# Key assertions last: non-zero exit AND the coverage-gap message.
	[ "$status" -eq 1 ]
	[[ $output == *coverage* ]]
}

@test "a non-phase1 source record does NOT count toward coverage (BLOCKED)" {
	# The source filter (records without source==phase1 are excluded) is what
	# stops a --source cr / phase0.5 record from satisfying the Phase 1 gate.
	_seed_round 2
	_seed_cover 2 cr
	_run_gate
	[ "$status" -eq 1 ]
	[[ $output == *coverage* ]]
}

@test "coverage filed before the round start does NOT count (BLOCKED)" {
	# The time-window (ts >= round-start) is what stops prior-PR records from
	# giving every commit a free pass.
	_seed_round 2
	_seed_cover 2 phase1 2019-12-31T00:00:00Z
	_run_gate
	[ "$status" -eq 1 ]
	[[ $output == *coverage* ]]
}

@test "a round with zero findings passes without graduating" {
	_seed_round 0
	_run_gate
	[ "$status" -eq 0 ]
	# Zero findings short-circuits before the graduation step, so no marker is
	# written — distinguishes 'ran the coverage math, nothing to enforce' from
	# 'bailed early because no review log'.
	[ -z "$(find "$TEST_TMP/.claude/.session-state/phase-graduation" -name '*.json' 2>/dev/null)" ]
}
