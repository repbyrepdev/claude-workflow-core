#!/bin/bash
set -euo pipefail
# event: SessionStart
# auto-register: true
# v0.30.F (#193) — wipe the Phase 1 subagent agentId registry at SessionStart.
#
# WHY: phase1-agent-id.sh records the `agentId` of each Phase 1 subagent so
# round N>1 can RESUME it via SendMessage instead of spawning fresh. Those
# agentIds identify IN-PROCESS teammates, which do NOT survive a session per
# Claude Code docs ("No session resumption with in-process teammates: /resume
# and /rewind do not restore in-process teammates"). A record carried across
# a session boundary would point at a dead teammate — the resume would fail
# and the main loop would fall back to a fresh spawn anyway, but only after a
# wasted SendMessage round-trip.
#
# Clearing here makes the invariant clean: any record phase1-agent-id.sh
# `directive` finds is necessarily from the CURRENT session, so no
# session-marker comparison is needed in the hot path. Best-effort: never
# fails session start (a clear failure is logged to stderr but exits 0).
#
# Idempotent (no dir → no-op). Safe across consumer repos: resolves the repo
# root the same way every other hook does; outside a git repo it no-ops.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
# Outside a git repo (gh-only sessions, scratch dirs) — nothing to clear.
[ -n "$REPO_ROOT" ] || exit 0

STORE_DIR="$REPO_ROOT/.claude/.session-state/phase1-agent-ids"
[ -d "$STORE_DIR" ] || exit 0

# Defensive guard before rm -rf: the path MUST end in the expected suffix.
# REPO_ROOT comes from `git rev-parse` so this should always hold, but an
# `rm -rf` deserves a belt-and-suspenders check regardless.
case "$STORE_DIR" in
*/.claude/.session-state/phase1-agent-ids) ;;
*)
	echo "phase1-agent-ids-session-clear: WARN refusing to clear unexpected path: $STORE_DIR" >&2
	exit 0
	;;
esac

if ! rm -rf "$STORE_DIR" 2>/dev/null; then
	# Non-fatal: stale records only cost a wasted resume attempt that falls
	# back to fresh. Surface, don't block session start.
	echo "phase1-agent-ids-session-clear: WARN failed to clear $STORE_DIR (perms?)" >&2
fi
exit 0
