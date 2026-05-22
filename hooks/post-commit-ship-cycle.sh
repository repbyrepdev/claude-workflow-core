#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W4 (#728): post-commit helper that fires `ship-pr-cycle.sh resume`
# after every successful `git commit`. Runs detached so it doesn't block
# the commit return.
#
# Wiring (one-time, per-clone — `.git/hooks/post-commit` is local-only):
#   cat >> .git/hooks/post-commit <<'EOF'
#   if [ -x "$(dirname "$0")/post-commit-ship-cycle.sh" ]; then
#       "$(dirname "$0")/post-commit-ship-cycle.sh" || true
#   fi
#   EOF
#
# Behavior:
#   1. Resolve current HEAD SHA.
#   2. Spawn `ship-pr-cycle.sh resume` detached (setsid + nohup).
#   3. Log invocation to .claude/logs/ship-cycle-resume.jsonl with sha + ts.
#   4. Exit 0 immediately — failures in the detached process don't block.
#
# Skip path: SHIP_CYCLE_POST_COMMIT_SKIP=1 in env disables the auto-fire
# (operator-controlled toggle, e.g. during commit-amend storms).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -z "$REPO_ROOT" ] && exit 0

if [ "${SHIP_CYCLE_POST_COMMIT_SKIP:-0}" = "1" ]; then
	exit 0
fi

SCRIPT="$REPO_ROOT/scripts/ship-pr-cycle.sh"
[ -x "$SCRIPT" ] || exit 0

LOG_DIR="$REPO_ROOT/.claude/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/ship-cycle-resume.jsonl"

# Resolve SHA first — if rev-parse fails, exit 0 silently rather than
# log a half-empty record. Forensic readers expect every record to have
# a usable sha fingerprint.
SHA=$(git rev-parse HEAD 2>/dev/null) || exit 0
[ -z "$SHA" ] && exit 0
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="<unresolved>"
[ -z "$BRANCH" ] && BRANCH="<unresolved>"

# Log the invocation (atomic single-line append, well under PIPE_BUF).
# Use jq to safely escape branch name — git allows characters that
# break naive JSON interpolation (e.g. `git checkout -b 'foo"bar'`).
jq -nc --arg ts "$TS" --arg sha "$SHA" --arg branch "$BRANCH" \
	'{ts:$ts, sha:$sha, branch:$branch, action:"fire-resume"}' >>"$LOG"

# Detach: setsid + nohup so the resume call survives the commit's parent
# shell exit. stdout/stderr → log file for post-mortem inspection.
DETACH_LOG="$LOG_DIR/ship-cycle-resume-$(printf '%s' "$SHA" | head -c 8).log"
if command -v setsid >/dev/null 2>&1; then
	setsid nohup "$SCRIPT" resume >"$DETACH_LOG" 2>&1 </dev/null &
else
	# macOS lacks setsid by default; nohup + & is the best we can do.
	nohup "$SCRIPT" resume >"$DETACH_LOG" 2>&1 </dev/null &
fi
disown 2>/dev/null || true

exit 0
