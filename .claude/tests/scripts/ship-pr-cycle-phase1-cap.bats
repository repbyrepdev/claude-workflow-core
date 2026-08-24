#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# #2575 (+#2570 exit contract): the phase-1 round-cap, mechanically enforced.
# Before this, the cap was a printed suggestion — the #2547 cycle armed NINE
# 6-agent rounds against a cap of 3 (millions of tokens) and nothing refused.
# Mirrors the #2545 phase-2 pattern: a branch-wide round counter
# (_phase1_branch_round_count — per-BRANCH: fix-commit HEADs must not reset
# it) and one at-cap decision (_phase1_cap_gate): GRADUATE only on positive
# coverage evidence (phase1_round_coverage_summary: covers >= findings on the
# newest branch sha with rows), else refuse rc 2 + hook-ack; deliberate
# overrun only via the audited PIPELINE_GATE_SKIP escape.
#
# Same harness family as ship-pr-cycle-phase2-cap.bats: tmp git repo (main +
# branch), state seeded to phase1, consumer-first stubs for the scaler and
# graduation lib; the round counter reads seeded .claude/review-log/<sha>.jsonl
# files; coverage reads seeded .claude/audit/prove-yourself.jsonl through the
# REAL _lib/phase1-round-coverage.sh.
# shellcheck disable=SC2030,SC2031

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-p1cap.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		git branch -M main
		git checkout -q -b feat-2575-cap
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work1
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work2
		mkdir -p .claude/hooks .claude/_lib .claude/review-log .claude/audit
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
	ROOT=$(cd "$TEST_TMP" && git rev-parse --show-toplevel)
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	SHA_PREV=$(cd "$TEST_TMP" && git rev-parse HEAD~1)
	STATE_DIR="$ROOT/.claude/.session-state/ship-cycle"
	mkdir -p "$STATE_DIR"

	# Scaler stub → deterministic cap (STUB_ROUNDS, default 3).
	cat >"$ROOT/.claude/hooks/phase1-scaler.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ROUNDS=%s\n' "${STUB_ROUNDS:-3}"
exit 0
STUB
	chmod +x "$ROOT/.claude/hooks/phase1-scaler.sh"
	# Graduation stub: NOT graduated (rc 1) so the cap path is reachable.
	cat >"$ROOT/.claude/_lib/phase-graduation.sh" <<'STUB'
graduation_check() { return 1; }
STUB
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-p1cap.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_seed_stage_phase1() {
	printf '{"version":1,"stage":"phase1","branch":"feat-2575-cap","sha":"%s","history":[]}\n' \
		"$SHA" >"$STATE_DIR/$SHA.json"
}

_cur_stage() {
	jq -r '.stage' "$STATE_DIR/$SHA.json"
}

# Seed N phase-1 rounds onto a given FULL sha's review log. Latest round
# carries findings>0 so clean_streak stays 0 (the cap path, not convergence).
_seed_rounds() { # $1 = full sha, $2 = round count, $3 = findings on latest round
	local sha="$1" n="$2" f="${3:-4}" i
	: >"$ROOT/.claude/review-log/$sha.jsonl"
	for ((i = 1; i <= n; i++)); do
		local rf=0
		[ "$i" -eq "$n" ] && rf="$f"
		printf '{"sha":"%s","phase":1,"round":%s,"agent":"code-reviewer","findings":%s,"status":"ok"}\n' \
			"$sha" "$i" "$rf" >>"$ROOT/.claude/review-log/$sha.jsonl"
	done
}

_seed_coverage() { # $1 = full sha, $2 = covers_count
	printf '{"source":"phase1","covered_sha":"%s","covers_count":%s}\n' "$1" "$2" \
		>>"$ROOT/.claude/audit/prove-yourself.jsonl"
}

@test "at cap with FULL coverage: graduates to phase2, no new round armed" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 3 4
	_seed_coverage "$SHA" 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"GRADUATED to phase2"* ]]
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
	[ "$(_cur_stage)" = "phase2" ]
}

@test "at cap with PARTIAL coverage: refuses rc 2, ENFORCED, stage stays phase1" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 3 4
	_seed_coverage "$SHA" 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"phase1 round-cap ENFORCED (3/3)"* ]]
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
	[ "$(_cur_stage)" = "phase1" ]
}

@test "under cap: the operator directive is emitted, stage stays phase1" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	[[ $output != *"round-cap ENFORCED"* ]]
	[ "$(_cur_stage)" = "phase1" ]
}

@test "cap is the scaler's value, not a constant (5-round tier, 3 rounds spent → directive)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=5
	run bash "$SCRIPT" next
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	[[ $output != *"round-cap ENFORCED"* ]]
}

@test "the counter is per-BRANCH: rounds on a prior fix-commit HEAD still count (#2547 property)" {
	_seed_stage_phase1
	# 2 rounds on the previous branch commit + 1 on HEAD = 3 total = cap.
	_seed_rounds "$SHA_PREV" 2 4
	_seed_rounds "$SHA" 1 4
	_seed_coverage "$SHA" 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"phase1 round-cap ENFORCED (3/3)"* ]]
}

@test "PIPELINE_GATE_SKIP=1 at cap: audit row written, one more round armed" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3 SKIP_LOG="$ROOT/.claude/logs/pipeline-skip.jsonl"
	mkdir -p "$ROOT/.claude/logs"
	PIPELINE_GATE_SKIP=1 PIPELINE_GATE_SKIP_REASON="bats override fixture" run bash "$SCRIPT" next
	[[ $output == *"OVERRIDDEN via PIPELINE_GATE_SKIP=1"* ]]
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	grep -q "phase1-round-cap" "$SKIP_LOG"
}

@test "PIPELINE_GATE_SKIP=1 with unwritable audit refuses (fail-closed override)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3 SKIP_LOG="$ROOT/.claude" # a directory — append fails
	PIPELINE_GATE_SKIP=1 run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"audit append FAILED"* ]]
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
}

@test "corrupt review log fails CLOSED (rc 2), never a vacuous count" {
	_seed_stage_phase1
	printf 'not json at all\n' >"$ROOT/.claude/review-log/$SHA.jsonl"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"cannot count rounds"* ]] || [[ $output == *"jq failed reading"* ]]
}
