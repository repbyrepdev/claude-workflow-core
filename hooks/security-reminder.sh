#!/bin/bash
set -uo pipefail
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# Wrapper that delegates to the upstream security-guidance plugin's
# PreToolUse hook. Ensures Layer 0 (CLAUDE.md rule 5) actually fires on
# Edit/Write/MultiEdit regardless of whether plugin auto-registration kicks in.
#
# Plugin discovery: glob `~/.claude/plugins/**/security-guidance/hooks/security_reminder_hook.py`.
# The specific marketplace path (claude-plugins-official) may change across
# reinstalls — the glob stays robust.
#
# Input: stdin = tool-use JSON payload (Claude Code hook protocol).
# Exit code: propagates the plugin's exit. Plugin exits 2 to block a risky
# Edit (surfacing the reminder to stderr) and 0 to allow. If the plugin or
# python3 is missing, **fail closed** (exit 2) by default — a missing
# Layer-0 dependency is a security regression, not a free pass. Opt out
# with SECURITY_REMINDER_DEGRADED_EXIT=0 for contributors who haven't
# installed security-guidance yet (e.g., fresh clones before plugin install).

DEGRADED_EXIT="${SECURITY_REMINDER_DEGRADED_EXIT:-2}"
# SECURITY_REMINDER_PLUGIN_ROOT lets tests point at a fake plugin tree under
# a tmpdir. Defaults to the user's plugin root.
PLUGIN_ROOT="${SECURITY_REMINDER_PLUGIN_ROOT:-$HOME/.claude/plugins}"

HOOK_SCRIPT=$(find "$PLUGIN_ROOT" -type f -path '*security-guidance*/hooks/security_reminder_hook.py' 2>/dev/null | head -1)

if [ -z "$HOOK_SCRIPT" ] || [ ! -f "$HOOK_SCRIPT" ]; then
	echo "security-reminder.sh: security-guidance plugin not found — Layer 0 disabled for this session" >&2
	exit "$DEGRADED_EXIT"
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "security-reminder.sh: python3 unavailable — Layer 0 disabled for this session" >&2
	exit "$DEGRADED_EXIT"
fi

# Pass stdin through. Plugin script writes advisory messages to stderr and
# exits 2 on block, 0 on pass. Exec to propagate exit code cleanly.
exec python3 "$HOOK_SCRIPT"
