#!/bin/bash
set -euo pipefail
# event: SessionStart
# v0.32.12 (#250-wiring): daily-throttled runner for the log-retention SSOT.
#
# Runs scripts/maintain/log-retention.sh (prunes logs/state per the SSOT
# .claude/log-retention.yml) at most once per ~24h per repo, gated on a marker
# file's mtime under .claude/logs/last-run/ (the established last-run dir; NOT
# in the yml's prune set, so it survives its own runs).
#
# Fail-closed: ALWAYS exit 0 — a periodic cleanup utility must never block
# session start. No-op when the retention script is absent (repo predates #250
# or hasn't been bootstrapped yet).
#
# Bypass: LOG_RETENTION_SESSION_SKIP=1. Override cadence: LOG_RETENTION_THROTTLE_S.

[ "${LOG_RETENTION_SESSION_SKIP:-0}" = "1" ] && exit 0

# Resolve repo root from the script's own location (decouple from caller cwd),
# falling back to the canonicalized parent when not inside a git worktree
# (e.g. a test copy under a tmpdir). Either way, no-op if it can't be found.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$REPO_ROOT" ]; then
	REPO_ROOT=$(cd -- "$SELF_DIR/.." 2>/dev/null && pwd) || REPO_ROOT=""
fi
{ [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ]; } || exit 0

RETENTION="$REPO_ROOT/scripts/maintain/log-retention.sh"
[ -x "$RETENTION" ] || exit 0

THROTTLE_S="${LOG_RETENTION_THROTTLE_S:-86400}"
[[ $THROTTLE_S =~ ^[0-9]+$ ]] || THROTTLE_S=86400

MARKER_DIR="$REPO_ROOT/.claude/logs/last-run"
MARKER="$MARKER_DIR/log-retention.ts"

now=$(date +%s)
if [ -f "$MARKER" ]; then
	# Portable mtime (BSD stat -f / GNU stat -c); 0 on failure ⇒ treat as stale.
	last=$(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || echo 0)
	[[ $last =~ ^[0-9]+$ ]] || last=0
	if [ "$((now - last))" -lt "$THROTTLE_S" ]; then
		exit 0 # ran within the throttle window — skip
	fi
fi

mkdir -p "$MARKER_DIR" 2>/dev/null || true
# Live prune (no --dry-run). Capture rc but never propagate — fail-closed.
ret_rc=0
"$RETENTION" >/dev/null 2>&1 || ret_rc=$?
# Stamp the marker regardless of outcome so a failing run doesn't re-fire every
# session start (it retries on the next throttle window).
: >"$MARKER" 2>/dev/null || true
if [ "$ret_rc" -ne 0 ]; then
	echo "log-retention-session: log-retention.sh exited rc=$ret_rc (throttled retry in ${THROTTLE_S}s)" >&2
fi
exit 0
