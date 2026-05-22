#!/bin/bash
set -u
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# v4.24-P (#603) — PreToolUse Write/Edit/MultiEdit guard: refuse to land
# a new .sh file that uses bash 4.0+ features with `#!/bin/bash` shebang.
#
# Anchor case: CR autofix introduced `mapfile -d ''` into phase1-launcher
# in v4.24-R cycle. macOS bash 3.2 silently skipped it; caused phantom
# test skips + 15min of debug before I caught it. This gate refuses the
# Write before the file lands.
#
# Rule shared with commit-time gate via .claude/_lib/bash4-features-check.sh.
# Denial uses .claude/_lib/hook-deny.sh (JSON permissionDecision=deny).
#
# Registered via ~/.claude/settings.json hooks.PreToolUse matcher=
# Edit|Write|MultiEdit.

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_CHECK="${HOOK_DIR}/../_lib/bash4-features-check.sh"
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"

# Fail-open gracefully if lib missing (fresh clone) — commit-time gate
# still enforces if pre-commit is wired.
[ -f "$LIB_CHECK" ] || exit 0
# shellcheck source=../_lib/bash4-features-check.sh
source "$LIB_CHECK"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi

# Parse stdin payload. Fail-closed on malformed JSON (same as sibling
# bash-safety-write-guard).
if ! PAYLOAD=$(cat 2>/dev/null); then
	hook_deny "bash4-features-write-guard" "stdin read failed — failing closed"
fi
if ! TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	hook_deny "bash4-features-write-guard" "payload not valid JSON — failing closed"
fi
if ! FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null); then
	hook_deny "bash4-features-write-guard" "payload missing tool_input.file_path"
fi

case "$TOOL" in
Write | Edit | MultiEdit) ;;
*) exit 0 ;;
esac
case "$FILE_PATH" in
*.sh) ;;
*) exit 0 ;;
esac

# Grandfather existing files on Edit/MultiEdit (same semantic as commit-
# time --diff-filter=A). Write on an existing file always re-validates.
if [ -f "$FILE_PATH" ] && [ "$TOOL" != "Write" ]; then
	exit 0
fi
case "$(basename "$FILE_PATH")" in
_*.sh) exit 0 ;;
esac
# Path-based exemption for .claude/_lib/*.sh — matches the sibling
# commit-time gate's exemption. Ensures both guards align when a lib
# file's basename doesn't start with `_` (e.g. `hook-deny.sh` under
# .claude/_lib/). v4.24-Q2 #609 drift fix.
case "$FILE_PATH" in
*/.claude/_lib/*.sh | .claude/_lib/*.sh) exit 0 ;;
esac

CONTENT=""
# Use `if ! CMD=...` form — command substitution always yields exit 0,
# so `$(...) || hook_deny ...` silently skips the error branch (same bug
# CR found in bash-safety-write-guard.sh's identical pattern, v4.24-Q2).
case "$TOOL" in
Write)
	if ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.content // ""' 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "jq failed to extract Write content"
	fi
	;;
Edit)
	if ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""' 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "jq failed to extract Edit new_string"
	fi
	;;
MultiEdit)
	if ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.edits // []) | map(.new_string // "") | join("\n")' 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "jq failed to extract MultiEdit edits"
	fi
	;;
esac

[ -z "$CONTENT" ] && exit 0

if ! bash4_features_check_content "$FILE_PATH" "$CONTENT"; then
	hook_deny "bash4-features-write-guard" \
		"Write refused — .sh uses bash 4.0+ feature(s) with \`#!/bin/bash\` shebang. macOS /bin/bash is 3.2. Change shebang to \`#!/usr/bin/env bash\` or remove the bash-4 feature. See stderr for which feature."
fi

exit 0
