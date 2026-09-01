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
# The data needed to check it was already on disk, keyed by the SAME sha
# `covered_sha` stamps. This library reads it.
#
# Stage log locations (one place, so a new stage is added here, not in each
# consumer):
#   phase0.5 → .claude/logs/phase0.5-run.jsonl    {sha, findings}
#   phase1   → .claude/review-log/<sha>.jsonl     per-sha, one row per finding
#   cr       → .claude/logs/cr-local-review.jsonl {sha, findings}

# _stage_findings_count <repo_root> <stage> <sha>
# Echoes how many findings that stage logged at that sha; 0 when the log is
# absent, unreadable, or jq is missing. A 0 therefore means "no findings
# VISIBLE here", which is why the caller must also consult
# _stage_findings_cycle_started before treating silence as clean — the whole
# failure this file addresses came from empty logs, not from a wrong count.
_stage_findings_count() {
	local root="${1:-}" stage="${2:-}" sha="${3:-}" log n
	if [ -z "$root" ] || [ -z "$stage" ] || [ -z "$sha" ]; then
		printf '0\n'
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		printf '0\n'
		return 0
	fi
	case "$stage" in
	phase0.5) log="$root/.claude/logs/phase0.5-run.jsonl" ;;
	cr) log="$root/.claude/logs/cr-local-review.jsonl" ;;
	phase1) log="$root/.claude/review-log/$sha.jsonl" ;;
	*)
		printf '0\n'
		return 0
		;;
	esac
	if [ ! -r "$log" ]; then
		printf '0\n'
		return 0
	fi
	case "$stage" in
	phase1)
		# Per-sha file; each finding is a row.
		n=$(jq -rs '[ .[] | select(((.finding_id // .id // "") | tostring) != "") ] | length' \
			"$log" 2>/dev/null) || n=0
		;;
	*)
		# Shared log; take the LARGEST count recorded for this sha. Rounds
		# append, and a later clean round must not erase an earlier round's
		# findings — "0 findings this round" is not "0 findings on this sha".
		n=$(jq -rs --arg s "$sha" '
			[ .[] | select((.sha // "") == $s) | (.findings // 0) ] | max // 0
		' "$log" 2>/dev/null) || n=0
		;;
	esac
	case "$n" in
	'' | *[!0-9]*) n=0 ;;
	esac
	printf '%s\n' "$n"
}

# _stage_findings_stages_at <repo_root> <sha>
# Echoes, newline-separated, every stage that logged >0 findings at that sha.
# Empty output = no stage claims findings there.
_stage_findings_stages_at() {
	local root="${1:-}" sha="${2:-}" st n
	for st in phase0.5 phase1 cr; do
		n=$(_stage_findings_count "$root" "$st" "$sha")
		if [ "$n" -gt 0 ] 2>/dev/null; then
			printf '%s\n' "$st"
		fi
	done
	return 0
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
