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
	[[ $output == *"GRADUATED to phase2"* ]] || return 1
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]] || return 1
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
	[[ $output == *"phase1 round-cap ENFORCED (3/3)"* ]] || return 1
	[[ $output == *"uncovered:"* ]] || return 1
	[[ $output == *"PIPELINE_GATE_SKIP=1"* ]] || return 1
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]] || return 1
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
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]] || return 1
	[[ $output != *"round-cap ENFORCED"* ]] || return 1
	[ "$(_cur_stage)" = "phase1" ]
}

@test "cap is the scaler's value, not a constant (5-round tier, 3 rounds spent → directive)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=5
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]] || return 1
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
	[[ $output == *"round-cap ENFORCED"* ]] || return 1
	[[ $output == *"uncovered: ${SHA_PREV:0:7}=0/4"* ]] || return 1
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
	[[ $output == *"NO findings-bearing completed round"* ]] || return 1
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
	[[ $output == *"GRADUATED to phase2"* ]] || return 1
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
	[[ $output == *"UNDETERMINABLE"* ]] || return 1
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
	[[ $output == *"OVERRIDDEN via PIPELINE_GATE_SKIP=1"* ]] || return 1
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]] || return 1
	grep -q "phase1-round-cap" "$SKIP_LOG"
}

@test "PIPELINE_GATE_SKIP=1 with unwritable audit refuses (fail-closed override)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3 SKIP_LOG="$ROOT/.claude" # a directory — append fails
	PIPELINE_GATE_SKIP=1 run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"audit append FAILED"* ]] || return 1
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
}

@test "corrupt review log fails CLOSED (rc 2), never a vacuous count" {
	_seed_stage_phase1
	printf 'not json at all\n' >"$ROOT/.claude/review-log/$SHA.jsonl"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	# ONE exact diagnostic (p2r4): the or-chain could pass on a different
	# error class than the one this fixture provokes.
	[[ $output == *"cannot count rounds (corrupt review log?)"* ]]
}

@test "rev-list failure fails CLOSED (rc 2), never a vacuous zero (BASE_BRANCH not a ref)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 3 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3 BASE_BRANCH=no-such-base
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"is no-such-base a local ref?"* ]] || return 1
	[[ $output != *"DIRECTIVE FOR OPERATOR"* ]]
}

@test "status renders the P1 cap line at phase1, and degrades to <unavailable> without aborting" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 2 4
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" status
	[ "$status" -eq 0 ]
	[[ $output == *"P1 cap:      2/3"* ]] || return 1
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

@test "malformed phase1_rounds in valid state refuses a vacuous zero (p2r3, CI r1)" {
	# The state must PARSE for _get_stage (a fully-corrupt file dies there,
	# never reaching the counter — CI r1 caught the earlier test passing on
	# that wrong path). A valid stage with a non-numeric rounds value drives
	# _p1_zero_backed_by_state's strict-parse refusal for real.
	_seed_stage_phase1
	printf '{"version":1,"stage":"phase1","branch":"feat-2575-cap","sha":"%s","phase1_rounds":"garbage","history":[]}\n' \
		"$SHA" >"$STATE_DIR/$SHA.json"
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]
	[[ $output == *"cannot prove zero rounds"* ]]
}

@test "scaler exiting nonzero degrades LOUDLY to the default cap, never silently (p2r4)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 1 4
	printf '#!/usr/bin/env bash\nexit 3\n' >"$ROOT/.claude/hooks/phase1-scaler.sh"
	chmod +x "$ROOT/.claude/hooks/phase1-scaler.sh"
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"defaulting cap to 2"* ]] || return 1
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
}

@test "scaler emitting no ROUNDS line degrades LOUDLY to the default cap (p2r4)" {
	_seed_stage_phase1
	_seed_rounds "$SHA" 1 1 4
	printf '#!/usr/bin/env bash\necho "TIER=confused"\nexit 0\n' >"$ROOT/.claude/hooks/phase1-scaler.sh"
	chmod +x "$ROOT/.claude/hooks/phase1-scaler.sh"
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ]
	[[ $output == *"no parseable ROUNDS=N line"* ]] || return 1
	[[ $output == *"DIRECTIVE FOR OPERATOR"* ]]
}

# ---- (#2641) the phase0.5 -> phase1 collapse ----------------------------

_seed_stage_phase05() {
	printf '{"version":1,"stage":"phase0.5","branch":"feat-2575-cap","sha":"%s","history":[]}\n' \
		"$SHA" >"$STATE_DIR/$SHA.json"
}

_seed_phase05_log() {
	# The phase0.5 arm's gate: a logged prefilter row for this sha.
	mkdir -p "$ROOT/.claude/logs"
	printf '{"sha":"%s","findings":0,"status":"ok"}\n' "$SHA" \
		>"$ROOT/.claude/logs/phase0.5-run.jsonl"
}

@test "one next at phase0.5 lands BOTH the stage flip and the phase1 directive" {
	# THE COLLAPSE. Flipping to phase1 used to consume the whole invocation,
	# so the phase1 arm — which writes the directive marker + nonce and
	# prints the agent directive — could only run on a SECOND call. That
	# second call was byte-identical and argument-free, and the hook-ack
	# nagging the operator into typing it accounted for 246 of 511 recorded
	# blocks.
	#
	# Asserted on BOTH halves. Checking only the stage would pass on the old
	# two-call behaviour; checking only the directive would not prove the
	# stage advanced.
	_seed_stage_phase05
	_seed_phase05_log
	_seed_rounds "$SHA" 1 1 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next

	[ "$(_cur_stage)" = "phase1" ] || {
		echo "stage did not advance: $(_cur_stage)"
		return 1
	}
	# The phase1 arm ran in the SAME call — it either printed its directive
	# or took a documented phase1 exit (cap/graduation). What it must NOT do
	# is stop after the flip having produced neither.
	case "$output" in
	*"DIRECTIVE FOR OPERATOR"* | *"GRADUATED to phase2"* | *"round-cap ENFORCED"*) ;;
	*)
		echo "the phase1 arm never ran in this invocation: $output"
		return 1
		;;
	esac
	# And the two-step nag is gone for good.
	case "$output" in
	*"two-step"* | *"AGAIN"*)
		echo "the two-step directive is still being emitted: $output"
		return 1
		;;
	esac
}

@test "the collapse does NOT turn next into an unbounded walk" {
	# Scoped to one edge, capped at a single re-dispatch. cmd_resume is the
	# thing that walks many stages, deliberately and with its own
	# suppression rules.
	#
	# ASSERTS THE COUNT, not just the destination. Phase 0.5 pointed out
	# that checking only "the final stage is one of phase0.5/phase1/phase2"
	# would still pass if the loop re-dispatched several times and happened
	# to land inside that set — which is most of the machine. The bound is
	# what is under test, so the bound is what is measured: exactly one
	# re-dispatch, evidenced by the phase1 arm running exactly once.
	_seed_stage_phase05
	_seed_phase05_log
	_seed_rounds "$SHA" 1 1 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	# PINNED, not "0 or 2". Phase 0.5 round 2 was right that accepting
	# either outcome asserts almost nothing: rc 2 is this script's refusal
	# code, so a run that hit the refusal — the very thing a sibling test
	# exists to prove is reachable — would satisfy the loose form and hide
	# a regression that made the ordinary path refuse. A single sanctioned
	# re-dispatch is an ordinary advance and returns 0.
	[ "$status" -eq 0 ] || {
		echo "one sanctioned re-dispatch returned $status, expected 0: $output"
		return 1
	}

	# The dispatcher announces itself once per dispatch, so a collapsed
	# `next` prints the line twice: once entering phase0.5, once entering
	# the phase1 arm it collapsed into. Three would mean the loop re-entered
	# past the single sanctioned re-dispatch, which the cap exists to
	# prevent; one would mean the collapse never happened.
	local n
	n=$(printf '%s\n' "$output" | grep -c 'current stage = ' || true)
	# EXACTLY 2, not "at most 2". `-le` has no floor, so it is satisfied by
	# a run that never re-dispatched at all — which is precisely how the
	# sibling graduated-branch test passed with the collapse mutated OUT.
	# One sanctioned re-dispatch means the dispatcher ran twice: once for
	# phase0.5, once for the phase1 arm it collapsed into. Both the ceiling
	# (no walk) and the floor (the collapse happened) are the claim.
	[ "$n" -eq 2 ] || {
		echo "cmd_next dispatched $n times in one invocation, expected exactly 2: $output"
		return 1
	}
	case "$(_cur_stage)" in
	phase1 | phase2) ;;
	*)
		echo "one next landed at an unexpected stage: $(_cur_stage)"
		return 1
		;;
	esac
}

@test "the GRADUATED phase0.5 branch collapses too, and only once" {
	# There are two call sites that set _SHIP_NEXT_REDISPATCH: the per-sha
	# phase0.5-log match, and this one — a branch already graduated past
	# phase 0.5/1, which short-circuits before the log check. Every other
	# test here stubs graduation_check to rc 1, so this second entry into
	# the new machinery had no coverage at all: the collapse could have
	# been wired on one path and not the other, or wired on BOTH in a way
	# that asked twice, and nothing would have said so.
	cat >"$ROOT/.claude/_lib/phase-graduation.sh" <<'STUB'
graduation_check() { return 0; }
STUB
	_seed_stage_phase05
	# Deliberately NO phase0.5 log: the graduated path must not need one.
	_seed_rounds "$SHA" 1 1 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || {
		echo "the graduated collapse returned $status, expected 0: $output"
		return 1
	}
	# It must actually reach the phase1 arm in this one call, not stop at
	# the stage flip — that flip alone is what the old two-step did.
	case "$(_cur_stage)" in
	phase1 | phase2) ;;
	*)
		echo "the graduated branch did not advance past phase0.5: $(_cur_stage)"
		return 1
		;;
	esac
	local n
	n=$(printf '%s\n' "$output" | grep -c 'current stage = ' || true)
	[ "$n" -eq 2 ] || {
		echo "the graduated branch dispatched $n times in one invocation, expected exactly 2 (1 = the collapse did not happen): $output"
		return 1
	}
	# And it must NOT have gone the long way round: a two-step would have
	# told the operator to run next again.
	case "$output" in
	*two-step-phase1*)
		echo "the graduated branch still emits the two-step directive: $output"
		return 1
		;;
	esac
}

@test "a dispatch that FAILS does not re-dispatch, even having asked to" {
	# The wrapper checks the rc before the flag. That order is the whole
	# safety property: an arm that both errored and set the flag must
	# surface its error, not be retried into a stage it could not reach.
	# Reversed, a failing gate would be re-entered on the strength of a
	# flag it set before failing — the exact shape of a gate that refuses
	# and gets run again anyway.
	cd "$TEST_TMP" || return 1
	cat >"$TEST_TMP/fail-and-ask.sh" <<SHIM
#!/bin/bash
set -uo pipefail
_extracted=\$(sed -n '/^cmd_next()/,/^}\$/p' '$SCRIPT')
case "\$_extracted" in
*_SHIP_NEXT_REDISPATCH*) ;;
*)
	echo "SHIM: could not extract cmd_next" >&2
	exit 99
	;;
esac
_calls=0
_cmd_next_once() {
	_calls=\$((_calls + 1))
	echo "dispatch \$_calls"
	_SHIP_NEXT_REDISPATCH=1
	return 3
}
eval "\$_extracted"
cmd_next
_rc=\$?
echo "rc=\$_rc calls=\$_calls"
exit "\$_rc"
SHIM
	run bash "$TEST_TMP/fail-and-ask.sh"
	# The arm's own rc must reach the caller unchanged — not 0, not 2.
	[ "$status" -eq 3 ] || {
		echo "a failing dispatch returned $status, expected its own rc 3: $output"
		return 1
	}
	# And it must have run exactly once.
	case "$output" in
	*"dispatch 2"*)
		echo "a failing dispatch was re-dispatched anyway: $output"
		return 1
		;;
	esac
	case "$output" in
	*"dispatch 1"*) ;;
	*)
		echo "the shim never dispatched at all: $output"
		return 1
		;;
	esac
}

@test "a SECOND re-dispatch request in one next is REFUSED, not warned past" {
	# The defensive arm, which had no coverage: only the phase0.5 edge may
	# request a re-dispatch, and a second request means some other arm set
	# the flag — a broken state machine, not a slow path.
	#
	# It returns 2, not 0. Reporting success would let a caller and CI treat
	# a violated invariant as a clean advance, which is the silent
	# degradation this whole epic is about.
	#
	# Forced by wrapping the script with a shim that sets the flag from a
	# stage arm that must never set it.
	_seed_stage_phase05
	_seed_phase05_log
	_seed_rounds "$SHA" 1 1 0
	cd "$TEST_TMP" || return 1
	export STUB_ROUNDS=3
	cat >"$TEST_TMP/force-redispatch.sh" <<SHIM
#!/bin/bash
set -uo pipefail
# Source the orchestrator's functions without running main, then make the
# inner dispatcher always ask to re-dispatch.
# The two function bodies are lifted out of the script by range-extract
# rather than sourced, because sourcing runs main. That is brittle to a
# reformat of the function headers — so it is CHECKED: an empty extract
# would otherwise leave cmd_next undefined and the run would fail with
# status 127, which an "expected non-zero" assertion would happily accept.
_extracted=\$(sed -n '/^cmd_next()/,/^}\$/p' '$SCRIPT')
case "\$_extracted" in
*_SHIP_NEXT_REDISPATCH*) ;;
*)
	echo "SHIM: could not extract cmd_next from $SCRIPT — the range-extract needs updating" >&2
	exit 99
	;;
esac
eval "\$(sed -n '/^_cmd_next_once()/,/^}\$/p' '$SCRIPT')" 2>/dev/null || true
_cmd_next_once() {
	echo "ship-pr-cycle: current stage = stub"
	_SHIP_NEXT_REDISPATCH=1
	return 0
}
eval "\$_extracted"
cmd_next
SHIM
	chmod +x "$TEST_TMP/force-redispatch.sh"
	run bash "$TEST_TMP/force-redispatch.sh"
	[ "$status" -eq 2 ] || {
		echo "a repeated re-dispatch request returned $status, expected 2: $output"
		return 1
	}
	case "$output" in
	*"more than one stage re-dispatch"*) ;;
	*)
		echo "the refusal does not name the invariant it caught: $output"
		return 1
		;;
	esac
}

# ---- #2641: the phase-0.5 round cap -------------------------------------
#
# Phase 0.5 was the only review stage with no cap. Because the way you clear
# a phase-0.5 finding is to COMMIT a fix, and a new HEAD demands a fresh
# prefilter run, every round minted the next one. The branch that added this
# spent four rounds that way before anyone counted.

_seed_p05_log() { # $1..$n = shas that have a phase-0.5 row; findings via P05_FINDINGS
	mkdir -p "$ROOT/.claude/logs"
	: >"$ROOT/.claude/logs/phase0.5-run.jsonl"
	local _s
	for _s in "$@"; do
		printf '{"ts":"2026-01-01T00:00:00Z","sha":"%s","phase":0.5,"agent":"<all>","findings":%s,"status":"emitted"}\n' \
			"$_s" "${P05_FINDINGS:-4}" >>"$ROOT/.claude/logs/phase0.5-run.jsonl"
	done
}

_seed_p05_coverage() { # $1 = covers_count, dated AFTER the branch root
	mkdir -p "$ROOT/.claude/.session-state/prove-yourself"
	printf '{"finding_id":"t","kind":"fix","source":"phase0.5","covers_count":%s,"ts":"2099-01-01T00:00:00Z"}\n' \
		"$1" >"$ROOT/.claude/.session-state/prove-yourself/seeded.json"
}

@test "#2641: phase0.5 rounds are COUNTED per branch, not per sha" {
	# Per-sha would make the cap unreachable: every fix commit resets it.
	_seed_stage_phase05
	_seed_p05_log "$SHA" "$SHA_PREV"
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" next
	# Two branch shas carry a row, so two rounds are spent — under a cap of
	# 3 this must still proceed normally, not refuse.
	[ "$status" -ne 2 ] || {
		echo "two rounds under a cap of three was refused: $output"
		return 1
	}
}

@test "#2641: at the cap with every finding covered, the branch GRADUATES" {
	# The exit door. It opens on positive evidence — coverage — never on
	# the panel happening to go quiet, because an errored panel is quiet too.
	_seed_stage_phase05
	P05_FINDINGS=4 _seed_p05_log "$SHA_PREV" "$(cd "$TEST_TMP" && git rev-parse HEAD~2 2>/dev/null || echo "$SHA_PREV")"
	_seed_p05_coverage 99
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || {
		echo "a fully covered branch at the cap did not graduate (rc $status): $output"
		return 1
	}
	case "$output" in
	*"GRADUATED to phase1"*) ;;
	*)
		echo "the graduation is not announced: $output"
		return 1
		;;
	esac
	case "$(_cur_stage)" in
	phase1 | phase2) ;;
	*)
		echo "graduated but the stage did not advance: $(_cur_stage)"
		return 1
		;;
	esac
}

@test "#2641: at the cap with findings UNCOVERED, it refuses rc 2" {
	# The other half. Capping without the coverage requirement would just
	# be a way to skip review; the cap bounds the ROUNDS, not the work.
	_seed_stage_phase05
	P05_FINDINGS=7 _seed_p05_log "$SHA_PREV"
	_seed_p05_coverage 2
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "an uncovered branch at the cap returned $status, expected 2: $output"
		return 1
	}
	case "$output" in
	*"2/7 finding(s) covered"*) ;;
	*)
		echo "the refusal does not say how much is missing: $output"
		return 1
		;;
	esac
}

@test "#2641: at the cap with NO findings recorded, it refuses rather than graduating" {
	# All-zero at the cap means the panels errored or never ran. Silence is
	# not coverage, and this is the door an errored pipeline would otherwise
	# walk straight through.
	_seed_stage_phase05
	P05_FINDINGS=0 _seed_p05_log "$SHA_PREV"
	_seed_p05_coverage 50
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "an all-zero branch at the cap returned $status, expected 2: $output"
		return 1
	}
	case "$output" in
	*"NO findings are recorded"*) ;;
	*)
		echo "the refusal does not name the missing evidence: $output"
		return 1
		;;
	esac
}

@test "#2641: coverage from BEFORE this branch does not open the cap door" {
	# The bug the first draft of this gate had. The prove-yourself ledger is
	# not reset between branches — measured at 142 covers against 26
	# findings on the branch that added this, nearly all of them earned
	# elsewhere. Counting them would report a graduation nothing on this
	# branch paid for, which is worse than having no cap at all.
	_seed_stage_phase05
	P05_FINDINGS=9 _seed_p05_log "$SHA_PREV"
	mkdir -p "$ROOT/.claude/.session-state/prove-yourself"
	printf '{"finding_id":"old","kind":"fix","source":"phase0.5","covers_count":500,"ts":"1999-01-01T00:00:00Z"}\n' \
		>"$ROOT/.claude/.session-state/prove-yourself/ancient.json"
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "pre-branch coverage opened the cap door (rc $status): $output"
		return 1
	}
	case "$output" in
	*"0/9 finding(s) covered"*) ;;
	*)
		echo "the stale records were counted: $output"
		return 1
		;;
	esac
}

@test "#2641: PIPELINE_GATE_SKIP overrides the cap, and says so" {
	# Every gate in this repo has one audited escape. A cap with no override
	# is a cap that gets removed the first time it is inconvenient.
	_seed_stage_phase05
	P05_FINDINGS=9 _seed_p05_log "$SHA_PREV"
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	export PIPELINE_GATE_SKIP=1
	run bash "$SCRIPT" next
	[ "$status" -ne 2 ] || {
		echo "the override did not override: $output"
		return 1
	}
	case "$output" in
	*"OVERRIDDEN by PIPELINE_GATE_SKIP"*) ;;
	*)
		echo "the override is silent — an unaudited bypass: $output"
		return 1
		;;
	esac
}

@test "#2641: PHASE05_ROUND_CAP=0 disables the cap entirely" {
	# The documented off switch. 0 must mean "no cap", not "cap of zero",
	# which would refuse every branch immediately.
	_seed_stage_phase05
	P05_FINDINGS=9 _seed_p05_log "$SHA_PREV"
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=0
	run bash "$SCRIPT" next
	[ "$status" -ne 2 ] || {
		echo "a cap of 0 refused instead of disabling: $output"
		return 1
	}
}

@test "#2641: a non-numeric PHASE05_ROUND_CAP fails loudly, not silently" {
	# A typo'd cap must not read as "unlimited" — that is how a bound
	# disappears without anyone noticing.
	_seed_stage_phase05
	_seed_p05_log "$SHA_PREV"
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=three
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "a non-numeric cap returned $status, expected 2: $output"
		return 1
	}
	case "$output" in
	*"must be a non-negative integer"*) ;;
	*)
		echo "the refusal does not name the bad value: $output"
		return 1
		;;
	esac
}
