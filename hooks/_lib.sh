#!/bin/bash
# Shared hook library — used by all .claude/hooks/*.sh and skills that
# need lightweight telemetry. Source from hooks like:
#   source "$(dirname "$0")/_lib.sh"
#   hook_log_run "$0" "$?" "$start_ts"
#
# Part of v3.19 meta-learning infrastructure (#233, #234).

HOOK_RUNS_LOG="${HOOK_RUNS_LOG:-.claude/hook-runs.jsonl}"
SKILL_USES_LOG="${SKILL_USES_LOG:-.claude/skill-uses.jsonl}"

# hook_log_run <hook_path> <exit_code> <start_epoch>
hook_log_run() {
	local hook_path="$1"
	local exit_code="$2"
	local start="$3"
	local end
	end=$(date +%s)
	local duration=$((end - start))
	mkdir -p "$(dirname "$HOOK_RUNS_LOG")" 2>/dev/null
	jq -nc \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg hook "$(basename "$hook_path")" \
		--argjson exit "$exit_code" \
		--argjson s "$duration" \
		'{timestamp: $ts, hook: $hook, exit: $exit, duration_s: $s}' >>"$HOOK_RUNS_LOG" 2>/dev/null
}

# v4.26 (#626): SSOT reader for the .claude/.session-state/current-pr.txt
# `key=value` cache file. Three hooks (persist, restore, pre-compact-flush)
# parse the same KV format — previously each ran its own ad-hoc awk inline,
# violating CLAUDE.md's SSOT-first rule. Now they all call this helper.
#
# session_state_read <key> [<state-dir>]
#   key       — pr | branch | ts
#   state-dir — defaults to .claude/.session-state relative to cwd
# Echoes the value (empty string if file/key missing); always exits 0.
session_state_read() {
	local key="$1"
	local state_dir="${2:-.claude/.session-state}"
	local file="$state_dir/current-pr.txt"
	[ -f "$file" ] || {
		echo ""
		return 0
	}
	# `$1 == k { print $2 }` would truncate values containing `=` (git
	# allows `=` in branch names). Match the key prefix, then emit the
	# remainder of the line after the FIRST `=` so multi-`=` values
	# round-trip intact.
	awk -v k="$key" 'BEGIN{p=k"="} index($0, p) == 1 { print substr($0, length(p)+1); exit }' "$file" 2>/dev/null || true
}

# skill_log_use <skill_name> <trigger_phrase> <source(natural|slash|auto)>
skill_log_use() {
	local skill="$1"
	local trigger="${2:-}"
	local source="${3:-natural}"
	mkdir -p "$(dirname "$SKILL_USES_LOG")" 2>/dev/null
	jq -nc \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg skill "$skill" \
		--arg trigger "$trigger" \
		--arg source "$source" \
		'{timestamp: $ts, skill: $skill, trigger: $trigger, source: $source}' >>"$SKILL_USES_LOG" 2>/dev/null
}
