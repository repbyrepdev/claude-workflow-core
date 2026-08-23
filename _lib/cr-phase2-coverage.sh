#!/usr/bin/env bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`. -e/-o pipefail would mutate the CALLERS' errexit (this is sourced
# into ship-pr-cycle.sh + the pre-push gate, both already -euo pipefail), and
# the functions here are explicitly fail-closed (every fallback is
# `|| echo <sentinel>` that the guards reject, plus explicit `return 0/1`).
# [#248 CR declined `set -euo pipefail` — sourced-lib convention.]
# v0.32.7 (#238): SSOT for "is this sha's Phase 2 CR-CLI review clean — or are
# all its findings ADDRESSED?". Sourced by BOTH:
#   - hooks/pre-push-pipeline-gate.sh  (the push gate)
#   - scripts/ship-pr-cycle.sh         (the Phase 2 round-cap advance decision)
# so the round-cap never advances to a push the gate will refuse, and the two
# never drift. Extracted verbatim from the gate's former `_cr_cli_clean_for_sha`
# (which was "local to this script") + made silent (callers emit their own
# messages) so it composes.
#
# cr_phase2_clean_for_sha <sha>
#   rc 0 = clean: latest CR-CLI run for the sha has findings=0, OR every finding
#                 is covered by source=cr prove-yourself records scoped to the
#                 sha (sum of .covers_count >= latest findings).
#   rc 1 = not clean / cannot determine.
# Fail-CLOSED: missing run-log, missing jq, non-numeric/absent findings, or
# missing audit log → rc 1 (never whitewash). REPO_ROOT honored if exported
# (tests pre-set it); else derived from git.

cr_phase2_clean_for_sha() {
	local sha=$1
	# #248 CR: fail CLOSED on an unresolvable repo root — do NOT fall back to
	# pwd (which could point at an unrelated repo whose .claude/logs happen to
	# exist, yielding a wrong clean/not-clean verdict).
	local repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
	[ -n "$repo_root" ] || return 1
	local cr_log="$repo_root/.claude/logs/cr-local-review.jsonl"
	[ -f "$cr_log" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local short_sha
	short_sha=$(printf '%s' "$sha" | cut -c1-7)
	local latest_findings
	# A PARTIAL / TIMED-OUT run is NOT evidence of a clean review (#2544).
	#
	# THE LAUNDERING THIS CLOSES: when the CR-CLI is killed before emitting a
	# single finding, local-review.sh logs `{"findings":0,"timeout":true,
	# "partial":true}` — truthfully reporting "0 findings were SEEN", not "0
	# findings EXIST". This predicate read only `.findings`, so `0` meant CLEAN,
	# and the pre-push gate then accepted a SHA whose local review never ran.
	# Observed live: PR #2540's f21b3d1 pushed on exactly such an entry, and the
	# operator was told the signal was clean.
	#
	# Mapping partial/timeout to -1 routes it through the existing non-numeric
	# rejection below — the same fail-closed exit as "no run at all", which is
	# precisely what a review that produced no verdict IS.
	#
	# This is UNCONDITIONAL: the mapping ignores `.findings` entirely, so
	# prove-yourself coverage can NOT clear a partial run even when findings
	# were salvaged and every one of them was addressed. That is deliberate —
	# covering the 3 findings CR happened to emit before the kill says nothing
	# about the rest of the diff it never read. The only thing that clears a
	# partial run is a subsequent COMPLETE run for the same SHA (see the
	# non-sticky note below).
	#
	# `!= false` rather than `== true` on purpose. local-review.sh writes real
	# JSON booleans (`--argjson partial true`), so `== true` matches today — but
	# a writer that ever emitted the string "true", or 1, would slip straight
	# past a strict equality test and re-open the exact laundering hole this
	# closes. Absent/null degrades to false via `//` and stays clean, and an
	# explicit `false` stays clean; anything else is treated as "flagged".
	# For a fail-closed gate, over-rejecting a malformed entry is the safe
	# direction — it costs a re-run, not a false green.
	latest_findings=$(jq -rs --arg s "$short_sha" \
		'[.[] | select(.sha==$s)]
		 | if length > 0 then
		     (last as $l
		      | if (($l.partial // false) != false) or (($l.timeout // false) != false)
		        then -1
		        else ($l.findings // -1) end)
		   else -1 end' \
		"$cr_log" 2>/dev/null || echo -1)
	# NON-STICKY, deliberately: `last` keys on the newest entry for the SHA
	# only. A partial run followed by a complete one reads CLEAN off the
	# complete entry. Making the rejection sticky would strand a branch whose
	# re-run genuinely succeeded, with no way to clear it short of a new
	# commit — the gate would stop being a signal and start being a wall.
	# Reject non-numeric / missing / negative BEFORE the coverage path. -1 means
	# "no CR-CLI run for this SHA" — fail-closed, never whitewashed by old audit.
	case "$latest_findings" in
	'' | *[!0-9]*) return 1 ;;
	esac
	if [ "$latest_findings" = "0" ]; then
		return 0
	fi
	# findings>0 → clean IFF every finding has a prove-yourself record scoped to
	# THIS sha (by .covered_sha prefix). Sum .covers_count (default 1 — #238
	# made the writer persist the real count so `--covers-count N` is honored).
	local audit_log="$repo_root/.claude/audit/prove-yourself.jsonl"
	[ -f "$audit_log" ] || return 1
	local cr_covered
	cr_covered=$(jq -rs --arg s "$short_sha" '
		[.[] | select(.source == "cr") | select((.covered_sha // "") | startswith($s))] |
		map(.covers_count // 1) | add // 0
	' "$audit_log" 2>/dev/null || echo 0)
	[ "${cr_covered:-0}" -ge "${latest_findings:-0}" ] && return 0
	return 1
}
