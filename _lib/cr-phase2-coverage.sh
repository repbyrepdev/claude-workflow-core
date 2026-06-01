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
	latest_findings=$(jq -rs --arg s "$short_sha" \
		'[.[] | select(.sha==$s)] | if length > 0 then (last.findings // -1) else -1 end' \
		"$cr_log" 2>/dev/null || echo -1)
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
