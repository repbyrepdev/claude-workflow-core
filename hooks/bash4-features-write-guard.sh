#!/bin/bash
set -u
# event: PreToolUse
# matcher: Edit|Write|MultiEdit
# v4.24-P (#603) — PreToolUse Write/Edit/MultiEdit guard: refuse bash 4.0+
# features headed for a `#!/bin/bash` (3.2) file. Two paths (#2645):
#   - Write: the full new content is scanned before the file lands.
#   - Edit/MultiEdit on an EXISTING file: the POST-EDIT content is
#     RECONSTRUCTED (disk content with each old->new applied, Edit-tool
#     semantics) and scanned whole — so shebang downgrades, waiver
#     deletions, and features formed jointly with disk context are all
#     judged against the file that will actually exist. The old wholesale
#     grandfathering is gone — the anchor-case mapfile entered via an
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

# Edit/MultiEdit on an existing file: reconstruct the POST-EDIT content and
# scan THAT (#2645 phase2 r2 — supersedes the r1 shebang+waiver graft). The
# graft judged the fragment against the PRE-edit file, so an edit that
# downgrades the shebang to `#!/bin/bash`, deletes a waiver while keeping
# its feature, or whose halves only form a feature joined with disk context
# was judged against the wrong file. Reconstruction applies each
# old_string -> new_string literally (first occurrence, or all when
# replace_all), matching the Edit tool's own semantics; an old_string that
# does not occur leaves content unchanged — that edit fails in the tool
# anyway, and scanning disk-as-is stays fail-safe. Unreadable file or
# un-enumerable edits = deny (r1 fail-closed standard).
RECONSTRUCTED=""
if [ -f "$FILE_PATH" ] && [ "$TOOL" != "Write" ]; then
	if ! DISK_CONTENT=$(cat "$FILE_PATH" 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "cannot read on-disk $FILE_PATH to reconstruct the edit — failing closed"
	fi
	if ! _edits=$(printf '%s' "$PAYLOAD" | jq -c 'if .tool_name == "MultiEdit" then (.tool_input.edits // [])[] else {old_string: (.tool_input.old_string // ""), new_string: (.tool_input.new_string // ""), replace_all: (.tool_input.replace_all // false)} end' 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "jq failed to enumerate edits for reconstruction — failing closed"
	fi
	RECONSTRUCTED="$DISK_CONTENT"
	while IFS= read -r _edit; do
		[ -n "$_edit" ] || continue
		_old=$(printf '%s' "$_edit" | jq -r '.old_string // ""')
		_new=$(printf '%s' "$_edit" | jq -r '.new_string // ""')
		_all=$(printf '%s' "$_edit" | jq -r '.replace_all // false')
		[ -n "$_old" ] || continue
		if [ "$_all" = "true" ]; then
			RECONSTRUCTED="${RECONSTRUCTED//"$_old"/$_new}"
		else
			RECONSTRUCTED="${RECONSTRUCTED/"$_old"/$_new}"
		fi
	done <<<"$_edits"
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
Edit | MultiEdit)
	# Full post-edit file, reconstructed above. A NEW file via Edit (no
	# on-disk copy) degrades to the bare fragment — no shebang means the
	# detector treats it as safe, and the commit gate scans the real blob.
	if [ -n "$RECONSTRUCTED" ]; then
		CONTENT="$RECONSTRUCTED"
	elif ! CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""' 2>/dev/null); then
		hook_deny "bash4-features-write-guard" "jq failed to extract Edit new_string"
	fi
	;;
esac

[ -z "$CONTENT" ] && exit 0

if ! bash4_features_check_content "$FILE_PATH" "$CONTENT"; then
	hook_deny "bash4-features-write-guard" \
		'Write/Edit refused — the post-edit .sh would use bash 4.0+ feature(s) with `#!/bin/bash` shebang. macOS /bin/bash is 3.2. Change shebang to `#!/usr/bin/env bash` or remove the bash-4 feature. See stderr for which feature.'
fi

exit 0
