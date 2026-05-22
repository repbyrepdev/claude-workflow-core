#!/bin/bash
set -euo pipefail
# event: SessionStart
# v4.26 (#626) — SessionStart hook: surface in-flight session state so a
# post-compact session resumes without re-deriving "what was I doing".
#
# Reads .claude/.session-state/ (populated by persist-session-state.sh) and
# emits a hookSpecificOutput.additionalContext block summarizing the
# active PR / branch / last command. Silent when no state exists.

_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$REPO_ROOT/.claude/.session-state"

# No state captured → nothing to surface. Realistic case: fresh clone where
# the persist hook hasn't run yet (its first run creates STATE_DIR).
[ -d "$STATE_DIR" ] || exit 0

LAST_CMD=""
ROUND_COUNT=0

# Reuse the SSOT KV reader (_lib.sh) — same parser as persist + pre-compact.
# session_state_read always echoes (empty on miss) and exits 0, so these
# unconditionally bind under set -u without a prior empty-init.
PR=$(session_state_read pr "$STATE_DIR")
BRANCH_RECORDED=$(session_state_read branch "$STATE_DIR")

if [ -f "$STATE_DIR/last-tool-cmd.txt" ]; then
	LAST_CMD=$(head -c 200 "$STATE_DIR/last-tool-cmd.txt" 2>/dev/null || echo "")
fi

if [ -f "$STATE_DIR/cr-round-state.jsonl" ]; then
	ROUND_COUNT=$(wc -l <"$STATE_DIR/cr-round-state.jsonl" 2>/dev/null | tr -d ' ')
	[ -n "$ROUND_COUNT" ] || ROUND_COUNT=0
fi

# Bail if the state is empty in every dimension — nothing useful to inject.
if [ -z "$PR" ] && [ -z "$LAST_CMD" ] && [ "$ROUND_COUNT" -eq 0 ]; then
	exit 0
fi

# Cross-check: if the recorded branch doesn't match the current branch, the
# state is stale (user switched branches mid-session). Surface that too so I
# don't blindly assume the old PR is still in flight.
CURRENT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
STALE_NOTE=""
if [ -n "$BRANCH_RECORDED" ] && [ -n "$CURRENT_BRANCH" ] && [ "$BRANCH_RECORDED" != "$CURRENT_BRANCH" ]; then
	STALE_NOTE=" (NOTE: state recorded on branch \`$BRANCH_RECORDED\` but currently on \`$CURRENT_BRANCH\` — likely stale)"
fi

# Build segments into an array so we can join with " · " — appending the
# separator at each segment leaves a dangling " · " when a trailing segment
# (e.g. LAST_CMD) is empty. STALE_NOTE is a parenthetical tail-append, not
# a separator-joined segment, so it stays out of this array.
SEGMENTS=()
[ -n "$PR" ] && SEGMENTS+=("in-flight PR=#$PR")
[ -n "$BRANCH_RECORDED" ] && SEGMENTS+=("branch=$BRANCH_RECORDED")
[ "$ROUND_COUNT" -gt 0 ] && SEGMENTS+=("recorded actions=$ROUND_COUNT")
[ -n "$LAST_CMD" ] && SEGMENTS+=("last cmd: $LAST_CMD")
# Join via printf — emits " · <seg>" per array element, then strip the
# leading " · ". Avoids permanent IFS mutation (the `IFS=$'\x01' VAR=...`
# form leaks because the right-hand side is an assignment, not a command).
if [ "${#SEGMENTS[@]}" -gt 0 ]; then
	printf -v BODY -- ' · %s' "${SEGMENTS[@]}"
	BODY="${BODY# · }"
else
	BODY=""
fi
CTX="📌 Session-state restore: ${BODY}${STALE_NOTE}"

jq -nc \
	--arg ctx "$CTX" \
	'{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

exit 0
