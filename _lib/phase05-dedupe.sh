#!/bin/bash
# auto-register: false
set -u
# v4.28-W5 (#827) — shared 2-stage dedup wiring for Phase 0.5 prefilters.
#
# Sourced from phase0.5-{copilot,codex,gemini}-prefilter.sh to dedupe the
# 3-way duplication that landed in #817 + #823. The lib exposes:
#
#   phase05_preflight_audit_dedup_hook
#     Resolves AUDIT_DEDUP_HOOK script-relative + fails loud (exit 1) if
#     the helper is missing or non-executable. Run at TRUE preflight,
#     BEFORE invoking any CLI agent — without that order, a missing
#     hook is only detected at end-of-run AFTER spending CLI quota.
#
#   phase05_emit_findings TOTAL ALL_FINDINGS DEDUP_HOOK
#     Final emit stage. Pipes ALL_FINDINGS through phase1-dedup.sh
#     (cross-agent overlap) → phase0.5-dedupe-against-audit.sh (audit-log
#     suppression #817). On TOTAL=0, emits `[]`. Caller SHOULD have run
#     preflight first so a missing audit-dedup hook fails-loud BEFORE
#     spending CLI quota (PHASE05_AUDIT_DEDUP_HOOK is set at source-time,
#     not by preflight — preflight only validates executability).

# Resolve the audit-dedup hook path relative to THIS lib file (which
# lives at .claude/_lib/, so siblings are at .claude/hooks/).
_phase05_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PHASE05_AUDIT_DEDUP_HOOK="$_phase05_lib_dir/../hooks/phase0.5-dedupe-against-audit.sh"
unset _phase05_lib_dir

# Preflight check — exit 1 with diagnostic if hook missing/non-exec.
phase05_preflight_audit_dedup_hook() {
	[ -x "$PHASE05_AUDIT_DEDUP_HOOK" ] || {
		echo "phase0.5: audit-dedup hook not executable or missing: $PHASE05_AUDIT_DEDUP_HOOK" >&2
		exit 1
	}
}

# Final-stage emit. Args:
#   $1 = TOTAL (integer count of findings to dedup)
#   $2 = ALL_FINDINGS (JSON array string)
#   $3 = DEDUP_HOOK path (caller's existing phase1-dedup.sh resolution)
phase05_emit_findings() {
	local total="$1" all_findings="$2" dedup_hook="$3"
	# CR-CLI Phase 2 r2: validate dedup_hook before piping — fail loud
	# (rc=1) instead of letting bash emit a less-curated "permission
	# denied" / "command not found" mid-pipeline. Mirrors the
	# phase05_preflight_audit_dedup_hook contract for symmetry.
	if [ ! -x "$dedup_hook" ]; then
		echo "phase0.5: dedup-hook arg not executable or missing: $dedup_hook" >&2
		return 1
	fi
	if [ "$total" -gt 0 ]; then
		echo "$all_findings" | "$dedup_hook" | "$PHASE05_AUDIT_DEDUP_HOOK"
	else
		echo "[]"
	fi
}

# Absent-CLI graceful skip (#2259, CR r2 dedup): shared by the codex +
# gemini prefilters (copilot has its own resolver-aware variant). Logs a
# cli-tagged skipped-* entry, emits [], exits 0. The skip itself must
# stay exit-0 (optional pre-filter), but a failed skip-log write WARNs
# loudly - the scaler then treats the sha as no-prefilter-signal, which
# is the safe direction (more review rounds, not fewer).
# Args: $1=cli name  $2=LOG path  $3=status string  $4=install hint
# (the log dir is derived from the LOG path - single source of truth)
phase05_emit_skip_and_exit() {
	local _cli="$1" _log="$2" _status="$3" _hint="$4" _skip_sha _log_dir
	_log_dir=$(dirname "$_log")
	echo "phase0.5-${_cli}: ${_cli} CLI absent - skipping optional pre-filter; Phase 1 Claude agents proceed. ${_hint}" >&2
	_skip_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
	if [ -z "$_skip_sha" ]; then
		echo "phase0.5-${_cli}: WARN - could not resolve HEAD sha; skip entry will not match the scaler's HEAD-scoped lookup" >&2
	fi
	mkdir -p "$_log_dir" 2>/dev/null || true
	if ! jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$_skip_sha" --arg cli "$_cli" --arg st "$_status" \
		'{ts:$ts, sha:$sha, phase:"0.5", cli:$cli, agent:"<all>", findings:0, status:$st}' \
		>>"$_log" 2>/dev/null; then
		echo "phase0.5-${_cli}: WARN - could not append skip entry to ${_log}; the scaler will treat this sha as no-prefilter-signal" >&2
	fi
	echo "[]"
	exit 0
}
