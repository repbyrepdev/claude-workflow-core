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
	# #2250/#2329: the review layers review the COMMITTED state (phase1 agents
	# scope on `git diff <base>..HEAD`; phase2 CR-CLI reviews `-t committed`), so
	# exclude based on the COMMITTED blob — a committed-then-reverted mirror change
	# must stay reviewed (TOCTOU). Fall back to the working-tree predicate only if
	# the committed one is unavailable. The pre-commit GATES call
	# canonical_consumer_skip directly (staged content) and are unaffected.
	if command -v canonical_consumer_skip_committed >/dev/null 2>&1; then
		canonical_consumer_skip_committed "$1"
		return
	fi
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

# canonical_review_filtered_finding_count <cr-cli-output-file>
#   Count CR-CLI findings EXCLUDING those on canonical-mirror files (the #2249
#   review-exclusion at the phase2 layer). A finding on a file byte-identical to
#   the pinned canonical (canonical_review_excluded) is already-reviewed-upstream
#   + hash-drift-enforced — the "verbatim treadmill" — so it is dropped; every
#   other finding is COUNTED. This is the PRECISE exclusion the coarse .coderabbit
#   globs can't express for a MIXED dir (.claude/hooks/) where mirrors and
#   consumer-authored files coexist.
#
#   Robustness contract (#2249 phase1 silent-failure-hunter — a review-suppression
#   counter must NEVER under-report; a false-clean lets unreviewed consumer code
#   reach push):
#   - Finding lines are read TEXTUALLY (grep `"type":"finding"`), NOT via a whole-
#     stream `jq -rs` slurp: the CR-CLI output file (TEE_OUT) is `2>&1`-merged and
#     interleaves banner/progress/stderr noise, and one non-JSON line makes a bare
#     `-rs` slurp fail → empty → a silent 0 (the sibling rate-limit detector pre-
#     filters `^\{` for the same reason). Each finding line is itself one JSON
#     object, parsed on its own.
#   - A finding is KEPT unless it has a NON-EMPTY path AND that path is a proven
#     canonical mirror. Empty/absent path, jq missing, OR predicate unavailable
#     all fall through to KEEP — the fail-safe direction (count, never drop).
#   - With finding lines present the kept count is authoritative (all-canonical →
#     0). Counting finding LINES also avoids the CR-CLI complete-event over-count
#     (#2240 saw findings:4 with 1 line emitted).
#   - With NO finding lines, fall back to the terminal `{"type":"complete",...,
#     "findings":N}` event, `^\{`-prefiltered so the slurp can't choke on noise.
canonical_review_filtered_finding_count() {
	local out="${1:-}" line file kept=0 saw=0 _have_jq=0
	{ [ -n "$out" ] && [ -r "$out" ]; } || {
		printf '0'
		return 0
	}
	if command -v jq >/dev/null 2>&1; then
		_have_jq=1
	fi
	while IFS= read -r line; do
		saw=1
		file=""
		# Each finding line is a single JSON object → parse it alone (no whole-
		# stream slurp). jq missing / parse failure → file stays empty → KEEP.
		if [ "$_have_jq" -eq 1 ]; then
			file=$(printf '%s\n' "$line" | jq -r '(.fileName // .file // "")' 2>/dev/null || printf '')
		fi
		# Drop ONLY a proven canonical mirror; every other case is kept.
		if [ -n "$file" ] && canonical_review_excluded "$file"; then
			continue
		fi
		kept=$((kept + 1))
	done < <(grep -E '"type"[[:space:]]*:[[:space:]]*"finding"' "$out" 2>/dev/null)
	if [ "$saw" -eq 1 ]; then
		printf '%s' "$kept"
		return 0
	fi
	# No finding lines → terminal complete event (no per-file paths to filter).
	# Pre-filter to JSON-object lines so the slurp survives banner/stderr noise.
	local c=""
	if [ "$_have_jq" -eq 1 ]; then
		c=$(grep -E '^[[:space:]]*\{' "$out" 2>/dev/null | jq -rs 'map(select(.type=="complete")) | if length>0 then (.[-1].findings // 0) else 0 end' 2>/dev/null || printf '')
	fi
	case "${c:-}" in
	'' | *[!0-9]*) printf '0' ;;
	*) printf '%s' "$c" ;;
	esac
}
