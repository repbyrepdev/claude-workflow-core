#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# #2575 (+#2570 exit contract): the phase-1 round-cap, mechanically enforced.
# Before this, the cap was a printed suggestion — the #2547 cycle armed NINE
# 6-agent rounds against a cap of 3 (millions of tokens) and nothing refused.
# Mirrors the #2545 phase-2 pattern: a branch-wide round counter
# (_phase1_branch_round_count — per-BRANCH: fix-commit HEADs must not reset
# it) and one at-cap decision (_phase1_cap_gate): GRADUATE only on positive
# coverage evidence — EVERY findings-bearing branch sha covered, at least
# one such sha — else refuse rc 2 + hook-ack (clearing the directive
# marker); deliberate overrun only via the audited PIPELINE_GATE_SKIP.
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

# Seed phase-1 rounds onto a FULL sha (FAITHFUL row shape, r1 ta#1: three
# agent rows per round — production rounds carry 7 — so a row-count-vs-
# distinct-rounds regression cannot hide; round numbers START at $2 so
# multi-sha branches model the real launcher, which increments across
# the branch). Latest round carries findings>0 unless overridden.
_seed_rounds() { # $1 = full sha, $2 = start round, $3 = round count, $4 = findings on latest round
	local sha="$1" start="$2" n="$3" f="${4:-4}" i a
	: >"$ROOT/.claude/review-log/$sha.jsonl"
	for ((i = start; i < start + n; i++)); do
		local rf=0
		[ "$i" -eq "$((start + n - 1))" ] && rf="$f"
		# Findings land on ONE agent's row (agents report their own counts;
		# the cumulative total sums across rows — putting f on every row
		# would triple it).
		printf '{"sha":"%s","phase":1,"round":%s,"agent":"code-reviewer","findings":%s,"status":"ok"}\n' \
			"$sha" "$i" "$rf" >>"$ROOT/.claude/review-log/$sha.jsonl"
		for a in semgrep security-review; do
			printf '{"sha":"%s","phase":1,"round":%s,"agent":"%s","findings":0,"status":"ok"}\n' \
				"$sha" "$i" "$a" >>"$ROOT/.claude/review-log/$sha.jsonl"
		done
	done
	# Production logs also carry round-less accept-with-reason rows and
	# phase-2 rows — neither may mint phantom rounds (r1 sf-F3/ta#1).
	printf '{"sha":"%s","phase":1,"kind":"accept-with-reason","reason":"fixture"}\n' "$sha" >>"$ROOT/.claude/review-log/$sha.jsonl"
	printf '{"sha":"%s","phase":2,"round":99,"agent":"cr-cli","findings":0,"status":"ok"}\n' "$sha" >>"$ROOT/.claude/review-log/$sha.jsonl"
}

_seed_coverage() { # $1 = full sha, $2 = covers_count
	printf '{"source":"phase1","covered_sha":"%s","covers_count":%s}\n' "$1" "$2" \
		>>"$ROOT/.claude/audit/prove-yourself.jsonl"
}

@test "at cap with FULL coverage: graduates to phase2, no new round armed" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	_seed_coverage "$SHA" 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"GRADUATED to phase2"* ]]
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
	[ "$(_cur_stage)" = "phase2" ]
}

@test "at cap with PARTIAL coverage: refuses rc 2, ENFORCED, hook-ack diag written, stage stays phase1" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	_seed_coverage "$SHA" 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	# Pre-arm a directive marker: the refusal MUST clear it (a marker that
	# survives denies Edit/Write — r1 code-reviewer CRITICAL). Without the
	# pre-arm, the absence assert below is vacuously true.
	touch "$STATE_DIR/$SHA.phase1-directive.txt"
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"phase1 round-cap ENFORCED (3/3)"* ]]
	[[ $output == *"uncovered:"* ]]
	[[ $output == *"PIPELINE_GATE_SKIP=1"* ]]
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
	[ "$(_cur_stage)" = "phase1" ]
	# The refusal is hook-ack routed (cannot scroll past) — the diagnostic
	# file must exist under the SANDBOX repo's session-state.
	ls "$ROOT/.claude/.session-state/hook-ack/ship-pr-cycle-p1cap/"*phase1-round-cap-enforced* >/dev/null
	# r1 code-reviewer CRITICAL: the refusal must CLEAR any armed directive
	# marker — a surviving marker denies the Edit/Write the remedies need.
	[ ! -f "$STATE_DIR/$SHA.phase1-directive.txt" ]
}

@test "under cap: the operator directive is emitted, stage stays phase1" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 1 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	[[ $output != *"round-cap ENFORCED"* ]]
	[ "$(_cur_stage)" = "phase1" ]
}

@test "cap is the scaler's value, not a constant (5-round tier, 3 rounds spent → directive)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=5
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	[[ $output != *"round-cap ENFORCED"* ]]
}

@test "the counter is per-BRANCH: rounds on a prior fix-commit HEAD still count (#2547 property)" {
	_seed_stage_phase1
	# Rounds 1-2 on the previous branch commit + round 3 on HEAD = 3 = cap
	# (real launcher numbering increments across the branch).
	_seed_rounds "$SHA_PREV" 1 2 4
	_seed_rounds "$SHA" 3 1 4
	_seed_coverage "$SHA" 2
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"phase1 round-cap ENFORCED (3/3)"* ]]
}

@test "LAUNDERING GUARD (r1 sf-F2): a fresh 0-finding sha does NOT wash out uncovered older findings" {
	_seed_stage_phase1
	# Rounds 1-3 on PREV carry 4 UNcovered findings; HEAD adds a 0-finding
	# round 4. Pre-fix, HEAD's file was the coverage anchor → 0/0 graduated.
	_seed_rounds "$SHA_PREV" 1 3 4
	_seed_rounds "$SHA" 4 1 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"round-cap ENFORCED"* ]]
	[[ $output == *"uncovered: ${SHA_PREV:0:7}=0/4"* ]]
	[ "$(_cur_stage)" = "phase1" ]
}

@test "VACUOUS-EVIDENCE GUARD (r1 sf-F1): all-zero rounds at the cap refuse — 0/0 is not positive evidence" {
	_seed_stage_phase1
	# Three rounds, every row findings 0, but only 3 of the 7 expected
	# agents logged — partial/errored panels, so the clean-streak door
	# never opened. The covered-at-cap door must not open either.
	_seed_rounds "$SHA" 1 3 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"NO findings-bearing completed round"* ]]
	[ "$(_cur_stage)" = "phase1" ]
}

@test "graduation walks to an OLDER sha: covered findings on PREV, bare HEAD (usual fix-commit shape)" {
	_seed_stage_phase1
	_seed_rounds "$SHA_PREV" 1 3 4
	_seed_coverage "$SHA_PREV" 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"GRADUATED to phase2"* ]]
	[ "$(_cur_stage)" = "phase2" ]
}

@test "UNDETERMINABLE coverage fails CLOSED at the gate (corrupt prove-yourself ledger)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	printf 'not json\n' >"$ROOT/.claude/audit/prove-yourself.jsonl"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"UNDETERMINABLE"* ]]
	[[ $output != *"GRADUATED"* ]]
}

@test "PIPELINE_GATE_SKIP=1 at cap: audit row written, one more round armed, rc 0" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3 SKIP_LOG="$ROOT/.claude/logs/pipeline-skip.jsonl"
	mkdir -p "$ROOT/.claude/logs"
	PIPELINE_GATE_SKIP=1 PIPELINE_GATE_SKIP_REASON="bats override fixture" run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"OVERRIDDEN via PIPELINE_GATE_SKIP=1"* ]]
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
	grep -q "phase1-round-cap" "$SKIP_LOG"
}

@test "PIPELINE_GATE_SKIP=1 with unwritable audit refuses (fail-closed override)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
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
	[[ $output == *"cannot count rounds"* ]] || [[ $output == *"jq failed"* ]]
}

@test "rev-list failure fails CLOSED (rc 2), never a vacuous zero (BASE_BRANCH not a ref)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3 BASE_BRANCH=no-such-base
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"is no-such-base a local ref?"* ]]
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
}

@test "status renders the P1 cap line at phase1, and degrades to <unavailable> without aborting" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 2 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" status
	[ "$status" -eq 0 ]
	[[ $output == *"P1 cap:      2/3"* ]]
	printf 'not json at all\n' >"$ROOT/.claude/review-log/$SHA.jsonl"
	run bash "$SCRIPT" status
	[ "$status" -eq 0 ]
	[[ $output == *"P1 cap:      <unavailable>/3"* ]]
}

@test "vanished logs (state records rounds>0, no log files) refuse a vacuous zero" {
	_seed_stage_phase1
	# State says 2 rounds were spent; no review-log file exists for any
	# branch sha — the logs vanished. Counting 0 would reopen the
	# pre-#2575 unbounded mode.
	printf '{"version":1,"stage":"phase1","branch":"feat-2575-cap","sha":"%s","phase1_rounds":2,"history":[]}\n' \
		"$SHA" >"$STATE_DIR/$SHA.json"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"review logs vanished"* ]]
}

@test "unreadable state file with no logs refuses a vacuous zero (p2r3)" {
	_seed_stage_phase1
	printf 'not json' >"$STATE_DIR/$SHA.json"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -ne 0 ]
	[[ $output == *"cannot prove zero rounds"* ]] || [[ $output == *"ERROR"* ]]
}
