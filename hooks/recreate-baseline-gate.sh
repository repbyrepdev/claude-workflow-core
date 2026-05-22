#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# v4.27 (#632) item #15 — PreToolUse Bash gate: refuse raw `docker compose
# recreate` / `up --force-recreate` invocations unless a recent
# health-check baseline exists.
#
# WHY: post-merge-deploy.sh captures a baseline before recreating stacks
# (via v4.27 #15 wire-in), so post-deploy regressions can be diffed.
# But ad-hoc raw `docker compose up --force-recreate` from the operator
# bypasses that — the running state changes with no baseline to compare
# against, and "wait, did this container break BEFORE I recreated?" is
# unanswerable. This gate forces the baseline capture.
#
# ESCAPE HATCH: HEALTH_CHECK_GATE_SKIP=1 (when running cold-boot or in
# scenarios where no comparison is desired).

command -v jq >/dev/null 2>&1 || {
	echo "recreate-baseline-gate: jq not found — cannot emit deny JSON, exiting" >&2
	exit 2
}

deny() {
	local reason="$1" json
	echo "recreate-baseline-gate: $reason" >&2
	json=$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || exit 2
	printf '%s\n' "$json"
	exit 0
}

INPUT=$(cat 2>/dev/null || echo "{}")
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# Match `docker compose up --force-recreate` OR `docker compose recreate`.
# Anchored to command-start or shell separator to avoid quoted-string fires.
# Accept optional env-var assignment prefixes (e.g., POST_MERGE_DEPLOY_BASELINE_CAPTURED=1 docker ...).
if ! printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*docker[[:space:]]+compose([[:space:]]+[^[:space:]]+)*[[:space:]]+(up[[:space:]]+([^[:space:]]+[[:space:]]+)*--force-recreate|recreate)'; then
	exit 0
fi

# Skip if invoked by post-merge-deploy.sh (it captured baseline before
# recreating). Detect via env var that recreate-stacks.sh sets.
if [ "${POST_MERGE_DEPLOY_BASELINE_CAPTURED:-0}" = "1" ]; then
	exit 0
fi

# Env override.
if [ "${HEALTH_CHECK_GATE_SKIP:-0}" = "1" ]; then
	echo "recreate-baseline-gate: HEALTH_CHECK_GATE_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
LOG_DIR="$REPO_ROOT/.claude/logs/health-check"

# Check for any baseline captured in the last 5 minutes (heuristic: if
# operator just ran health-check.sh --mode=baseline, the recreate is
# legitimate-with-baseline).
recent=""
if [ -d "$LOG_DIR" ]; then
	# Find baseline files modified within the last 5 minutes. Use -mmin -5
	# (portable across macOS + GNU find) instead of -newermt with a date
	# string — the latter mixes local/UTC parsing depending on platform
	# and was returning stale files as "recent".
	recent=$(find "$LOG_DIR" -maxdepth 1 -name '*.txt' -mmin -5 2>/dev/null | head -1 || echo "")
fi

if [ -z "$recent" ]; then
	deny "🛑 docker compose recreate / up --force-recreate without recent health-check baseline. Run \`scripts/health-check.sh --mode=baseline --label=manual\` first so post-deploy regressions can be diffed. Override: HEALTH_CHECK_GATE_SKIP=1 <your-command> (use only for cold boots)."
fi

exit 0
