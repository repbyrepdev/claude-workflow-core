#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# v4.24-O (#601) — PreToolUse Write/Edit guard that refuses to let Claude
# create a new .sh file without `set -u*` in the first 20 lines.
#
# Why this exists: bash-safety.sh blocks at COMMIT time. By then the file
# is already on disk, I've already run tests against it, and now I have to
# edit + re-stage + re-log bats hashes + retry commit. User feedback:
# "it's annoying seeing you code then have to commit just to see oh I need
#  to move set eu pipefail in a bunch of places." Fixing by mechanically
# enforcing the same rule at Write-tool time so the file never lands wrong.
#
# IMPORTANT: rule must EXACTLY match .claude/pre-commit-hooks/bash-safety.sh.
# Both source .claude/_lib/bash-safety-check.sh — one rule, two gates.
#
# Registered via ~/.claude/settings.json hooks.PreToolUse matcher=Edit|Write|MultiEdit.
# Reads Claude Code hook payload from stdin (JSON with tool_input.file_path
# + tool_input.content / tool_input.new_string). Exit 2 denies the tool use
# with the stderr message shown to Claude.

# v4.24-Q (#604): denial via shared hook_deny — JSON permissionDecision
# ="deny" + exit 0 is the documented reliable block path (bare exit 2
# was unreliable per skill-bypass-guard v4.17.R precedent). Resolve via
# hook's own install dir (not `git rev-parse`) so tmpdir/arbitrary-cwd
# invocation works.
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi

# Fail-closed on stdin/jq errors — prior `|| echo "{}"` silently coerced
# broken payloads to empty JSON and bypassed the guard.
if ! PAYLOAD=$(cat 2>/dev/null); then
	hook_deny "bash-safety-write-guard" "stdin read failed — failing closed"
fi
if ! TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	hook_deny "bash-safety-write-guard" "hook payload not valid JSON — failing closed"
fi
if ! FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null); then
	hook_deny "bash-safety-write-guard" "hook payload missing tool_input.file_path — failing closed"
fi

# Only care about Write/Edit/MultiEdit on .sh files.
case "$TOOL" in
Write | Edit | MultiEdit) ;;
*) exit 0 ;;
esac
case "$FILE_PATH" in
*.sh) ;;
*) exit 0 ;;
esac

# For Edit/MultiEdit: only guard when the file doesn't exist yet (creating).
# Existing files are grandfathered — same rule as bash-safety.sh's
# --diff-filter=A. If the file exists, let the edit through; commit-time
# gate will still catch any content that falls out of spec.
if [ -f "$FILE_PATH" ] && [ "$TOOL" != "Write" ]; then
	exit 0
fi

# Extract the content-about-to-be-written. Write uses .content,
# Edit uses .new_string (but usually only for existing files which we
# skip above). MultiEdit uses .edits[].new_string — also existing files.
CONTENT=""
# jq failures here are fail-closed: a malformed payload that can't be
# parsed could be a real attack surface (guard bypass via crafted JSON).
# Use `if ! CMD=...` form — command substitution always yields exit 0,
# so `$(...) || hook_deny ...` silently skips the error branch. The
# inverted `if !` around the assignment reads jq's actual rc.
case "$TOOL" in
Write)
	if ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.content // ""' 2>/dev/null); then
		hook_deny "bash-safety-write-guard" "jq failed to extract Write content — failing closed"
	fi
	;;
Edit)
	if ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""' 2>/dev/null); then
		hook_deny "bash-safety-write-guard" "jq failed to extract Edit new_string — failing closed"
	fi
	;;
MultiEdit)
	# Concatenate all new_string values — if any one is wrong, fail.
	if ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.edits // []) | map(.new_string // "") | join("\n")' 2>/dev/null); then
		hook_deny "bash-safety-write-guard" "jq failed to extract MultiEdit edits — failing closed"
	fi
	;;
esac

# Empty content means Claude passed nothing — let the tool handle that
# upstream. The empty case isn't an attack surface (nothing written).
[ -z "$CONTENT" ] && exit 0

# Share the rule with the commit-time gate.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
LIB="${REPO_ROOT}/.claude/_lib/bash-safety-check.sh"
if [ ! -f "$LIB" ]; then
	# Library missing — fail open so fresh-clone repos aren't broken, but
	# emit stderr so it's visible. Commit-time bash-safety.sh still enforces
	# if the repo has pre-commit set up. Prior silent exit 0 hid a real
	# configuration break from the operator.
	echo "bash-safety-write-guard: shared lib missing at $LIB — Write-time check disabled (commit-time gate still active)" >&2
	exit 0
fi
# shellcheck source=../_lib/bash-safety-check.sh
. "$LIB"

if ! bash_safety_check_content "$FILE_PATH" "$CONTENT"; then
	hook_deny "bash-safety-write-guard" \
		"Write refused — new .sh file missing \`set -u*\` in first 20 lines. Rule identical to commit-time bash-safety.sh. Fix content before retrying. See stderr for detail."
fi

exit 0
