#!/bin/bash
set -euo pipefail
# event: SessionStart
# auto-register: true
# v0.7.1 (#23): fire scripts/cr/auto-parse-plans.sh on session start so the
# plan-me → CR plan → epic+subs chain advances without operator manual
# `cr-plan parse <N>` invocation. The script is idempotent (label-gated) +
# nudges stuck plans after CR_PLAN_STUCK_TIMEOUT_SEC (default 600s).
#
# Runs detached (& disown) so session-start isn't delayed by `gh issue list`.
# Output goes to .claude/logs/cr-auto-parse.jsonl (JSONL audit log).

# Resolve script path. SCRIPT_DIR is the hook dir; auto-parse lives at
# ../scripts/cr/auto-parse-plans.sh in the plugin OR consumer layout.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTO_PARSE="$SCRIPT_DIR/../scripts/cr/auto-parse-plans.sh"
if [ ! -x "$AUTO_PARSE" ]; then
	# Silent no-op: this is an optional convenience hook, not a critical gate.
	exit 0
fi

# Outside-git-repo: silent no-op (gh hooks run anywhere).
git rev-parse --show-toplevel >/dev/null 2>&1 || exit 0

# Skip if CR_AUTO_PARSE_DISABLED=1 in env (operator can opt-out).
if [ "${CR_AUTO_PARSE_DISABLED:-0}" = "1" ]; then
	exit 0
fi

# Skip if gh not authed (otherwise auto-parse will spam errors).
if ! gh auth status >/dev/null 2>&1; then
	exit 0
fi

# Detach + run. Use nohup so the script survives session exit.
nohup "$AUTO_PARSE" >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
