#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# PostToolUse hook that captures FAILED tool calls to .claude/session-log.jsonl
# for later /retro analysis. Fills the "what went wrong" signal gap — capture-
# signal.sh logs what the user said; this logs what the tools did.
#
# Captures: tool name, command/input excerpt, exit_code, stderr excerpt (first
# 200 chars). Only fires on failure — clean runs produce no signal noise.
#
# v3.22 #265.

_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
EXIT=$(echo "$INPUT" | jq -r '.tool_response.exitCode // empty' 2>/dev/null || true)

# Only log on failure. Exit codes:
#   - numeric non-zero → tool failed
#   - "error" or string → Agent/other tool errored
#   - null / missing → skip (tool hasn't reported)
FAILED=0
if [ -n "$EXIT" ] && [ "$EXIT" != "0" ] && [ "$EXIT" != "null" ]; then
	FAILED=1
fi
# Catch explicit error fields too (some tools emit .is_error or .error)
IS_ERROR=$(echo "$INPUT" | jq -r '.tool_response.is_error // .is_error // empty' 2>/dev/null || true)
[ "$IS_ERROR" = "true" ] && FAILED=1

[ "$FAILED" = "0" ] && exit 0

# Extract concise identifiers. `|| true` on each pipe: under set -euo pipefail,
# malformed INPUT JSON makes jq exit 2; pipefail propagates and aborts the
# assignment — defeating the hook precisely when it's needed (logging a
# tool failure with a malformed payload).
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.file_path // .tool_input.pattern // ""' 2>/dev/null | head -c 200 || true)
STDERR=$(echo "$INPUT" | jq -r '.tool_response.stderr // .tool_response.error // ""' 2>/dev/null | head -c 200 || true)

LOG_DIR=".claude"
LOG_FILE="$LOG_DIR/session-log.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null || true

jq -nc \
	--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg tool "$TOOL" \
	--arg cmd "$CMD" \
	--arg exit "$EXIT" \
	--arg stderr "$STDERR" \
	'{signal_type: "tool_failure", ts: $ts, tool: $tool, command: $cmd, exit_code: $exit, stderr_excerpt: $stderr}' \
	>>"$LOG_FILE" 2>/dev/null || true

exit 0
