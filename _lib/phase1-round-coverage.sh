#!/usr/bin/env bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`. -e/-o pipefail would mutate the CALLERS' errexit (this is sourced
# into ship-pr-cycle.sh, already -euo pipefail). Mirrors the sourced-lib
# convention established by _lib/cr-phase2-coverage.sh.
#
# v0.34.122 (#2535): SSOT for "has the latest COMPLETE phase-1 round produced
# findings that are not yet applied (or rejected with evidence)?"
#
# WHY THIS EXISTS — the re-arm deadlock:
#   `ship-pr-cycle.sh next` at the phase1 stage re-writes the phase1-directive
#   marker on EVERY invocation while clean_streak < cap. The marker makes
#   hooks/phase1-directive-pending-guard.sh deny Edit/Write/commit. So once a
#   round returns findings, the operator must Edit to apply them — but the
#   marker blocks Edit, and the marker only clears on round-complete or a stage
#   transition, both of which need the fixes applied. Circular. The operator had
#   to `rm` the marker by hand 4x in one session.
#
#   The fix is at the RE-ARM SITE, not in the guard: while the prior round's
#   findings are still unapplied, `next` must not re-arm. The guard's round
#   check is deliberately left UNTOUCHED — weakening it was tried and it
#   un-gated rounds 2+, which is the failure mode this must not reproduce.
#
# phase1_round_has_unapplied_findings <sha> <expected_agents>
#   rc 0 = YES — the latest round is COMPLETE, produced findings, and coverage
#                is short. Caller should SUPPRESS the re-arm so Edit is possible.
#   rc 1 = NO  — no findings, fully covered, round still in flight, or the
#                verdict cannot be determined.
#
# FAIL-CLOSED means rc 1 here. Re-arming is the status quo that keeps the guard
# strict, so every unresolvable case (missing logs, missing jq, unparseable
# round, incomplete round) returns 1 and the caller re-arms exactly as before.
# Suppression requires POSITIVE evidence of a complete round with short
# coverage; it is never the fallback.

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

	# Latest round, its summed findings, and its DISTINCT agent count, in one
	# pass. `.round != null` is load-bearing: the same JSONL also holds phase2
	# rows and `accept-with-reason` rows which are phase==1 but round-less, and
	# they would otherwise poison the grouping.
	local row
	row=$(jq -rs '
		[ .[] | select(.phase == 1 and .round != null and (.findings // null) != null) ]
		| if length == 0 then "" else
			( max_by(.round) | .round ) as $r
			| [ .[] | select(.round == $r) ]
			| [ ($r | tostring),
			    ([ .[].findings ] | add | tostring),
			    ([ .[].agent ] | unique | length | tostring) ]
			| @tsv
		  end
	' "$rlog" 2>/dev/null) || return 1
	[ -n "$row" ] || return 1

	local round total agents
	IFS=$'\t' read -r round total agents <<<"$row"
	case "$round$total$agents" in '' | *[!0-9]*) return 1 ;; esac

	# Round still in flight → the marker is doing its job; re-arm.
	[ "$agents" -ge "$expected_agents" ] || return 1
	# Clean round → nothing to apply; let the normal convergence path run.
	[ "$total" -gt 0 ] || return 1

	# findings>0 on a complete round → unapplied IFF coverage is short. Coverage
	# is the sum of .covers_count over phase1-sourced prove-yourself records
	# scoped to THIS sha by .covered_sha prefix — the same shape
	# cr_phase2_clean_for_sha uses for phase 2, so the two cannot drift.
	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl"
	# No audit log at all + findings>0 ⇒ nothing can have been applied yet.
	local covered=0
	if [ -f "$audit_log" ]; then
		local short_sha
		short_sha=$(printf '%s' "$sha" | cut -c1-7)
		covered=$(jq -rs --arg s "$short_sha" '
			[ .[] | select((.source // "") == "phase1")
			      | select((.covered_sha // "") | startswith($s)) ]
			| map(.covers_count // 1) | add // 0
		' "$audit_log" 2>/dev/null) || return 1
		case "$covered" in '' | *[!0-9]*) return 1 ;; esac
	fi

	[ "$covered" -lt "$total" ] && return 0
	return 1
}

# Human-readable one-line summary for the operator directive. Echoes
# "<round> <findings> <covered>" for the latest round, or nothing when
# undeterminable. Kept separate so the predicate above stays side-effect-free.
phase1_round_coverage_summary() {
	local sha=$1
	local repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
	[ -n "$repo_root" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	local rlog="$repo_root/.claude/review-log/$sha.jsonl"
	[ -f "$rlog" ] || return 0
	local row
	row=$(jq -rs '
		[ .[] | select(.phase == 1 and .round != null and (.findings // null) != null) ]
		| if length == 0 then "" else
			( max_by(.round) | .round ) as $r
			| [ .[] | select(.round == $r) ]
			| [ ($r | tostring), ([ .[].findings ] | add | tostring) ] | @tsv
		  end
	' "$rlog" 2>/dev/null) || return 0
	[ -n "$row" ] || return 0
	local round total
	IFS=$'\t' read -r round total <<<"$row"
	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl" covered=0
	if [ -f "$audit_log" ]; then
		local short_sha
		short_sha=$(printf '%s' "$sha" | cut -c1-7)
		covered=$(jq -rs --arg s "$short_sha" '
			[ .[] | select((.source // "") == "phase1")
			      | select((.covered_sha // "") | startswith($s)) ]
			| map(.covers_count // 1) | add // 0
		' "$audit_log" 2>/dev/null) || covered=0
	fi
	printf '%s %s %s' "$round" "$total" "$covered"
}
