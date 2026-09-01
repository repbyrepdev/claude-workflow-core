#!/usr/bin/env bats
# covers: _lib/stage-findings.sh
#
# (#2643) The guard that would have caught a real, expensive mistake.
#
# 42 phase0.5 findings across three shas were recorded as `--source issue`.
# The work was genuinely done and committed; the label was wrong. The
# graduation gate counts only `source == "phase0.5"`, so it reported
# 0/17, 0/13, 0/12 — and because `covered_sha` is stamped from HEAD there
# was no way to correct the records afterwards. The only exits left were a
# bypass or re-running three rounds of review.
#
# Nothing nudged at record time. These tests pin the checks that now do.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$REPO_ROOT/_lib/stage-findings.sh"
	[ -r "$LIB" ] || skip "library not found at $LIB"
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

@test "phase0.5 findings at a sha are counted" {
	_load
	printf '{"sha":"aaaa111","findings":12}\n' >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 aaaa111
	[ "$output" = "12" ] || {
		echo "expected 12, got '$output'"
		return 1
	}
}

@test "a later CLEAN round does not erase an earlier round's findings" {
	# Rounds append. If the last row for a sha is `findings: 0`, that means
	# "this round found nothing", NOT "this sha has nothing outstanding".
	# Taking the last row would silently mark a sha covered.
	_load
	{
		printf '{"sha":"bbbb222","findings":17}\n'
		printf '{"sha":"bbbb222","findings":0}\n'
	} >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 bbbb222
	[ "$output" = "17" ] || {
		echo "a clean round erased the earlier findings: got '$output', expected 17"
		return 1
	}
}

@test "a sha with no rows counts zero" {
	_load
	printf '{"sha":"aaaa111","findings":12}\n' >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_count "$WORK" phase0.5 cccc333
	[ "$output" = "0" ] || {
		echo "expected 0 for an unrelated sha, got '$output'"
		return 1
	}
}

@test "a missing log counts zero rather than failing the caller" {
	_load
	run _stage_findings_count "$WORK" cr dddd444
	[ "$status" -eq 0 ] || {
		echo "a missing log failed the caller (status $status)"
		return 1
	}
	[ "$output" = "0" ]
}

@test "phase1 counts finding ROWS in the per-sha review log" {
	_load
	{
		printf '{"finding_id":"a"}\n'
		printf '{"finding_id":"b"}\n'
		printf '{"note":"not a finding"}\n'
	} >"$WORK/.claude/review-log/eeee555.jsonl"
	run _stage_findings_count "$WORK" phase1 eeee555
	[ "$output" = "2" ] || {
		echo "expected 2 finding rows, got '$output'"
		return 1
	}
}

@test "stages_at names every stage with findings at that sha" {
	_load
	printf '{"sha":"ffff666","findings":3}\n' >"$WORK/.claude/logs/phase0.5-run.jsonl"
	printf '{"sha":"ffff666","findings":5}\n' >"$WORK/.claude/logs/cr-local-review.jsonl"
	run _stage_findings_stages_at "$WORK" ffff666
	[[ $output == *phase0.5* ]] || {
		echo "phase0.5 missing: $output"
		return 1
	}
	[[ $output == *cr* ]] || {
		echo "cr missing: $output"
		return 1
	}
}

@test "stages_at is EMPTY when no stage logged findings" {
	# The load-bearing negative: if this returned a stage spuriously, the
	# caller's mismatch refusal would fire on every record.
	_load
	printf '{"sha":"ffff666","findings":0}\n' >"$WORK/.claude/logs/phase0.5-run.jsonl"
	run _stage_findings_stages_at "$WORK" ffff666
	[ -z "$output" ] || {
		echo "expected no stages, got: $output"
		return 1
	}
}

@test "cycle_started is false for a sha the machine never drove" {
	_load
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	run _stage_findings_cycle_started "$WORK" 9999abc
	[ "$status" -ne 0 ] || {
		echo "a sha with no state file reported as started"
		return 1
	}
}

@test "cycle_started is true once a state file exists" {
	_load
	mkdir -p "$WORK/.claude/.session-state/ship-cycle"
	printf '{}\n' >"$WORK/.claude/.session-state/ship-cycle/9999abc.json"
	run _stage_findings_cycle_started "$WORK" 9999abc
	[ "$status" -eq 0 ] || {
		echo "an existing state file did not report as started"
		return 1
	}
}

@test "cycle_in_use distinguishes 'machine not running here' from 'sha unlogged'" {
	# This is what keeps the refusal proportionate. A repo that never
	# adopted the cycle has no state dir, and refusing there would block
	# legitimate recording for a machine that is not running — the kind of
	# gate people bypass on reflex.
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
