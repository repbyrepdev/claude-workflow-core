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

# (#2563 p1r1) One row writer for the per-agent audit log. $6 cli is ""
# for copilot's historically untagged rows; codex/gemini pass their tag
# and get the cli: field in its historical position. partial: is only
# meaningful on ok rows (a salvaged/lossy count must never read as a
# clean parse), so it is attached there and omitted elsewhere.
_phase05_log_row() { # $1=ts $2=sha $3=agent $4=findings $5=status $6=cli $7=log $8=partial
	jq -nc --arg ts "$1" --arg sha "$2" --arg agent "$3" --argjson n "$4" \
		--arg st "$5" --arg cli "$6" --argjson p "${8:-false}" \
		'{ts:$ts, sha:$sha, phase:"0.5"}
		 + (if $cli != "" then {cli:$cli} else {} end)
		 + {agent:$agent, findings:$n, status:$st}
		 + (if $st == "ok" then {partial:$p} else {} end)' >>"$7"
}

# (#2563 p1r1) Shared parse → salvage → stamp → count → log for ONE
# agent's raw model output. The whole #2563 hardening lives HERE so the
# three prefilters (copilot/codex/gemini) cannot diverge — the original
# fix landed copilot-only and round 1 caught codex/gemini still carrying
# every defect it closed (3 agents converged on this).
#
#   phase05_parse_and_log_findings RAW AGENT TS SHA LOG CLI
#
# stdout: the cleaned findings array — objects only, .agent stamped
#   UNCONDITIONALLY (the producer KNOWS which agent it invoked; a model
#   echoing someone else's name is exactly the untrusted echo the stamp
#   exists to override).
# rc 0: array emitted; an ok row was logged (partial:true when a prose
#   wrapper was salvaged or non-object garbage was dropped — both warned).
# rc 1: no array recoverable (non-array-output row logged) — caller
#   `continue`s to the next agent.
phase05_parse_and_log_findings() {
	local raw="$1" agent="$2" ts="$3" sha="$4" log="$5" cli="${6:-}"
	local cleaned _partial=false _salvage _pre_len count
	# Strip fenced code block markers + leading/trailing whitespace.
	cleaned=$(printf '%s' "$raw" | sed -E 's/^```(json)?//' | sed -E 's/```$//' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
	# Preamble/trailer salvage: prose-wrapped arrays used to be discarded
	# as non-array-output with findings:0 — a paid-for review reporting
	# success-shaped zero (the #2544 laundering class, living in 0.5).
	# Extract the first-[ .. last-] span and validate it.
	if ! printf '%s' "$cleaned" | jq -e 'type == "array"' >/dev/null 2>&1; then
		case "$raw" in
		*\[*\]*)
			_salvage="[${raw#*\[}"
			_salvage="${_salvage%\]*}]"
			if printf '%s' "$_salvage" | jq -e 'type == "array"' >/dev/null 2>&1; then
				cleaned="$_salvage"
				_partial=true
				echo "phase0.5: salvaged a JSON array wrapped in prose for agent=$agent — logging partial:true" >&2
			fi
			;;
		esac
	fi
	if ! printf '%s' "$cleaned" | jq -e 'type == "array"' >/dev/null 2>&1; then
		# No array anywhere in the output (refusal, pure prose).
		_phase05_log_row "$ts" "$sha" "$agent" 0 non-array-output "$cli" "$log"
		return 1
	fi
	_pre_len=$(printf '%s' "$cleaned" | jq 'length')
	# Defense-in-depth: this jq cannot fail on a validated array in normal
	# operation, but jq itself can die for environmental reasons (OOM,
	# signal) — fold that into the loud non-array path, never a crash.
	if ! cleaned=$(printf '%s' "$cleaned" | jq -c --arg a "$agent" '[.[] | select(type == "object") | .agent = $a]'); then
		echo "phase0.5: agent-stamp normalization failed for agent=$agent — treating as non-array output" >&2
		_phase05_log_row "$ts" "$sha" "$agent" 0 non-array-output "$cli" "$log"
		return 1
	fi
	count=$(printf '%s' "$cleaned" | jq 'length')
	# Non-object elements are schema garbage (no file/line/description to
	# act on) — dropped by the stamp filter, but never silently.
	if [ "$count" -ne "$_pre_len" ]; then
		echo "phase0.5: dropped $((_pre_len - count)) non-object element(s) from agent=$agent output — logging partial:true" >&2
		_partial=true
	fi
	_phase05_log_row "$ts" "$sha" "$agent" "$count" ok "$cli" "$log" "$_partial"
	printf '%s' "$cleaned"
}

# (#2563 p1r1) phase05_emit_findings + the documented-exit-code wrap.
# Any dedup/emit failure collapses to rc 1 with an errored-emit audit row
# — never a leaked jq rc through pipefail, and [] on stdout can never
# read as "clean" for a crashed round. Callers: `... || exit 1`.
#
#   phase05_emit_findings_logged TOTAL ALL_FINDINGS DEDUP_HOOK LOG SHA TS
phase05_emit_findings_logged() {
	local total="$1" all="$2" hook="$3" log="$4" sha="$5" ts="$6" _rc=0
	phase05_emit_findings "$total" "$all" "$hook" || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		echo "phase0.5: findings emit/dedup pipeline failed (rc=$_rc) — this round's findings were NOT emitted" >&2
		jq -nc --arg ts "$ts" --arg sha "$sha" --argjson rc "$_rc" --argjson n "$total" \
			'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:$n, status:"errored-emit", emit_rc:$rc}' \
			>>"$log"
		return 1
	fi
	# (#2563 p2r1) TERMINAL success record. Per-agent ok rows are written
	# BEFORE emission, so they alone must not prove the run: a crashed
	# emit leaves ok rows behind and the run-proof gates would unlock
	# downstream on a round whose findings were never emitted. The gates
	# key on THIS row (status:"emitted") or a run-level skipped-* row —
	# both are written only at a genuine terminal.
	jq -nc --arg ts "$ts" --arg sha "$sha" --argjson n "$total" \
		'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:$n, status:"emitted"}' \
		>>"$log" || {
		echo "phase0.5: WARN — could not append the terminal emitted row to $log; the run-proof gates will treat this sha as no-run" >&2
		return 1
	}
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
