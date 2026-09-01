#!/bin/bash
# set-u: opt-out — SOURCED library; an option set here leaks into every
# caller and changes how the rest of THEIR script behaves. Every expansion
# below is individually guarded (`${1:-}` style), so the file does not need
# it; owning shell options is the caller's business. Same contract as the
# sibling _lib/bats-scope.sh.
#
# (#2643) SSOT for "which review stage produced findings at sha S?"
#
# WHY THIS EXISTS. `record-fix --source X` took X on trust. Nothing compared
# it against the stage that actually produced the findings being covered, so
# 42 phase0.5 findings across three shas were recorded as `--source issue`,
# and the phase0.5 graduation gate — which counts only `source == "phase0.5"`
# — correctly reported 0/17, 0/13, 0/12 while every one of those findings had
# in fact been fixed and committed. The evidence was real, the label was
# wrong, and because `covered_sha` is stamped from HEAD there was no way to
# correct it afterwards: the only exits were a skip or re-running the review.
#
# A self-declared, unvalidated source field is exactly the free-text claim
# the prove-yourself rule exists to remove — sitting in the one field that
# decides whether the evidence counts at all.
#
# ---------------------------------------------------------------------------
# THE FIRST VERSION OF THIS FILE INVENTED ITS OWN SCHEMAS AND WAS DEAD ON
# TWO OF THREE STAGES. Phase 1 caught it; recording it here because the
# failure mode is the one this whole epic is about — a gate that reports
# enforcement it does not perform.
#
#   phase1: counted rows with `.finding_id`/`.id`. hooks/review-log.sh is the
#           sole writer and emits {ts,sha,phase,round,agent,findings,...}.
#           Zero of the repo's real rows carry either key, so the arm
#           returned 0 for every sha — and on a sha carrying both phase0.5
#           and phase1 rows it told the operator to relabel a CORRECT
#           `--source phase1` record. The unit test pinned the invented
#           shape, so the suite stayed green over a guard that never fired.
#   cr:     compared FULL shas; cr-local-review.jsonl stores 7-char shas, so
#           that arm never matched either.
#   p0.5:   took `max` over a sha's rows — the algorithm
#           scripts/ship-pr-cycle.sh::_phase05_findings_for_sha documents as
#           MEASURED wrong "by up to 4x and wrong in both directions",
#           because per-agent rows are written BEFORE emission and survive a
#           crashed emit.
#
# So: this file no longer invents anything. Each arm mirrors the semantics
# of the gate that already owns that stage, and the docblock names it.
# ---------------------------------------------------------------------------
#
# A jq failure is NEVER coerced to 0. `_phase05_findings_for_sha` states the
# reason directly — coercing shrinks the bar, so an unreadable log would read
# as "nothing to cover". These functions echo `unknown` and return 2, and the
# caller must fail closed rather than treat it as clean.

# _stage_findings_log_usable <log>
# rc 0 when the file is empty, or has at least one line that parses as JSON.
# rc 1 when it has content and NOTHING parses — i.e. it is not a JSONL log.
#
# The distinction matters and cost a test to find. The phase0.5 reader uses
# `fromjson?`, which SILENTLY SKIPS unparseable lines — correct for one bad
# line among good ones, but it means a wholly corrupt log yields no rows and
# reads as "this sha has no findings". Zero and unreadable must not be the
# same answer here; zero opens a gate.
_stage_findings_log_usable() {
	local log="${1:-}" total ok
	[ -n "$log" ] && [ -r "$log" ] || return 0
	total=$(grep -c '[^[:space:]]' "$log" 2>/dev/null) || total=0
	[ "${total:-0}" -gt 0 ] 2>/dev/null || return 0
	ok=$(jq -r -R 'fromjson? | "x"' "$log" 2>/dev/null | grep -c x) || ok=0
	[ "${ok:-0}" -gt 0 ] 2>/dev/null
}

# _stage_findings_count <repo_root> <stage> <sha>
# Echoes a count, or `unknown` (rc 2) when the answer cannot be determined.
# rc 0 with a number = a real answer. rc 0 with 0 = genuinely no findings.
_stage_findings_count() {
	local root="${1:-}" stage="${2:-}" sha="${3:-}" log n short jq_err jq_rc=0
	if [ -z "$root" ] || [ -z "$stage" ] || [ -z "$sha" ]; then
		printf 'unknown\n'
		return 2
	fi
	if ! command -v jq >/dev/null 2>&1; then
		printf 'unknown\n'
		return 2
	fi

	case "$stage" in
	phase0.5)
		# AUTHORITY: scripts/ship-pr-cycle.sh::_phase05_findings_for_sha.
		# The terminal aggregate {agent:"<all>", status:"emitted"} is the
		# only trustworthy row; per-agent rows are written before emission
		# and summing them counts findings that were never emitted.
		# Newest aggregate wins — re-running the prefilter appends another.
		log="$root/.claude/logs/phase0.5-run.jsonl"
		[ -r "$log" ] || {
			printf '0\n'
			return 0
		}
		_stage_findings_log_usable "$log" || {
			printf 'unknown\n'
			return 2
		}
		jq_err=$(mktemp -t sf-p05.XXXXXX) || jq_err=""
		n=$(jq -r -R --arg s "$sha" \
			'fromjson? | select(.sha == $s and .agent == "<all>" and .status == "emitted") | .findings // 0' \
			"$log" 2>"${jq_err:-/dev/null}" | tail -1) || jq_rc=$?
		[ -n "$jq_err" ] && rm -f "$jq_err"
		if [ "$jq_rc" -ne 0 ]; then
			printf 'unknown\n'
			return 2
		fi
		# A sha with rows but no terminal aggregate is not a zero — the
		# prefilter may have crashed mid-emit. Say so.
		if [ -z "$n" ]; then
			local any
			any=$(jq -r -R --arg s "$sha" 'fromjson? | select(.sha == $s) | .sha' \
				"$log" 2>/dev/null | head -1) || any=""
			if [ -n "$any" ]; then
				printf 'unknown\n'
				return 2
			fi
			printf '0\n'
			return 0
		fi
		;;
	phase1)
		# AUTHORITY: pre-commit-hooks/prove-yourself-gate.sh — sum
		# `.findings` across the agents of the LATEST round, not a row
		# count. hooks/review-log.sh writes one aggregate row per agent.
		log="$root/.claude/review-log/$sha.jsonl"
		[ -r "$log" ] || {
			printf '0\n'
			return 0
		}
		_stage_findings_log_usable "$log" || {
			printf 'unknown\n'
			return 2
		}
		local latest
		latest=$(jq -r 'select(.phase==1 and .round!=null) | .round' "$log" 2>/dev/null |
			sort -un | tail -1) || latest=""
		if [ -z "$latest" ]; then
			printf '0\n'
			return 0
		fi
		n=$(jq -r --arg r "$latest" \
			'select(.phase==1 and (.round|tostring)==$r) | (.findings // 0)' \
			"$log" 2>/dev/null | awk '{s+=$1} END {print s+0}') || n=""
		[ -n "$n" ] || {
			printf 'unknown\n'
			return 2
		}
		;;
	cr)
		# AUTHORITY: _lib/cr-phase2-coverage.sh. Two things this arm got
		# wrong on the first pass: the log stores SHORT (7-char) shas, and
		# a PARTIAL/TIMED-OUT run reports "0 findings SEEN", not "0 exist"
		# — reading that as clean is the #2544 laundering.
		log="$root/.claude/logs/cr-local-review.jsonl"
		[ -r "$log" ] || {
			printf '0\n'
			return 0
		}
		_stage_findings_log_usable "$log" || {
			printf 'unknown\n'
			return 2
		}
		short=$(printf '%s' "$sha" | cut -c1-7)
		n=$(jq -rs --arg s "$short" '
			[ .[]
			  | select((.sha // "") == $s)
			  | select((.partial // false) != true and (.timeout // false) != true)
			  | (.findings // 0) ]
			| last // 0
		' "$log" 2>/dev/null) || n=""
		[ -n "$n" ] || {
			printf 'unknown\n'
			return 2
		}
		;;
	*)
		printf 'unknown\n'
		return 2
		;;
	esac

	case "$n" in
	'' | *[!0-9]*)
		printf 'unknown\n'
		return 2
		;;
	esac
	printf '%s\n' "$n"
	return 0
}

# _stage_findings_stages_at <repo_root> <sha>
# Echoes, newline-separated, every stage that logged >0 findings at that sha.
# rc 2 if ANY stage could not be determined — the caller must not treat a
# partial answer as "no stage claims findings here".
_stage_findings_stages_at() {
	local root="${1:-}" sha="${2:-}" st n rc=0
	for st in phase0.5 phase1 cr; do
		n=$(_stage_findings_count "$root" "$st" "$sha") || rc=2
		case "$n" in
		unknown) rc=2 ;;
		*)
			if [ "$n" -gt 0 ] 2>/dev/null; then
				printf '%s\n' "$st"
			fi
			;;
		esac
	done
	return "$rc"
}

# _stage_findings_cycle_started <repo_root> <sha>
# True (rc 0) when a ship-cycle state file exists for this sha.
#
# This is the check that actually catches the failure. Phase evidence
# recorded on a branch the state machine has never driven is the condition
# under which every stage log is empty — so the source comparison above
# cannot fire, and a hand-run phase produces records nothing will ever
# reconcile. The phases were run by hand; the machine was invoked only at
# the end; by then the labels were already wrong and unfixable.
_stage_findings_cycle_started() {
	local root="${1:-}" sha="${2:-}"
	if [ -z "$root" ] || [ -z "$sha" ]; then
		return 1
	fi
	[ -f "$root/.claude/.session-state/ship-cycle/$sha.json" ]
}

# _stage_findings_cycle_in_use <repo_root>
# True when this repo actually drives the ship-cycle state machine, i.e. the
# state directory exists at all.
#
# The "no cycle state for this sha" refusal is only meaningful where the
# machine is in play. A scratch fixture, a consumer repo that never adopted
# the cycle, or a fresh clone has no state dir — refusing there would block
# legitimate recording for a machine that is not running, which is the kind
# of gate that gets bypassed on reflex and then trusted by nobody. Where the
# dir DOES exist, a sha with no state means a phase was run by hand around
# the machine, which is the case worth refusing.
_stage_findings_cycle_in_use() {
	local root="${1:-}"
	[ -n "$root" ] || return 1
	[ -d "$root/.claude/.session-state/ship-cycle" ]
}
