#!/bin/bash
set -euo pipefail
# v4.26 (#626) — one-time installer: register persist-session-state.sh in the
# user-scope settings file (~/.claude/settings.json) under PostToolUse:Bash.
#
# Why: per CLAUDE.md, PreToolUse / PostToolUse hooks live at user scope
# (project-scope settings.json only loads UserPromptSubmit / SessionStart /
# Stop / PreCompact). The PR ships the hook script + project-scope restore
# hook + bats coverage, but cannot edit ~/.claude/settings.json on behalf of
# a fresh clone — that's a per-machine registration. Run this once.
#
# Idempotent: if the hook is already registered, this is a no-op + reports
# the existing state.

# shellcheck disable=SC2034  # REPO_ROOT may be referenced by sourced libs

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HOOK_SCRIPT="$(dirname "$0")/persist-session-state.sh"
USER_SETTINGS="$HOME/.claude/settings.json"

if [ ! -x "$HOOK_SCRIPT" ]; then
	echo "FAIL: $HOOK_SCRIPT missing or not executable" >&2
	exit 1
fi

if [ ! -f "$USER_SETTINGS" ]; then
	echo "FAIL: $USER_SETTINGS not found — Claude Code user settings must exist first" >&2
	exit 1
fi

# Already registered?
if jq -e --arg p "$HOOK_SCRIPT" '
	.hooks.PostToolUse // [] | map(select(.matcher == "Bash")) |
	map(.hooks // [] | map(select(.command == $p))) | flatten | length > 0
' "$USER_SETTINGS" >/dev/null 2>&1; then
	echo "✓ persist-session-state.sh already registered in $USER_SETTINGS"
	exit 0
fi

# Register: append to the existing PostToolUse:Bash matcher entry. If no Bash
# matcher exists yet, create one. jq edit-in-place via tmpfile.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

jq --arg p "$HOOK_SCRIPT" '
	.hooks.PostToolUse //= [] |
	if any(.hooks.PostToolUse[]; .matcher == "Bash") then
		.hooks.PostToolUse |= map(
			if .matcher == "Bash" then
				.hooks //= [] | .hooks += [{type:"command", command:$p, timeout:3}]
			else . end
		)
	else
		.hooks.PostToolUse += [{matcher:"Bash", hooks:[{type:"command", command:$p, timeout:3}]}]
	end
' "$USER_SETTINGS" >"$TMP"

# Sanity check the rewrite parses + has the new entry
if ! jq -e --arg p "$HOOK_SCRIPT" '
	.hooks.PostToolUse | map(select(.matcher == "Bash")) |
	map(.hooks | map(select(.command == $p))) | flatten | length > 0
' "$TMP" >/dev/null; then
	echo "FAIL: post-write verification failed; $USER_SETTINGS unchanged" >&2
	exit 2
fi

# Preserve original file mode across the rewrite. macOS `stat -f %A` and
# Linux `stat -c %a` both emit numeric mode; portable form picks whichever
# returns a parseable octal string.
ORIG_MODE=$(stat -f %A "$USER_SETTINGS" 2>/dev/null || stat -c %a "$USER_SETTINGS" 2>/dev/null || echo "")
mv "$TMP" "$USER_SETTINGS"
[ -n "$ORIG_MODE" ] && chmod "$ORIG_MODE" "$USER_SETTINGS" 2>/dev/null || true
trap - EXIT
echo "✓ Registered persist-session-state.sh in $USER_SETTINGS (PostToolUse:Bash)"
