#!/bin/bash
set -euo pipefail
# event: Stop
# Stop hook — fires when Claude finishes a turn. If the working tree has
# modified files AND the last commit is older than 90s, emit a reminder via
# `systemMessage` (the schema-correct field for Stop events; see comment
# at the jq invocation below). Prevents mid-work abandonment where edits
# sit uncommitted across sessions, while suppressing noise during active
# edit-then-commit cycles. Advisory/non-blocking — benign-failure calls are
# individually defended (`|| true` / `|| exit 0` / `|| echo "?"` / `|| rc=$?` /
# `if cmd; then ... else ...` guards) so strict mode doesn't break the exit-0
# contract. The mix of patterns reflects what each call site actually needs.
#
# v3.22 #265.

_HOOK_START=$(date +%s)
# `${BASH_SOURCE[0]}` resolves to the script path even if sourced;
# `$0` would only break in that case. Hooks are normally executed by the
# harness, but BASH_SOURCE is robust for both.
# shellcheck source=/dev/null
# Source failure (missing _lib.sh) is non-fatal — the EXIT trap's
# `hook_log_run ... || true` already swallows the missing-function call —
# but emit a one-line stderr warning so the operator knows telemetry is off.
# Silent-swallow would let _lib.sh disappearance go unnoticed indefinitely.
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh" 2>/dev/null ||
	echo "stop-uncommitted-changes: _lib.sh source failed — telemetry disabled" >&2

# Tempfiles for git stdout (NUL-delimited porcelain) AND stderr (advisory
# warnings like CRLF). CRITICAL: bash 3.2 macOS strips NUL bytes through
# command substitution `var=$(...)` so we MUST capture porcelain output to a
# file and read the loop from the file — `DIRTY=$(git status -z)` would
# silently produce empty parse results (5-rounds-of-CR-rejected verified).
# Stderr split also prevents a benign advice line from corrupting the parse.
# Fallback to /dev/null on mktemp failure: lose diagnostic capability but
# preserve the exit-0 advisory contract. Emit a degraded systemMessage so
# the operator sees the failure (instead of silently falling through to a
# COUNT=0 result indistinguishable from a clean tree).
_GIT_OUT_TMP=$(mktemp 2>/dev/null) || _GIT_OUT_TMP=/dev/null
_GIT_ERR_TMP=$(mktemp 2>/dev/null) || _GIT_ERR_TMP=/dev/null
if [ "$_GIT_OUT_TMP" = /dev/null ] || [ "$_GIT_ERR_TMP" = /dev/null ]; then
	# Clean up the half-success case: if one mktemp succeeded but the other
	# fell back to /dev/null, remove the orphan so we don't leak it (the EXIT
	# trap below isn't installed yet at this point in execution).
	[ "$_GIT_OUT_TMP" != /dev/null ] && rm -f "$_GIT_OUT_TMP"
	[ "$_GIT_ERR_TMP" != /dev/null ] && rm -f "$_GIT_ERR_TMP"
	WARN_MSG="WARN: stop-uncommitted-changes hook could not mktemp (TMPDIR=${TMPDIR:-/tmp} unwriteable?) — uncommitted-state check skipped. Verify tree manually before ending session."
	if command -v jq >/dev/null 2>&1 && jq -nc --arg msg "$WARN_MSG" '{systemMessage: $msg}'; then
		exit 0
	fi
	# Hand-built fallback if jq missing or fails. (json_escape is defined
	# below — inline a minimal escape since we haven't sourced it yet.)
	ESC=$(printf '%s' "$WARN_MSG" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
	printf '{"systemMessage":"%s"}\n' "$ESC"
	exit 0
fi
# shellcheck disable=SC2154  # _rc is set inside the trap string at runtime
trap '_rc=$?; [ "$_GIT_OUT_TMP" != /dev/null ] && rm -f "$_GIT_OUT_TMP"; [ "$_GIT_ERR_TMP" != /dev/null ] && rm -f "$_GIT_ERR_TMP"; hook_log_run "$0" "$_rc" "$_HOOK_START" 2>/dev/null || true' EXIT INT TERM

# JSON-escape helper for the no-jq fallback. Two-stage:
#   1. STRIP (via `tr -d`) the control bytes that strict parsers (jq, RFC 7159)
#      reject — 0x01-0x08, 0x0B-0x0C, 0x0E-0x1F (backspace, vertical tab,
#      form feed, etc). These chars are LOST, not escaped — they shouldn't
#      appear in user-facing systemMessage anyway, so dropping is fine.
#   2. ESCAPE (via `sed`) the well-known 5: backslash → \\, quote → \", tab
#      → \t, CR → \r, newline → \n (via the awk join). These are preserved.
# NUL (0x00) is not in the strip range because shell variable expansion
# (`"$1"` / `printf '%s' "$1"`) cannot carry a NUL through to the pipeline
# anyway. Multi-line input collapses to a single \n-separated JSON string.
json_escape() {
	# `|| true` on the pipeline: tr/sed/awk all return rc=0 on valid input,
	# but defending the pipe anyway means a future addition (e.g. a sed -E
	# pattern with /q/ or /e/) can't silently abort the script under
	# set -euo pipefail. Callers should still defend with `|| ESC=$1` for
	# the worst case where this function returns empty.
	printf '%s' "$1" |
		LC_ALL=C tr -d '\001-\010\013\014\016-\037' |
		sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e $'s/\t/\\\\t/g' -e $'s/\r/\\\\r/g' |
		awk 'BEGIN{ORS=""} {if (NR>1) printf "\\n"; print}' || true
}

# Must be in a git repo
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Re-query at this exact moment — never trust cached state. The Stop hook's
# message is captured by the harness and may be replayed across renders, so
# we must produce the message from a FRESH `git status` query each fire.
# Capture stderr SEPARATELY (to $_GIT_ERR_TMP) so a git-side failure (lock
# contention, corrupt index, permission flip mid-turn) surfaces a degraded
# warning, AND so a benign git stderr advice line can't corrupt the NUL-
# delimited porcelain parse. CLAUDE.md "no silent failures" rule.
rc=0
git status -z --porcelain >"$_GIT_OUT_TMP" 2>"$_GIT_ERR_TMP" || rc=$?
GIT_ERR=$(cat "$_GIT_ERR_TMP" 2>/dev/null || true)
if [ "$rc" -ne 0 ]; then
	WARN_MSG="WARN: stop-uncommitted-changes hook could not run \`git status\` (rc=${rc}): ${GIT_ERR} — verify tree manually before ending session."
	if command -v jq >/dev/null 2>&1 && jq -nc --arg msg "$WARN_MSG" '{systemMessage: $msg}'; then
		exit 0
	fi
	ESC_WARN=$(json_escape "$WARN_MSG")
	printf '{"systemMessage":"%s"}\n' "$ESC_WARN"
	exit 0
fi
[ ! -s "$_GIT_OUT_TMP" ] && exit 0

# Suppress when the working tree was just committed (within last 90s). The
# common case "user edits → claude commits → next-turn-edit-in-progress"
# would otherwise trigger the warning every turn even though the user is
# actively working. 90s is the threshold tuned for "active session" vs
# "abandoned session". Long-running Bash tool turns (~60s) are still
# captured if no recent commit happened.
#
# Distinguish three cases: (1) empty repo (no HEAD), (2) git log execution
# failure (corrupt refs / permission denial / etc.), (3) real timestamp.
# The prior version collapsed (1) and (2) into the same "no commits yet"
# label, hiding real degradation. Now we probe HEAD first via `git rev-parse
# --verify HEAD` to disambiguate.
NOW_TS=$(date +%s)
LAST_COMMIT_TS=""
if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
	# Case 1 — no HEAD ref = empty repo.
	AGE_LABEL="no commits yet"
elif LAST_COMMIT_TS=$(git log -1 --format=%ct 2>/dev/null); then
	# Case 3 — real timestamp captured.
	if [ "$((NOW_TS - LAST_COMMIT_TS))" -lt 90 ]; then
		exit 0 # recently committed — user mid-iteration, suppress
	fi
	AGE_LABEL="last commit $(((NOW_TS - LAST_COMMIT_TS) / 60))m ago"
else
	# Case 2 — HEAD exists but `git log` failed. Surface the real error
	# instead of the misleading "no commits yet" label.
	AGE_LABEL="git log failed (refs/permissions issue)"
fi

BRANCH=$(git branch --show-current 2>/dev/null || echo "")
[ -z "$BRANCH" ] && BRANCH="(detached)"

# NUL-delimited porcelain output — handles filenames with spaces correctly.
# Per `man git-status`: under `-z`, renames emit TWO NUL records (new\0old\0)
# with the `->` arrow OMITTED. The first record carries status R/C and the
# new path; the second record is the bare old path. We must consume the
# trailing OLD record without incrementing COUNT, otherwise renames are
# double-counted and the old path leaks into FIRST3.
COUNT=0
FIRST3=""
while IFS= read -r -d '' line; do
	COUNT=$((COUNT + 1))
	# Status XY at offset 0-1; offset 2 is space; path starts at offset 3.
	status="${line:0:2}"
	path="${line:3}"
	if [ "$COUNT" -le 3 ]; then
		FIRST3="${FIRST3:+$FIRST3 }$path"
	fi
	# Renames/copies under -z: discard the trailing old-path NUL record so
	# it doesn't get counted or surface in FIRST3.
	case "$status" in
	R* | C*) IFS= read -r -d '' _old || true ;;
	esac
done <"$_GIT_OUT_TMP"

# Compact one-line summary — `systemMessage` is a single string per spec.
# Build MORE_SUFFIX out-of-line: an inline `$([ test ] && echo ...)` cmd-sub
# returns rc=1 when the test fails (no echo runs), and bash 3.2 under set -e
# treats that as the assignment failing → script aborts. The `[ test ] && var=...`
# form short-circuits cleanly because && doesn't propagate the LHS failure.
MORE_SUFFIX=""
[ "$COUNT" -gt 3 ] && MORE_SUFFIX=" (+$((COUNT - 3)) more)"
MSG="⚠ ${COUNT} uncommitted file(s) on \`${BRANCH}\` (${AGE_LABEL}): ${FIRST3}${MORE_SUFFIX} — commit/stash/defer before ending session."

# Stop hooks accept `systemMessage` per the Claude Code spec — NOT
# `hookSpecificOutput.additionalContext` (which is only PreToolUse /
# PostToolUse / UserPromptSubmit / PostToolBatch). Prior implementation
# emitted invalid JSON; this is the schema-correct shape.
# Defensive: if jq is missing or fails, fall back to a hand-built JSON
# literal so the warning at least reaches the user instead of being
# silently dropped (the exact failure mode the schema fix protected
# against).
if command -v jq >/dev/null 2>&1 && jq -nc --arg msg "$MSG" '{systemMessage: $msg}'; then
	exit 0
fi
# Hand-built fallback. Full control-char escape via json_escape (backslash +
# quote + newline + tab + CR) — see helper definition near the top of the file.
# `|| ESC_MSG="$MSG"` honors the helper's documented contract (callers should
# defend against helper failure with a raw-MSG fallback).
ESC_MSG=$(json_escape "$MSG") || ESC_MSG="$MSG"
printf '{"systemMessage":"%s"}\n' "$ESC_MSG"
exit 0
