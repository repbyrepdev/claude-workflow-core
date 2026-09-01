#!/usr/bin/env bats
# covers: _lib/stage-findings.sh
#
# (#2643) The guard for a real, expensive mistake — and, on its first
# attempt, a demonstration of the same mistake.
#
# 42 phase0.5 findings across three shas were recorded as `--source issue`.
# The work was done and committed; the label was wrong. The graduation gate
# counts only `source == "phase0.5"`, so it reported 0/17, 0/13, 0/12, and
# because `covered_sha` was stamped from HEAD the records could not be
# corrected. The only exits were a bypass or re-running three rounds.
#
# THE FIRST VERSION OF THESE TESTS PINNED SCHEMAS THAT DO NOT EXIST. They
# fed `{"finding_id":"a"}` rows to the phase1 arm and full shas to the cr
# arm, both of which the real writers never produce — so the suite was green
# over a guard that returned 0 for every sha on two of three stages. A test
# that invents its own fixture format validates the invention, not the code.
#
# Every fixture below is now copied from a REAL row emitted by the real
# writer, with the writer named. That is the only thing that makes these
# tests worth anything.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$REPO_ROOT/_lib/stage-findings.sh"
	# FAIL, do not skip — a missing subject must not read as a pass.
	[ -r "$LIB" ] || {
		echo "FATAL: subject under test missing at $LIB" >&2
		return 1
	}
	WORK=$(mktemp -d -t stage-findings.XXXXXX) || return 1
	mkdir -p "$WORK/.claude/logs" "$WORK/.claude/review-log"
}

teardown() {
	case "${WORK:-}" in
	*/stage-findings.*) rm -rf "$WORK" ;;
	esac
	return 0
}

_load() {
	# shellcheck source=/dev/null
	. "$LIB"
}

# ---- phase0.5: the terminal aggregate is the authority --------------------
# Writer: _lib/phase05-dedupe.sh. Per-agent rows are written BEFORE emission;
# only {agent:"<all>", status:"emitted"} is trustworthy. Summing or maxing the
# per-agent rows is measured wrong by up to 4x, in both directions —
# scripts/ship-pr-cycle.sh::_phase05_findings_for_sha documents the numbers.

@test "phase0.5 reads the terminal aggregate, not the per-agent rows" {
	_load
	{
		printf '{"sha":"aaaa111","agent":"copilot","findings":9,"status":"parsed"}\n'
		printf '{"sha":"aaaa111","agent":"other","findings":14,"status":"parsed"}\n'
		printf '{"sha":"aaaa111","agent":"<all>","findings":12,"status":"emitted"}\n'
	} >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 aaaa111
	[ "$status" -eq 0 ]
	[ "$output" = "12" ] || {
		echo "expected the aggregate's 12, got '$output' — a per-agent row was used"
		return 1
	}
}

@test "phase0.5 rows with NO terminal aggregate are 'unknown', never zero" {
	# A crashed emit leaves per-agent rows and no aggregate. Reporting 0
	# there would mark the sha covered and shrink the graduation bar.
	_load
	printf '{"sha":"bbbb222","agent":"copilot","findings":9,"status":"parsed"}\n' \
		>"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 bbbb222
	[ "$output" = "unknown" ] || {
		echo "a crashed emit reported '$output' instead of unknown"
		return 1
	}
	[ "$status" -eq 2 ]
}

@test "phase0.5 takes the NEWEST aggregate when the prefilter re-ran" {
	_load
	{
		printf '{"sha":"cccc333","agent":"<all>","findings":17,"status":"emitted"}\n'
		printf '{"sha":"cccc333","agent":"<all>","findings":4,"status":"emitted"}\n'
	} >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 cccc333
	[ "$output" = "4" ] || {
		echo "expected the newest aggregate (4), got '$output'"
		return 1
	}
}

@test "phase0.5 with no rows for the sha is a real zero" {
	_load
	printf '{"sha":"aaaa111","agent":"<all>","findings":12,"status":"emitted"}\n' \
		>"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 zzzz999
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

# ---- phase1: sum the latest round's per-agent rows ------------------------
# Writer: hooks/review-log.sh, which emits
# {ts,sha,phase,round,agent,findings,status,diff_hash} — NO finding_id.
# Authority for the sum: pre-commit-hooks/prove-yourself-gate.sh.

@test "phase1 SUMS the latest round's agent rows (real review-log schema)" {
	# The row shape here is copied from hooks/review-log.sh. The first
	# version of this test invented `{"finding_id":"a"}` rows, which the
	# writer never emits — so the arm returned 0 for every real sha and
	# this suite stayed green over a guard that never fired.
	_load
	{
		printf '{"ts":"t","sha":"eeee555","phase":1,"round":1,"agent":"code-reviewer","findings":3,"status":"ok"}\n'
		printf '{"ts":"t","sha":"eeee555","phase":1,"round":1,"agent":"silent-failure-hunter","findings":5,"status":"ok"}\n'
	} >"$WORK/.claude/review-log/eeee555.jsonl"
	run _stage_findings_count "$WORK" phase1 eeee555
	[ "$status" -eq 0 ]
	[ "$output" = "8" ] || {
		echo "expected 3+5=8 from the real schema, got '$output'"
		return 1
	}
}

@test "phase1 uses only the LATEST round" {
	_load
	{
		printf '{"sha":"ffff666","phase":1,"round":1,"agent":"a","findings":9,"status":"ok"}\n'
		printf '{"sha":"ffff666","phase":1,"round":2,"agent":"a","findings":2,"status":"ok"}\n'
	} >"$WORK/.claude/review-log/ffff666.jsonl"
	run _stage_findings_count "$WORK" phase1 ffff666
	[ "$output" = "2" ] || {
		echo "expected only round 2's findings (2), got '$output'"
		return 1
	}
}

# ---- cr: SHORT sha, and a partial run is not a clean one -----------------
# Writer: scripts/cr/local-review.sh via the cr budget log. It records a
# 7-char sha; the first version compared full shas and never matched.

@test "cr matches on the SHORT sha the log actually stores" {
	_load
	printf '{"ts":"t","sha":"1fa8580","script":"cr-local-review","rc":0,"findings":6}\n' \
		>"$WORK/.claude/logs/cr-local-review.jsonl"
	run _stage_findings_count "$WORK" cr 1fa8580abcdef1234567890abcdef1234567890a
	[ "$status" -eq 0 ]
	[ "$output" = "6" ] || {
		echo "a full sha did not match the short sha in the log: got '$output'"
		return 1
	}
}

@test "cr ignores a PARTIAL/TIMED-OUT run rather than reading it as clean" {
	# #2544: a killed CR-CLI logs findings:0 truthfully meaning "0 SEEN",
	# not "0 exist". Counting it would call an unreviewed sha clean.
	_load
	{
		printf '{"sha":"2bb2222","rc":0,"findings":4}\n'
		printf '{"sha":"2bb2222","rc":124,"findings":0,"partial":true,"timeout":true}\n'
	} >"$WORK/.claude/logs/cr-local-review.jsonl"
	run _stage_findings_count "$WORK" cr 2bb2222
	[ "$output" = "4" ] || {
		echo "a partial run erased the real finding count: got '$output'"
		return 1
	}
}

# ---- failure handling ----------------------------------------------------

@test "an unreadable log is 'unknown', not zero" {
	# Coercing a read failure to 0 shrinks the graduation bar — the same
	# coercion _phase05_findings_for_sha refuses, for the same reason.
	_load
	printf 'this is not json at all\n' >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 aaaa111
	[ "$output" = "unknown" ] || {
		echo "a corrupt log reported '$output' instead of unknown"
		return 1
	}
	[ "$status" -eq 2 ]
}

@test "a genuinely absent log is a real zero, not unknown" {
	# The distinction that keeps the guard usable: no log at all means the
	# stage never ran here, which IS zero findings.
	_load
	run _stage_findings_count "$WORK" cr dddd444
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "an unknown stage name is 'unknown', not a silent zero" {
	_load
	run _stage_findings_count "$WORK" not-a-stage aaaa111
	[ "$output" = "unknown" ]
	[ "$status" -eq 2 ]
}

# ---- stages_at -----------------------------------------------------------

@test "stages_at names every stage with findings at that sha" {
	_load
	printf '{"sha":"ffff666","agent":"<all>","findings":3,"status":"emitted"}\n' \
		>"$WORK/.claude/logs/phase0.5-run.jsonl"
	printf '{"sha":"ffff666","rc":0,"findings":5}\n' \
		>"$WORK/.claude/logs/cr-local-review.jsonl"
	run _stage_findings_stages_at "$WORK" ffff666
	[ "$status" -eq 0 ]
	[[ $output == *phase0.5* ]] || {
		echo "phase0.5 missing: $output"
		return 1
	}
	[[ $output == *cr* ]] || {
		echo "cr missing: $output"
		return 1
	}
}

@test "stages_at finds phase1 through the REAL schema" {
	# The regression guard for the dead arm. Without it, phase1 could never
	# appear here and a correct --source phase1 would be refused on any sha
	# that also carried phase0.5 findings.
	_load
	printf '{"sha":"aaaa777","phase":1,"round":1,"agent":"a","findings":2,"status":"ok"}\n' \
		>"$WORK/.claude/review-log/aaaa777.jsonl"
	run _stage_findings_stages_at "$WORK" aaaa777
	[ "$status" -eq 0 ]
	[[ $output == *phase1* ]] || {
		echo "phase1 is invisible to stages_at — the arm is dead again: '$output'"
		return 1
	}
}

@test "stages_at is EMPTY when no stage logged findings" {
	# The load-bearing negative: a spurious stage here would make the
	# caller's mismatch refusal fire on every record.
	_load
	printf '{"sha":"ffff666","agent":"<all>","findings":0,"status":"emitted"}\n' \
		>"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_stages_at "$WORK" ffff666
	[ "$status" -eq 0 ]
	[ -z "$output" ] || {
		echo "expected no stages, got: $output"
		return 1
	}
}

@test "stages_at propagates 'unknown' as a failure, not as no-findings" {
	_load
	printf 'garbage\n' >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_stages_at "$WORK" ffff666
	[ "$status" -ne 0 ] || {
		echo "an undeterminable stage reported success, which the caller reads as clean"
		return 1
	}
}

# ---- cycle state ---------------------------------------------------------

@test "cycle_started is false for a sha the machine never drove" {
	_load
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	run _stage_findings_cycle_started "$WORK" 9999abc
	[ "$status" -ne 0 ]
}

@test "cycle_started is true once a state file exists" {
	_load
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	printf '{}\n' >"$WORK/.claude/.session-state/ship-cycle/9999abc.json"
	run _stage_findings_cycle_started "$WORK" 9999abc
	[ "$status" -eq 0 ]
}

@test "cycle_in_use distinguishes 'machine not running here' from 'sha unlogged'" {
	# This keeps the refusal proportionate. A repo that never adopted the
	# cycle has no state dir, and refusing there would block legitimate
	# recording for a machine that is not running — the kind of gate people
	# bypass on reflex and then trust from nobody.
	_load
	run _stage_findings_cycle_in_use "$WORK"
	[ "$status" -ne 0 ] || {
		echo "a repo with no ship-cycle dir reported the machine in use"
		return 1
	}
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	run _stage_findings_cycle_in_use "$WORK"
	[ "$status" -eq 0 ] || {
		echo "a repo WITH the ship-cycle dir did not report the machine in use"
		return 1
	}
}
