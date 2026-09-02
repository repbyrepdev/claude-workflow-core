#!/bin/bash
set -u
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# v4.24-P (#603) — PreToolUse Write/Edit/MultiEdit guard: refuse bash 4.0+
# features headed for a `#!/bin/bash` (3.2) file. Two paths (#2645 r1):
#   - Write: the full new content is scanned before the file lands.
#   - Edit/MultiEdit on an EXISTING file: the edit fragment is scanned,
#     grafted with the on-disk shebang + `# bash4-waiver:` lines (the
#     fragment alone carries neither). The old wholesale grandfathering
#     of existing files is gone — the anchor-case mapfile entered via an
#     edit, not a new-file Write.
#
# Anchor case: CR autofix introduced `mapfile -d ''` into phase1-launcher
# in v4.24-R cycle. macOS bash 3.2 silently skipped it; caused phantom
# test skips + 15min of debug before I caught it.
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

# Edit/MultiEdit on an existing file used to be grandfathered wholesale
# (the old commit-time --diff-filter=A semantic). #2645 r1: the commit gate
# now covers modified files (AM), so this guard scans the EDIT FRAGMENT too
# — otherwise the cheap early layer misses exactly the regression class the
# gate exists for (features EDITED into tracked files, e.g. by CR autofix).
# The fragment carries no shebang and no waiver comments, so both are
# borrowed from the ON-DISK file: a safe on-disk shebang exits early, and
# on-disk waiver lines are prepended so a waived feature stays waived.
EDIT_PREFIX=""
if [ -f "$FILE_PATH" ] && [ "$TOOL" != "Write" ]; then
	# An UNREADABLE on-disk file must fail CLOSED, not read as "safe
	# shebang" (#2645 r1 silent-failure: `|| printf ''` turned chmod-000 /
	# EIO into a silent allow of the exact edit denied when readable).
	# Matches this guard's stdin/jq fail-closed handling and the SSOT
	# lib's unreadable-file BLOCK.
	if ! DISK_HEAD=$(head -1 "$FILE_PATH" 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "cannot read on-disk $FILE_PATH to determine its shebang — failing closed"
	fi
	# Shared predicate — one definition with the lib's own scan (#2645 r1).
	bash4_features_unsafe_shebang "$DISK_HEAD" ||
		exit 0 # genuinely safe/absent shebang — fragment cannot regress 3.2
	# grep rc 1 (no waiver lines) is normal; rc >= 2 is a read error on a
	# file head just proved readable — treat as no-waivers, the detector
	# then fails toward BLOCK (stricter), never toward allow.
	DISK_WAIVERS=$(grep -E '^[[:space:]]*#[[:space:]]*bash4-waiver:' "$FILE_PATH" 2>/dev/null || true)
	EDIT_PREFIX="$DISK_HEAD
$DISK_WAIVERS"
fi
# `_*.sh` carve-out — shared predicate; rationale + caveats live with it
# in the SSOT lib (#2645 r1).
bash4_features_skip_basename "$FILE_PATH" && exit 0
# Detector-lib self-exemption — the SHARED predicate from the SSOT lib
# (#2645 r1): exactly one file wide, replacing the blanket `.claude/_lib/`
# carve-out. Every other non-underscore-named lib is in scope; guarded use
# goes through `# bash4-waiver:` instead. Shared with the commit-time gate
# so the scope predicate cannot drift again (#609).
bash4_features_exempt_path "$FILE_PATH" && exit 0

CONTENT=""
# Use `if ! CMD=...` form for jq extraction failures. (Precise semantics,
# #2645 r1 comment fix: a BARE assignment `X=$(cmd)` does propagate cmd's
# exit status — it is builtin-prefixed forms like `local X=$(cmd)` that
# mask it, the v4.24-Q2 bug class in bash-safety-write-guard.sh. `if !` is
# used uniformly anyway: it survives a future prefix refactor and reads as
# an explicit error branch.)
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
# Edit/MultiEdit fragment: graft the on-disk shebang + waiver lines so the
# detector sees the file's real dialect declaration and honors its waivers.
[ -n "$EDIT_PREFIX" ] && CONTENT="$EDIT_PREFIX
$CONTENT"

if ! bash4_features_check_content "$FILE_PATH" "$CONTENT"; then
	hook_deny "bash4-features-write-guard" \
		'Write refused — .sh uses bash 4.0+ feature(s) with `#!/bin/bash` shebang. macOS /bin/bash is 3.2. Change shebang to `#!/usr/bin/env bash` or remove the bash-4 feature. See stderr for which feature.'
fi

exit 0
