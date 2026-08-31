#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# (#2641) The phase-0.5 round cap.
#
# Phase 0.5 was the only review stage in the cycle with no cap. Because the
# way you clear a phase-0.5 finding is to COMMIT a fix, and a new HEAD
# demands a fresh prefilter run, every round minted the next one. The branch
# that added this spent three rounds and 26 findings that way with a fourth
# queued; convergence required a 5-agent panel to return zero on a diff it
# had already reviewed three times.
#
# Split out of ship-pr-cycle-phase1-cap.bats, which covers a different gate:
# one file per gate is what lets scripts/test-touched.sh map a changed gate
# to the suite that actually covers it.
#
# THE FIXTURES ARE FAITHFUL ON PURPOSE. The first version of these tests
# seeded only a {agent:"<all>"} row per sha, so a gate that read the wrong
# row — which the real gate did, taking a MAX over per-agent rows and
# landing up to 4x below the truth — was invisible to every one of them.
# The real log carries one row per agent plus a terminal aggregate, so these
# fixtures do too.
# shellcheck disable=SC2030,SC2031

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-p05cap.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		git branch -M main
		git checkout -q -b feat-2641-p05cap
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work1
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work2
		# THREE branch commits, not two. The cap only engages when HEAD has
		# no phase-0.5 row, so proving per-branch counting needs two OTHER
		# branch shas to carry rounds. With two commits, HEAD~2 is main's
		# root — not a branch sha at all — and the fixture silently seeded
		# one round instead of two, which is how the first version of the
		# per-branch test passed with the counter deleted.
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work3
		mkdir -p .claude/hooks .claude/_lib .claude/review-log .claude/audit .claude/logs
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
	ROOT=$(cd "$TEST_TMP" && git rev-parse --show-toplevel)
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	SHA_PREV=$(cd "$TEST_TMP" && git rev-parse HEAD~1)
	SHA_PREV2=$(cd "$TEST_TMP" && git rev-parse HEAD~2)
	STATE_DIR="$ROOT/.claude/.session-state/ship-cycle"
	mkdir -p "$STATE_DIR"
	P05_LOG="$ROOT/.claude/logs/phase0.5-run.jsonl"
	AUDIT="$ROOT/.claude/audit/prove-yourself.jsonl"

	cat >"$ROOT/.claude/hooks/phase1-scaler.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ROUNDS=%s\n' "${STUB_ROUNDS:-3}"
exit 0
STUB
	chmod +x "$ROOT/.claude/hooks/phase1-scaler.sh"
	cat >"$ROOT/.claude/_lib/phase-graduation.sh" <<'STUB'
graduation_check() { return 1; }
STUB
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-p05cap.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_seed_stage_phase05() {
	printf '{"version":1,"stage":"phase0.5","branch":"feat-2641-p05cap","sha":"%s","history":[]}\n' \
		"$SHA" >"$STATE_DIR/$SHA.json"
}

_cur_stage() {
	jq -r '.stage' "$STATE_DIR/$SHA.json"
}

# A COMPLETE phase-0.5 round: five per-agent rows plus the terminal
# aggregate the gate must key on. The per-agent counts deliberately do NOT
# sum to the aggregate — dedupe removes findings, which is its whole job, so
# a gate that sums or maxes over agent rows gets a different (wrong) answer
# and these fixtures expose it.
_seed_p05_round() { # $1 = sha, $2 = aggregate findings
	local sha="$1" agg="$2" a
	for a in code-reviewer code-simplifier comment-analyzer pr-test-analyzer silent-failure-hunter; do
		printf '{"ts":"2026-01-01T00:00:00Z","sha":"%s","phase":"0.5","agent":"%s","findings":7,"status":"ok"}\n' \
			"$sha" "$a" >>"$P05_LOG"
	done
	printf '{"ts":"2026-01-01T00:00:00Z","sha":"%s","phase":"0.5","agent":"<all>","findings":%s,"status":"emitted"}\n' \
		"$sha" "$agg" >>"$P05_LOG"
}

# A round that STARTED and never reached its terminal: agent rows, no
# aggregate. Must be undeterminable, never scored as its loudest agent.
_seed_p05_unterminated() { # $1 = sha
	local a
	for a in code-reviewer pr-test-analyzer; do
		printf '{"ts":"2026-01-01T00:00:00Z","sha":"%s","phase":"0.5","agent":"%s","findings":6,"status":"ok"}\n' \
			"$1" "$a" >>"$P05_LOG"
	done
}

_seed_cover() { # $1 = sha, $2 = covers_count, $3 = source (default phase0.5)
	printf '{"source":"%s","covered_sha":"%s","covers_count":%s}\n' \
		"${3:-phase0.5}" "$1" "$2" >>"$AUDIT"
}

# ---- counting ------------------------------------------------------------

@test "rounds are counted PER BRANCH, not per sha" {
	# Per-sha counting resets on every fix commit, which makes the cap
	# unreachable by construction — the branch just keeps minting rounds.
	#
	# The cap is set to 2 and BOTH branch shas carry a round, so the two
	# counting modes give different answers: per-branch = 2 (at the cap,
	# refuse or graduate), per-sha = 1 (under it, proceed). An earlier
	# version of this test used the default cap of 3, where both modes are
	# under the cap and the whole block is skipped either way — it asserted
	# only `status != 2` and passed with the counter deleted outright.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 5
	_seed_p05_round "$SHA_PREV2" 5
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=2
	run bash "$SCRIPT" next
	# At the cap with nothing covered: refusal. Per-sha counting would have
	# proceeded to "not yet logged" (rc 1) instead.
	[ "$status" -eq 2 ] || {
		echo "two branch shas under a cap of 2 did not reach the cap (rc $status) — counted per sha? $output"
		return 1
	}
	case "$output" in
	*"round-cap reached (2/2)"*) ;;
	*)
		echo "the cap did not report the per-branch count: $output"
		return 1
		;;
	esac
}

# ---- the exit door -------------------------------------------------------

@test "at the cap with every findings-bearing sha covered, the branch GRADUATES" {
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 5
	_seed_cover "$SHA_PREV" 5
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

@test "the findings bar is the TERMINAL AGGREGATE, not a max over agent rows" {
	# The defect that shipped: the gate took the MAX over a sha's rows.
	# Measured against the real log that is up to 4x low — af2ea771 gave 5
	# where its agent rows sum to 14. Here the aggregate is 20 and each
	# agent row says 7, so a max-reading gate sees a bar of 7 and graduates
	# on 8 covers; the correct bar is 20 and 8 must NOT be enough.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 20
	_seed_cover "$SHA_PREV" 8
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "8 covers cleared a 20-finding bar (rc $status) — the bar was read from an agent row: $output"
		return 1
	}
	case "$output" in
	*"=8/20"*) ;;
	*)
		echo "the refusal does not report the aggregate as the bar: $output"
		return 1
		;;
	esac
}

@test "the NEWEST terminal aggregate wins when a sha was re-run" {
	# Re-running the prefilter on an unchanged sha appends a second
	# aggregate. Summing them would inflate the bar until it can never be
	# met; taking the first would score a stale round.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 4
	_seed_p05_round "$SHA_PREV" 9
	_seed_cover "$SHA_PREV" 9
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	export STUB_ROUNDS=3
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || {
		echo "9 covers did not clear the newest bar of 9 (rc $status) — summed to 13, or read the stale 4? $output"
		return 1
	}
}

# ---- the refusals --------------------------------------------------------

@test "at the cap with findings UNCOVERED, it refuses rc 2" {
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 7
	_seed_cover "$SHA_PREV" 2
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "an uncovered branch at the cap returned $status, expected 2: $output"
		return 1
	}
	case "$output" in
	*"=2/7"*) ;;
	*)
		echo "the refusal does not say how much is missing: $output"
		return 1
		;;
	esac
}

@test "coverage on ONE sha does not launder another sha's findings" {
	# Per-sha, not in aggregate. Comparing summed totals lets a heavily
	# covered sha carry an uncovered one — the exact defect the phase-1
	# gate's own hardening comment says it was rewritten to close, and the
	# security pass found it here too. Totals: 12 covered vs 12 found, which
	# an aggregate comparison graduates; per sha, the second is 0/6.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 6
	_seed_p05_round "$SHA_PREV2" 6
	_seed_cover "$SHA_PREV" 12
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "coverage on one sha graduated a branch with another uncovered (rc $status): $output"
		return 1
	}
	case "$output" in
	*"=0/6"*) ;;
	*)
		echo "the refusal does not name the uncovered sha: $output"
		return 1
		;;
	esac
}

@test "a round with no TERMINAL aggregate is undeterminable, not zero" {
	# Agent rows without the {agent:\"<all>\",status:\"emitted\"} row mean a
	# round that did not finish. Summing its pre-emission rows would count
	# findings that were never emitted — the laundering class the dedupe
	# library names — and scoring it zero would let a crashed round satisfy
	# the cap by contributing nothing.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 4
	_seed_cover "$SHA_PREV" 4
	_seed_p05_unterminated "$SHA_PREV2"
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "an unterminated round did not block graduation (rc $status): $output"
		return 1
	}
	case "$output" in
	*UNDETERMINABLE*) ;;
	*)
		echo "the refusal does not name the undeterminable sha: $output"
		return 1
		;;
	esac
}

@test "at the cap with NO findings at all, it refuses rather than graduating" {
	# All-zero at the cap means the panels errored or never ran. Silence is
	# not coverage, and this is the door an errored pipeline would otherwise
	# walk straight through.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 0
	_seed_cover "$SHA_PREV" 50
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "an all-zero branch at the cap returned $status, expected 2: $output"
		return 1
	}
	case "$output" in
	*"NO findings-bearing sha"*) ;;
	*)
		echo "the refusal does not name the missing evidence: $output"
		return 1
		;;
	esac
}

@test "coverage from ANOTHER STAGE does not open the cap door" {
	# The ledger holds cr and phase1 records alongside phase0.5 ones — on
	# the branch that wrote this, 95 cr and 34 phase1 against 19 phase0.5.
	# Without the source filter the gate opens on another stage's evidence,
	# the same failure class as the branch-scoping bug that DID get a test.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 9
	_seed_cover "$SHA_PREV" 500 phase1
	_seed_cover "$SHA_PREV" 500 cr
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "phase1/cr coverage opened the phase0.5 cap door (rc $status): $output"
		return 1
	}
	case "$output" in
	*"=0/9"*) ;;
	*)
		echo "another stage's records were counted: $output"
		return 1
		;;
	esac
}

@test "coverage recorded against a NON-BRANCH sha does not count" {
	# Branch scoping comes from the ledger's own covered_sha. The first
	# version derived it from a commit-timestamp window instead, which
	# admitted any record written after this branch's root commit —
	# including coverage earned on a different branch later the same
	# session. The security pass measured 27 such covers falling inside the
	# window on a live checkout.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 9
	_seed_cover "0000000000000000000000000000000000000000" 500
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "coverage against a foreign sha opened the cap door (rc $status): $output"
		return 1
	}
	case "$output" in
	*"=0/9"*) ;;
	*)
		echo "a foreign sha's records were counted: $output"
		return 1
		;;
	esac
}

@test "a CORRUPT log refuses instead of making graduation easier" {
	# Every reader here uses `fromjson?`, which silently drops unparseable
	# lines. That LOWERS the findings bar while coverage is untouched, so
	# corruption makes the door easier to open, not harder.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 9
	_seed_cover "$SHA_PREV" 9
	printf 'this is not json\n' >>"$P05_LOG"
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "a corrupt log still graduated (rc $status): $output"
		return 1
	}
	case "$output" in
	*"unparseable line"*) ;;
	*)
		echo "the refusal does not name the corruption: $output"
		return 1
		;;
	esac
}

# ---- the escapes ---------------------------------------------------------

@test "PIPELINE_GATE_SKIP overrides the cap, and is AUDIT-LOGGED" {
	# The shared override contract (#2565): audit-logged is a precondition,
	# not an aspiration. This was the only one of the three PIPELINE_GATE_SKIP
	# sites that just echoed and proceeded — one env var meaning two
	# different things depending on which gate read it.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 9
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
	case "$output" in
	*"audit-logged"*) ;;
	*)
		echo "the override does not claim to be audited: $output"
		return 1
		;;
	esac
	[ -s "$ROOT/.claude/logs/pipeline-skip.jsonl" ] || {
		echo "no audit row was actually written — the claim is a lie"
		ls -la "$ROOT/.claude/logs/" 2>&1
		return 1
	}
}

@test "an override whose AUDIT APPEND fails is refused, not taken" {
	# The half that matters: audit-logged is a PRECONDITION. If the row
	# cannot be written, the override must refuse rather than proceed
	# unlogged — otherwise "audited bypass" is a claim with nothing behind
	# it, which is worse than an unaudited one because it reads as safe.
	#
	# Forced by pointing the writer at a path it cannot create. The sibling
	# guard (writer function entirely absent) is not reachable from a test:
	# the orchestrator sources pipeline-skip.sh from the installed plugin
	# directory, not from the sandbox, so a shadow copy here is never read.
	# Saying so rather than leaving a test that silently exercised the
	# ordinary override path and asserted the wrong thing.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 9
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	export PIPELINE_GATE_SKIP=1
	export SKIP_LOG="$ROOT/.claude/logs/unwritable/pipeline-skip.jsonl"
	mkdir -p "$ROOT/.claude/logs"
	: >"$ROOT/.claude/logs/unwritable"
	run bash "$SCRIPT" next
	rm -f "$ROOT/.claude/logs/unwritable"
	[ "$status" -eq 2 ] || {
		echo "an override whose audit append failed was taken anyway (rc $status): $output"
		return 1
	}
	case "$output" in
	*UNLOGGED*) ;;
	*)
		echo "the refusal does not say why: $output"
		return 1
		;;
	esac
}

@test "PHASE05_ROUND_CAP=0 disables the cap, and SAYS SO" {
	# The documented off switch. 0 means "no cap", not "cap of zero" — and
	# it must not be silent: a bound that vanishes because of a stale env
	# var with nothing on stderr is the same unaudited bypass the
	# PIPELINE_GATE_SKIP arm is careful about.
	#
	# rc is PINNED to 1 ("not yet logged"), not merely "not 2". Asserting
	# only `!= 2` passes if the arm dies for any non-refusal reason, so it
	# would never observe the disabled cap being stepped past.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 9
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=0
	run bash "$SCRIPT" next
	[ "$status" -eq 1 ] || {
		echo "a disabled cap returned $status, expected 1 (not-yet-logged): $output"
		return 1
	}
	case "$output" in
	*"not yet logged"*) ;;
	*)
		echo "the normal path was not reached: $output"
		return 1
		;;
	esac
	case "$output" in
	*"DISABLED by PHASE05_ROUND_CAP=0"*) ;;
	*)
		echo "the cap disappeared silently: $output"
		return 1
		;;
	esac
}

@test "a non-numeric PHASE05_ROUND_CAP fails loudly, not silently" {
	# A typo'd cap must not read as "unlimited" — that is how a bound
	# disappears without anyone noticing.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 4
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

@test "every cap-gate CALL SITE captures rc instead of calling bare" {
	# Under this script's `set -euo pipefail`, a BARE `_phase05_cap_gate ...`
	# followed by `return $?` never returns: errexit sees the refusal's
	# non-zero and EXITS the shell, so cmd_next's wrapper never runs and
	# cmd_resume dies instead of handling the refusal.
	#
	# No behavioural test can see this. exit(2) and return 2 both reach
	# bats' `run` as status 2, and cmd_resume captures cmd_next with
	# `|| rc=$?` so it reports the same number either way. CR-CLI caught it
	# by reading, on the commit that introduced it — the tests were green.
	#
	# So the PATTERN is what gets enforced, across all three gates: a call
	# site must capture the status. This also fails if a fourth gate is
	# added later and copies the bare form, which is the shape of mistake
	# that produced this one.
	local script="${BATS_TEST_DIRNAME}/../../../scripts/ship-pr-cycle.sh"
	[ -r "$script" ]
	local bad="" line n=0
	while IFS= read -r line; do
		n=$((n + 1))
		# Definitions and comments are not call sites.
		case "$line" in
		*'_cap_gate() {'* | *'#'*) continue ;;
		esac
		# A call site must pipe its status somewhere: `|| rc=$?`, an `if`,
		# or a `!` test. Anything else lets errexit swallow the refusal.
		case "$line" in
		*'|| '*'=$?'* | 'if '* | *'if !'* | *' if '*) continue ;;
		esac
		bad="$bad
    $line"
	done < <(grep -nE '_phase(05|1|2)_cap_gate[[:space:]]+"' "$script" || true)

	[ "$n" -gt 0 ] || {
		echo "no cap-gate call sites matched — the grep is stale, so this test checked nothing"
		return 1
	}
	[ -z "$bad" ] || {
		echo "cap-gate call site(s) do not capture the status, so errexit will exit instead of returning:$bad"
		return 1
	}
}

@test "the cap refusal is ROUTED THROUGH hook-ack, not just printed" {
	# stderr scrolls. The phase-1 and phase-2 caps both register their
	# refusal as a hook-ack diagnostic so the next tool call is blocked
	# until the operator reads it; this one printed to stderr alone, which
	# is the difference between a refusal that must be acknowledged and one
	# that can be missed.
	#
	# hook_ack_append short-circuits under bats by design, so what is
	# asserted is the DIAGNOSTIC — written for real, into the sandbox.
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 7
	_seed_cover "$SHA_PREV" 2
	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ]

	local dir="$ROOT/.claude/.session-state/hook-ack/ship-pr-cycle-p05cap"
	[ -d "$dir" ] || {
		echo "no hook-ack diagnostic directory — the refusal is stderr-only"
		ls -la "$ROOT/.claude/.session-state/hook-ack" 2>&1
		return 1
	}
	local f
	f=$(find "$dir" -name '*.txt' -type f 2>/dev/null | tail -1)
	[ -n "$f" ] && [ -s "$f" ] || {
		echo "the diagnostic is missing or empty in $dir"
		return 1
	}
	# It must carry the SAME message the operator saw, not a stub — a file
	# that exists but says nothing still blocks, and tells them nothing.
	grep -q '=2/7' "$f" || {
		echo "the diagnostic does not carry the shortfall: $(cat "$f")"
		return 1
	}
}

@test "no short-circuiting reader sits downstream of a pipe under pipefail" {
	# THE BUG THIS PR STARTED FROM, and it has now recurred three times.
	#
	# `grep -q` and `head -c N` exit as soon as they have what they need,
	# SIGPIPE-ing whatever is still writing upstream. Under `set -o
	# pipefail` — which both these files set — the pipeline then reports
	# FAILURE even though the read succeeded. In hook-ack that made every
	# diagnostic filename fall back to the pid, for 511 files. In the round
	# counter it would have left a sha uncounted, LOWERING the count and
	# arming another prefilter round.
	#
	# No practical test reproduces it: the window only opens once the
	# upstream output exceeds the pipe buffer, so fixtures pass either way
	# and CR-in-CI caught the recurrence by reading. The SHAPE is therefore
	# what gets enforced, in the two files that have carried it.
	#
	# The fix each time is a here-string or a redirect — no pipeline, so no
	# exit status to misread.
	local f hits="" found repo="${BATS_TEST_DIRNAME}/../../.."
	for f in "$repo/scripts/ship-pr-cycle.sh" "$repo/_lib/hook-ack.sh"; do
		[ -r "$f" ] || {
			echo "expected file missing, so this test checked nothing: $f"
			return 1
		}
		# Code only — a comment describing the anti-pattern is not the
		# anti-pattern, and both files are full of such comments now.
		found=$(grep -nE '\|[[:space:]]*(grep -q|head -c)' "$f" |
			grep -vE '^[0-9]+:[[:space:]]*#' || true)
		[ -z "$found" ] || hits="$hits
  ${f##*/}:
$found"
	done
	[ -z "$hits" ] || {
		echo "short-circuiting reader downstream of a pipe (SIGPIPE under pipefail):$hits"
		echo "Use a here-string or a redirect instead — no pipeline, no status to misread."
		return 1
	}
}

@test "the round counter survives a log larger than the pipe buffer" {
	# THE BEHAVIOURAL REPRODUCTION, as CR-in-CI asked for. The sibling
	# source-shape guard cannot see a newline-formatted pipeline; this one
	# does not care how the code is spelled, only what it does.
	#
	# The defect: `printf '%s\n' "$_logged" | grep -qxF "$_sha"`. grep -q
	# exits at its FIRST match, so if the wanted sha appears early and a
	# lot follows it, printf is still writing when the pipe closes, takes
	# SIGPIPE, and under `set -o pipefail` the whole pipeline reports
	# failure — the sha goes UNCOUNTED. That lowers the round count, which
	# ARMS another prefilter round: the cap silently stops capping.
	#
	# So: put the branch sha FIRST, then flood the log past the 64KiB pipe
	# buffer. With the bug the count drops to 0 and `next` walks on to
	# "not yet logged" (rc 1). With the here-string it counts 1, reaches
	# the cap of 1, and refuses (rc 2).
	_seed_stage_phase05
	_seed_p05_round "$SHA_PREV" 4
	# ~3000 rows of 40-char shas — comfortably past the buffer, and the
	# match is already behind us by the first of them.
	local i
	for i in $(seq 1 3000); do
		printf '{"ts":"2026-01-01T00:00:00Z","sha":"%040d","phase":"0.5","agent":"<all>","findings":0,"status":"emitted"}\n' \
			"$i" >>"$P05_LOG"
	done
	# Sanity: the sha list this drives really is bigger than a pipe buffer,
	# or the test proves nothing about the window it claims to open.
	local bytes
	bytes=$(jq -r -R 'fromjson? | .sha // empty' "$P05_LOG" | wc -c | tr -d ' ')
	[ "$bytes" -gt 65536 ] || {
		echo "the seeded sha list is only $bytes bytes — under the pipe buffer, so the SIGPIPE window never opens and this test is vacuous"
		return 1
	}

	cd "$TEST_TMP" || return 1
	export PHASE05_ROUND_CAP=1
	run bash "$SCRIPT" next
	[ "$status" -eq 2 ] || {
		echo "the branch sha was not counted under a large log (rc $status, expected 2) — the round count dropped and the cap did not engage: $output"
		return 1
	}
	case "$output" in
	*"round-cap reached (1/1)"*) ;;
	*)
		echo "the cap did not report the sha as counted: $output"
		return 1
		;;
	esac
}
