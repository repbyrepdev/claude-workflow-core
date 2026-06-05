#!/bin/bash
# set-u: opt-out — sourced library; inherits the caller's set -u/-e options.
# auto-register: false
# v0.34.35 (#2240): canonical-review-EXCLUSION — review layers (phase1 agents,
# phase2 local CR-CLI) skip files byte-identical to the pinned plugin canonical.
#
# WHY: a consumer MIRRORS canonical plugin files (.claude/hooks, _lib, skills/
# ship-pr-cycle, .github hashed templates, .semgrep) so hash-drift --verify +
# refresh-from-source can enforce byte-identity. But those mirrors were already
# reviewed+merged UPSTREAM and are hash-drift-enforced byte-identical, so
# re-reviewing them in a consumer is the "verbatim treadmill" (media-server
# v0.8.8->v0.34.34: 24 phase2 findings, all on upstream-validated mirrors).
#
# NOT A BLIND SPOT: hash-drift --verify (pre-commit + CI) fails the build if any
# mirror drifts one byte from the pinned canonical, so a file proven byte-
# identical IS the already-reviewed upstream artifact. Same predicate as the
# pre-commit canonical-consumer-skip (#2235) — reused here so the GATES and the
# REVIEW layers agree on what "canonical" means.
#
# CR-in-CI is handled separately (glob path_filters in .coderabbit) — it can't
# express hash-equality; these helpers are the precise hash-based path for the
# LOCAL layers.

# Source the shared hash-equality predicate (the keystone from #2235).
_CRE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
if [ -n "$_CRE_DIR" ] && [ -r "$_CRE_DIR/canonical-consumer-skip.sh" ]; then
	# shellcheck source=./canonical-consumer-skip.sh
	. "$_CRE_DIR/canonical-consumer-skip.sh" || true
fi

# canonical_review_excluded <repo-relative-file>
#   rc 0  → EXCLUDE from review (consumer AND byte-identical to pinned canonical)
#   rc 1  → review it (plugin self / not canonical / modified / unresolvable)
# Fail-SAFE toward reviewing: if the predicate is unavailable, never exclude.
canonical_review_excluded() {
	[ -n "${1:-}" ] || return 1
	command -v canonical_consumer_skip >/dev/null 2>&1 || return 1
	canonical_consumer_skip "$1"
}

# canonical_review_noncanonical_changed <base>
#   Echoes (one per line) the files changed in <base>..HEAD that are NOT
#   canonical-excluded — i.e. the consumer-authored surface a reviewer should
#   actually look at.
#   rc 0 + empty output = `git diff` SUCCEEDED and the whole diff is canonical
#                         (or there are no changes) → review nothing.
#   rc 2                = `git diff` FAILED (e.g. <base> does not resolve in this
#                         consumer / CI checkout). Callers MUST treat this as
#                         "could not scope" and fall back to reviewing EVERYTHING
#                         — never as "nothing to review" (#2240 phase1 silent-
#                         failure-hunter). The diff is captured + rc-checked (not
#                         streamed via process substitution) precisely so the
#                         git failure is NOT swallowed into an empty result.
canonical_review_noncanonical_changed() {
	local base="${1:-main}" f _diff
	if ! _diff=$(git diff --name-only "$base"..HEAD 2>/dev/null); then
		# Surface WHY scoping failed (e.g. <base> unresolved) so a consumer that
		# unexpectedly reviews its full diff is debuggable; still return the
		# fail-safe rc 2 so the caller falls back to reviewing everything. (#2240
		# phase2 CR: don't swallow the failure reason entirely.)
		printf 'canonical_review_noncanonical_changed: git diff against base %q failed (ref unresolved?); caller falls back to full review\n' "$base" >&2
		return 2
	fi
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		canonical_review_excluded "$f" || printf '%s\n' "$f"
	done <<<"$_diff"
}

# canonical_review_phase2_filtered_count <cr-cli-output-file>
#   The phase2 hash-filter (#2249): count CR-CLI findings EXCLUDING those on
#   canonical-mirror files. Reads `{"type":"finding","fileName":...}` JSON lines
#   from <file>, drops each whose path is canonical_review_excluded (byte-
#   identical to the pinned canonical → already reviewed upstream + hash-drift-
#   enforced → the verbatim treadmill), and prints the count of the remainder.
#   This is the PRECISE local-layer exclusion the coarse .coderabbit globs can't
#   express (a glob can't tell a mirror from a consumer-authored file in a mixed
#   dir like .claude/hooks/). Fail-SAFE: if the hash predicate is unavailable,
#   nothing is excluded → the full count (never a false-clean). With NO finding
#   lines it falls back to the terminal `{"type":"complete",...,"findings":N}`
#   count (no per-file paths to filter); counting finding LINES also avoids the
#   CR-CLI complete-event over-count (#2240 saw findings:4 with 1 line emitted).
canonical_review_phase2_filtered_count() {
	local out="${1:-}" files f kept=0
	{ [ -n "$out" ] && [ -r "$out" ]; } || {
		printf '0'
		return 0
	}
	if ! command -v jq >/dev/null 2>&1; then
		grep -cE '"type"[[:space:]]*:[[:space:]]*"finding"' "$out" 2>/dev/null || printf '0'
		return 0
	fi
	files=$(jq -rs 'map(select(.type=="finding") | (.fileName // .file // empty)) | .[]' "$out" 2>/dev/null || true)
	if [ -z "$files" ]; then
		# No finding lines → use the complete event verbatim (no paths to filter).
		local c
		c=$(jq -rs 'map(select(.type=="complete")) | if length>0 then (.[-1].findings // 0) else 0 end' "$out" 2>/dev/null || true)
		case "${c:-}" in
		'' | *[!0-9]*) printf '0' ;;
		*) printf '%s' "$c" ;;
		esac
		return 0
	fi
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		canonical_review_excluded "$f" && continue
		kept=$((kept + 1))
	done <<<"$files"
	printf '%s' "$kept"
}
