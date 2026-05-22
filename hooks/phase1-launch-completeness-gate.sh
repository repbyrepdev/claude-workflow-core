#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# v4.27 (#632) — PreToolUse Bash gate: refuse phase1-launcher.sh round N
# invocation when round N-1's EFFECTIVE_AGENTS aren't fully logged.
#
# WHY: phase1-launcher.sh writes a sidecar manifest of EFFECTIVE_AGENTS
# (= EXPECTED − SKIP_AGENTS − CACHED_AGENTS) per round. If round N-1 had
# 7 effective agents but only 6 logged, the prior gate (phase1-before-cr.sh)
# only fires at CR-CLI invocation time — meaning N tokens were burned on
# a partial round before discovery. This gate fails fast at the next
# launcher invocation, telling the user exactly which agent is missing.
#
# HOW: parse the round number from `phase1-launcher.sh N`. Read the
# sidecar `<sha>-round-<N-1>-effective.txt`. For each effective agent,
# verify a corresponding entry exists in `<sha>.jsonl` for round N-1.
# If any missing → deny with the specific list.
#
# ESCAPE HATCH: PHASE1_GATE_SKIP=1 (shared with phase1-before-cr.sh).
# Round 1 is always allowed (no round 0 to check).

command -v jq >/dev/null 2>&1 || {
	echo "phase1-launch-completeness-gate: jq not found — exiting" >&2
	exit 2
}

deny() {
	local reason="$1" json
	echo "phase1-launch-completeness-gate: $reason" >&2
	json=$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "phase1-launch-completeness-gate: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""'); then
	deny "payload unparseable — failing closed"
fi

# Match phase1-launcher.sh invocation. Uses SSOT cmd-prefix regex helper.
# CR #634 round 3: centralized after empty-value + env-after-assign fixes.
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_lib/cmd-prefix-regex.sh
source "$HOOK_DIR/../_lib/cmd-prefix-regex.sh"
# Two-step: first check the prefix matches (gate engages), then capture the
# round arg via a separate regex. grep -qE for engagement, [[ =~ ]] for capture.
TARGET_RE="$(cmd_prefix_target 'phase1-launcher\.sh')"
if ! printf '%s' "$CMD" | grep -qE "$TARGET_RE"; then
	exit 0
fi
# Capture optional numeric round argument.
if [[ "$CMD" =~ phase1-launcher\.sh[[:space:]]+([0-9]+) ]]; then
	ROUND="${BASH_REMATCH[1]}"
else
	ROUND=""
fi

# Env override (kept early so gate can still be bypassed during context
# resolution failures below).
if [ "${PHASE1_GATE_SKIP:-0}" = "1" ]; then
	echo "phase1-launch-completeness-gate: PHASE1_GATE_SKIP=1 — bypassing gate" >&2
	exit 0
fi

# CR #634 finding 64: do NOT fail open when context is broken — that
# disables the gate exactly when enforcement is most needed. Deny with
# a clear reason and operator can use PHASE1_GATE_SKIP=1 if legitimate.
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	deny "git rev-parse --show-toplevel failed — cannot resolve repo root. Override: PHASE1_GATE_SKIP=1."
fi
if ! SHA=$(git rev-parse HEAD 2>/dev/null) || [ -z "$SHA" ]; then
	deny "git rev-parse HEAD failed or returned empty — cannot resolve current SHA. Override: PHASE1_GATE_SKIP=1."
fi

# CR #634 finding 50: no-arg launcher invocation must still fire the gate.
# When ROUND is empty, derive it from the highest existing sidecar at
# this SHA (launcher's default-next semantic). If no sidecars exist, this
# is a legitimate fresh launch (round 1) and we let it through.
if [ -z "$ROUND" ]; then
	# CR #634 round 2 finding 81: defensive directory check + `|| true`. On
	# fresh repo (no .claude/review-log/ yet), find exits non-zero under
	# `set -euo pipefail` and aborts the gate before the round-1 fallback.
	HIGHEST=""
	if [ -d "$REPO_ROOT/.claude/review-log" ]; then
		HIGHEST=$(find "$REPO_ROOT/.claude/review-log" -maxdepth 1 \
			-name "${SHA}-round-*-effective.txt" 2>/dev/null |
			sed -E 's/.*-round-([0-9]+)-effective\.txt$/\1/' | sort -n | tail -1 || true)
	fi
	if [ -z "$HIGHEST" ]; then
		exit 0
	fi
	ROUND=$((HIGHEST + 1))
fi

# Round 1 has no predecessor — always allowed.
if [ "$ROUND" -le 1 ]; then
	exit 0
fi

PREV_ROUND=$((ROUND - 1))
SIDECAR="$REPO_ROOT/.claude/review-log/${SHA}-round-${PREV_ROUND}-effective.txt"
LOG="$REPO_ROOT/.claude/review-log/${SHA}.jsonl"

# No sidecar = launcher never ran round N-1 at this SHA. This is the
# legitimate post-fix-commit case (commit changes HEAD, prior sidecars
# were keyed to the old SHA). Skip the gate and let phase1-before-cr.sh
# handle cross-commit completeness as the backstop at CR-CLI time. The
# fail-fast gate only fires when we have evidence the launcher ran but
# left round N-1 incomplete.
if [ ! -f "$SIDECAR" ]; then
	exit 0
fi

# CR #634 finding 84: unreadable/empty sidecar should deny, not silently
# bypass — the sidecar's existence is evidence the launcher ran, so we
# must be able to read its effective-agents list. Empty file = corruption.
if [ ! -r "$SIDECAR" ]; then
	deny "Round $PREV_ROUND sidecar exists but is unreadable: $SIDECAR. Fix file permissions or remove + re-launch round $PREV_ROUND. Override: PHASE1_GATE_SKIP=1."
fi
EFFECTIVE=$(grep -v '^[[:space:]]*$' "$SIDECAR" 2>/dev/null | sort -u || true)
if [ -z "$EFFECTIVE" ]; then
	deny "Round $PREV_ROUND sidecar is empty: $SIDECAR. Sidecar should list effective agents launched. Remove + re-launch round $PREV_ROUND. Override: PHASE1_GATE_SKIP=1."
fi

# Read agents logged for round N-1 at this SHA.
if [ ! -f "$LOG" ]; then
	deny "phase1-launcher round $ROUND: no log file at $LOG, but round $PREV_ROUND was launched (sidecar exists). Run all $PREV_ROUND-effective agents and log via review-log.sh first. Override: PHASE1_GATE_SKIP=1."
fi

LOGGED=$(jq -r --arg r "$PREV_ROUND" \
	'select(.phase==1 and (.round|tostring)==$r) | .agent' "$LOG" 2>/dev/null | sort -u || true)

# comm needs sorted inputs (already sorted above). MISSING = effective − logged.
MISSING=$(comm -23 <(printf '%s\n' "$EFFECTIVE") <(printf '%s\n' "$LOGGED"))

if [ -n "$MISSING" ]; then
	MISSING_CSV=$(printf '%s\n' "$MISSING" | tr '\n' ',' | sed 's/,$//')
	deny "Round $PREV_ROUND incomplete — missing agents: $MISSING_CSV. Fire those agents + log via review-log.sh phase1 $PREV_ROUND <agent> <findings> <status>, THEN re-launch round $ROUND. (Effective set was $(printf '%s\n' "$EFFECTIVE" | wc -l | tr -d ' ') agents per the round's sidecar.) Override: PHASE1_GATE_SKIP=1."
fi

exit 0
