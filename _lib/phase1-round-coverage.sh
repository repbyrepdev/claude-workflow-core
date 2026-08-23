#!/usr/bin/env bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`. -e/-o pipefail would mutate the CALLERS' errexit (this is sourced
# into ship-pr-cycle.sh, already -euo pipefail). Matches the sourced-lib
# convention of _lib/cr-phase2-coverage.sh.
#
# v0.34.123 (#2535): SSOT for "has phase 1 produced findings on this sha that
# are not yet applied (or rejected with evidence)?"
#
# WHY THIS EXISTS — the re-arm deadlock:
#   `ship-pr-cycle.sh next` at the phase1 stage re-wrote the phase1-directive
#   marker on EVERY invocation while clean_streak < cap. The marker makes
#   hooks/phase1-directive-pending-guard.sh deny Edit/Write. So once a round
#   returned findings, applying them required Edit, the marker blocked Edit, and
#   the marker only cleared on round-complete or a stage transition — both of
#   which need the fixes already applied. Circular.
#
# phase1_round_has_unapplied_findings <sha> <expected_agents>
#   rc 0 = YES — findings exist on this sha and coverage is short. Caller should
#          SUPPRESS the re-arm so Edit is possible.
#   rc 1 = NO  — no findings, fully covered, round still in flight, or the
#          verdict cannot be determined.
#
# FAIL-CLOSED means rc 1. Re-arming is the status quo that keeps the guard
# strict, so every unresolvable case returns 1 and the caller re-arms exactly as
# before. Suppression requires POSITIVE evidence; it is never the fallback.

# --- private primitives ----------------------------------------------------
# Both public functions below need the SAME two queries. They were duplicated
# once (four jq programs, two of them byte-identical), which is how the
# scope bug below survived a fix in one copy — extract so a fix lands once.
# Each primitive is pure: it reports data or fails, and every rc POLICY decision
# stays in the callers, which is what keeps the two behaviours distinct.

# _p1rc_rounds <rlog> → "<latest_round>\t<latest_findings>\t<latest_agents>\t<all_rounds_findings>"
# rc 1 on jq failure or no phase-1 rows.
#
# `.round != null` is load-bearing: the same JSONL also holds phase2 rows and
# `accept-with-reason` rows, which are phase==1 but round-less and would
# otherwise poison the grouping.
_p1rc_rounds() {
	local rlog=$1 row rc=0
	row=$(jq -rs '
		[ .[] | select(.phase == 1 and .round != null and (.findings // null) != null) ]
		| if length == 0 then "" else
			( max_by(.round) | .round ) as $r
			| ( [ .[] | select(.round == $r) ] ) as $latest
			| [ ($r | tostring),
			    ([ $latest[].findings ] | add | tostring),
			    ([ $latest[].agent ] | unique | length | tostring),
			    ([ .[].findings ] | add | tostring) ]
			| @tsv
		  end
	' "$rlog" 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	[ -n "$row" ] || return 1
	printf '%s' "$row"
}

# _p1rc_covered <audit_log> <short_sha> → integer. rc 1 on jq failure.
# Caller decides what a MISSING log means (this returns rc 1 for that too, so a
# caller that wants "0" must say so explicitly).
_p1rc_covered() {
	local audit_log=$1 short_sha=$2 out rc=0
	[ -f "$audit_log" ] || return 1
	out=$(jq -rs --arg s "$short_sha" '
		[ .[] | select((.source // "phase1") == "phase1")
		      | select((.covered_sha // "") | startswith($s)) ]
		| map(.covers_count // 1) | add // 0
	' "$audit_log" 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	case "$out" in '' | *[!0-9]*) return 1 ;; esac
	printf '%s' "$out"
}

# --- public ----------------------------------------------------------------

phase1_round_has_unapplied_findings() {
	local sha=$1 expected_agents=${2:-0}
	# Fail CLOSED on an unresolvable repo root — never fall back to pwd, which
	# could point at an unrelated repo whose .claude/ happens to exist.
	local repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
	[ -n "$repo_root" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	[[ $expected_agents =~ ^[1-9][0-9]*$ ]] || return 1
	local rlog="$repo_root/.claude/review-log/$sha.jsonl"
	[ -f "$rlog" ] || return 1

	local row
	row=$(_p1rc_rounds "$rlog") || return 1
	local round latest_total agents all_total
	IFS=$'\t' read -r round latest_total agents all_total <<<"$row"
	case "$round$latest_total$agents$all_total" in '' | *[!0-9]*) return 1 ;; esac

	# Round still in flight → the marker is doing its job; re-arm.
	[ "$agents" -ge "$expected_agents" ] || return 1
	# Nothing found on this sha at all → let the normal convergence path run.
	[ "$all_total" -gt 0 ] || return 1

	# COMPARE CUMULATIVE TO CUMULATIVE (#2535 r1 — the bug this fix exists for).
	# The prove-yourself record carries no round discriminator (only source,
	# covered_sha and covers_count — see skills/prove-yourself-audit/run.sh), so
	# `covered` is inherently the sum across EVERY round on this sha. The first
	# version compared it against the LATEST round's findings alone, which made
	# the two sides describe different sets: round 1 with 10 findings fully
	# covered, then round 2 with 3 new findings, computed 10 < 3 = false → rc 1 →
	# re-arm, reproducing the exact deadlock this lib removes, from round 2
	# onward. Summing findings across all rounds puts both sides on the same
	# basis. (Scoping coverage per-round instead would need a round stamped on
	# the prove-yourself record at the writer — a larger change, tracked
	# separately; cumulative-vs-cumulative is correct today and strictly better
	# than the round-1-only behaviour it replaces.)
	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl"
	local covered
	if [ -f "$audit_log" ]; then
		covered=$(_p1rc_covered "$audit_log" "${sha:0:7}") || return 1
	else
		# findings>0 with no audit log at all ⇒ nothing can have been applied yet.
		# NOTE this is deliberately DIFFERENT from cr_phase2_clean_for_sha, which
		# hard-returns 1 on a missing audit log. Phase 2 is asking "may I advance?"
		# (fail-closed = don't advance); phase 1 here is asking "are findings
		# outstanding?" and a missing ledger is positive evidence that they are.
		# The two are not interchangeable — do not "align" them without re-reading
		# both call sites.
		covered=0
	fi

	[ "$covered" -lt "$all_total" ] && return 0
	return 1
}

# Human-readable one-line summary for the operator directive. Echoes
# "<round> <findings> <covered>" for the sha, or nothing when undeterminable.
#
# `findings` here is the SAME cumulative total the predicate compares against,
# so the operator's readout and the gate's decision can never disagree — an
# earlier version printed the latest round's count beside an all-rounds coverage
# sum, which could render nonsense like "round 4 / 3 findings / 21 covered".
phase1_round_coverage_summary() {
	local sha=$1
	local repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
	[ -n "$repo_root" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	local rlog="$repo_root/.claude/review-log/$sha.jsonl"
	[ -f "$rlog" ] || return 0
	local row
	row=$(_p1rc_rounds "$rlog") || return 0
	local round latest_total agents all_total
	IFS=$'\t' read -r round latest_total agents all_total <<<"$row"
	case "$round$all_total" in '' | *[!0-9]*) return 0 ;; esac

	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl" covered
	if ! covered=$(_p1rc_covered "$audit_log" "${sha:0:7}" 2>/dev/null); then
		# Do NOT report an unreadable ledger as the affirmative "0 covered" — that
		# renders to the operator as "none of your findings are covered", which is
		# a claim, not an absence of data.
		printf '%s %s unknown' "$round" "$all_total"
		return 0
	fi
	printf '%s %s %s' "$round" "$all_total" "$covered"
}
