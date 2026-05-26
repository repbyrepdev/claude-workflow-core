#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Monitor
# auto-register: true
#
# (#80) Block Monitor tool misuse for one-shot completion waits.
# The right tool for those is `Bash run_in_background` — the harness
# sends a single completion notification on bash exit, no orphan
# Monitor accumulation possible.
#
# BLOCKS: `until <cond>; do ...; sleep ...; done` shape (any condition,
# any body content as long as both `do` and `sleep` appear). This is
# the canonical one-shot polling form.
#
# PASSES: `tail -f`, `inotifywait -m`, `while true; do ...`, plain
# log-following — anything that doesn't have the `until ... done`
# shape. The `while [ ... ]; do sleep` variant is NOT covered here
# (less common in practice; can be added if observed — see follow-up
# discussion under #80/#92).
#
# BYPASS: MONITOR_MISUSE_SKIP=1 env. Audit-logged to
# .claude/logs/monitor-misuse-bypass.jsonl (timestamped, command-hashed
# — content not logged for privacy).
#
# THREAT MODEL: advisory ergonomic guard (same posture as #82). Agent
# has full command-string control and can syntactically evade
# (`\until`, eval-wrap, etc.). The hook catches the naive case the
# operator observed 2026-05-26.

deny() {
	local reason="$1" json
	echo "monitor-misuse-block: $reason" >&2
	json=$(jq -nc --arg r "$reason" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		# Fall back to hand-built JSON if jq somehow fails (shouldn't
		# happen after the presence check above, but defense-in-depth).
		printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"monitor-misuse-block: jq emit failed — failing closed"}}'
		exit 0
	}
	printf '%s\n' "$json"
	exit 0
}

# Bypass FIRST — before stdin read — so emergency override works even
# if stdin is broken.
_audit_log_bypass() {
	local repo_root log_dir log_file
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
	log_dir="$repo_root/.claude/logs"
	log_file="$log_dir/monitor-misuse-bypass.jsonl"
	mkdir -p "$log_dir" 2>/dev/null || return 0
	local cmd_hash="-"
	if [ -n "${1:-}" ]; then
		# Try sha256sum first (GNU coreutils, Linux default), fall back
		# to shasum -a 256 (macOS default). CR-CLI r3 minor: previous
		# code only tried shasum, leaving cmd_hash empty on Linux
		# systems without it. Validate the result is a 64-hex shape
		# before overwriting the "-" default.
		# Guard the assignment with `if` so set -euo pipefail can't
		# abort the bypass when neither sha256sum nor shasum exist —
		# we want fall-through to the "-" default, not termination.
		# CR-CLI r5 major.
		local candidate
		if candidate=$(printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -d' ' -f1); then
			:
		else
			candidate=""
		fi
		if [[ $candidate =~ ^[a-f0-9]{64}$ ]]; then
			cmd_hash=$candidate
		fi
	fi
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"ts":"%s","event":"monitor_misuse_skip","cmd_hash":"%s"}\n' "$ts" "$cmd_hash" >>"$log_file" 2>/dev/null || true
}

if [ "${MONITOR_MISUSE_SKIP:-0}" = "1" ]; then
	echo "monitor-misuse-block: MONITOR_MISUSE_SKIP=1 — passing through (logged to .claude/logs/monitor-misuse-bypass.jsonl)" >&2
	# Bypass path intentionally runs BEFORE the jq presence check
	# below — operator's emergency override must work even if jq
	# is missing from the environment. The audit-log helpers handle
	# the no-jq case gracefully (cmd_hash falls through to "-").
	# Read stdin best-effort so the audit log can record the
	# command-hash. If stdin is broken (the emergency case the
	# bypass-above-stdin-read positioning exists for), we still
	# log the bypass event with cmd_hash="-".
	BYPASS_PAYLOAD=""
	bypass_cmd=""
	if BYPASS_PAYLOAD=$(cat 2>/dev/null) && command -v jq >/dev/null 2>&1; then
		bypass_cmd=$(printf '%s' "$BYPASS_PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || printf '')
	fi
	_audit_log_bypass "$bypass_cmd"
	exit 0
fi

command -v jq >/dev/null 2>&1 || {
	# Hand-built deny JSON (no jq required) — failing closed when
	# jq is missing. Positioned AFTER the MONITOR_MISUSE_SKIP bypass
	# above so the emergency override works even without jq.
	printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"monitor-misuse-block: jq not installed — failing closed"}}'
	exit 0
}

if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi

if ! TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	deny "payload unparseable — failing closed"
fi
if [ "$TOOL_NAME" != "Monitor" ]; then
	exit 0
fi

if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null); then
	deny "tool_input.command unparseable — failing closed"
fi
# Fail-closed if tool_input exists but is not an object (e.g., string,
# number, array) — '.tool_input.command // ""' returns "" silently in
# those cases, which would let malformed payloads slip past. Explicit
# type check denies them. CR-CLI r3 critical.
if printf '%s' "$PAYLOAD" | jq -e 'has("tool_input") and (.tool_input | type != "object")' >/dev/null 2>&1; then
	deny "tool_input is not an object — failing closed"
fi
if [ -z "$CMD" ]; then
	exit 0
fi

# Flatten newlines to spaces so multi-line until-blocks match the same
# regex as single-line forms. Cheaper + clearer than a multi-line
# regex flag.
FLAT_CMD=$(printf '%s' "$CMD" | tr '\n' ' ')

# Single-shape match: `until <cond>(;| ) do ...; sleep N ...; done`.
# - `until[[:space:]]` — the keyword
# - `[^;]+` — at least one non-semicolon char (the condition)
# - `(;|[[:space:]])[[:space:]]*do[[:space:]]` — closes the condition
#   and opens the body. Single-line shell uses `;`, multi-line uses
#   newline (flattened to space). Either is accepted.
# - `.*sleep[[:space:]]+[0-9]` — sleep with a numeric arg anywhere in body
# - `.*done` — closing the loop
# Matching the full shape in ONE regex prevents independent-grep false
# positives (e.g. unrelated `for x in 1 2 3; do sleep 1; done` with the
# word "until" appearing elsewhere in a comment).
if printf '%s' "$FLAT_CMD" | grep -qE 'until[[:space:]]+[^;]+(;|[[:space:]])[[:space:]]*do[[:space:]].*sleep[[:space:]]+[0-9].*done'; then
	deny "Monitor used with one-shot 'until <cond>; do ...; sleep N; done' polling — the harness sends ONE completion notification when a background bash exits, so this should be Bash with run_in_background instead. Background process dying silently leaves the until-loop polling past its timeout, accumulating orphan Monitors across retries (see #80). Bypass: MONITOR_MISUSE_SKIP=1 env."
fi

exit 0
