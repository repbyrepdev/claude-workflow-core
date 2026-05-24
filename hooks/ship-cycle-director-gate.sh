#!/bin/bash
set -euo pipefail
# event: PreToolUse Bash
# auto-register: true
# v0.8.4 (#63) — ship-pr-cycle director-gate.
#
# Refuses workflow-critical Bash commands unless the current ship-pr-cycle
# stage permits them. Forces operator to call `ship-pr-cycle.sh next` so
# the cycle remains the single director of every transition.
#
# Why: PR #59 dogfood showed operator (Claude) repeatedly fired
# `coderabbit review`, `git push`, `gh pr merge`, and Phase 1 agents
# WITHOUT first asking the cycle what stage allowed them. Burned ~4
# hours + 3+ CR-budget cycles on a single-line pin-bump PR. The
# cycle's directive surfacing was ambiguous (CONVERGED signal buried
# by boilerplate); a PreToolUse refusal is the only reliable enforcement.
#
# Refusal patterns + graduation-aware behavior:
#
#   COMMAND PATTERN                | Marker absent (not graduated) | Marker present (graduated)
#   coderabbit review              | REFUSE — phase1 first         | OK at stage=phase2
#   scripts/cr/local-review.sh     | REFUSE                        | OK at stage=phase2
#   git push                       | REFUSE                        | OK at stage=push (pre-push-gate)
#   gh pr merge                    | REFUSE                        | OK at stage=merge-gate
#   pr-review-toolkit:* agents     | WARN if stage != phase1       | WARN if graduated
#   git commit                     | OK (commit always allowed)    | OK
#
# Refusal message ALWAYS quotes:  Run `ship-pr-cycle.sh next` first.
#
# Sanctioned wrapper:  SKILL_WRAPPER=1 from skill run.sh wrappers is honored
# (skill internal cycle calls). Emergency bypass: SHIP_CYCLE_GATE_SKIP=1
# (audit-logged).
#
# Input: PreToolUse JSON on stdin with .tool_input.command.
# Output: rc=0 to allow; rc=2 + stderr to deny.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Read tool_input.command from PreToolUse stdin (jq required; if missing, fail-open with warning to stderr).
read_command() {
	if ! command -v jq >/dev/null 2>&1; then
		echo "ship-cycle-director-gate: WARN — jq missing, fail-open" >&2
		exit 0
	fi
	jq -r '.tool_input.command // ""' 2>/dev/null || echo ""
}

# Honored bypasses (audit-logged).
if [ "${SHIP_CYCLE_GATE_SKIP:-0}" = "1" ]; then
	mkdir -p "$REPO_ROOT/.claude/logs"
	printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "SHIP_CYCLE_GATE_SKIP=1" \
		>>"$REPO_ROOT/.claude/logs/ship-cycle-gate-skip.jsonl"
	exit 0
fi
if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	# Sanctioned skill-internal invocation — skip the gate.
	exit 0
fi

CMD=$(read_command)
[ -z "$CMD" ] && exit 0

# Detect command category.
# Use word-boundary matching to avoid false-positives on substrings.
case "$CMD" in
*"coderabbit review"* | *"scripts/cr/local-review.sh"*)
	CATEGORY="cr-cli"
	;;
*"gh pr merge"*)
	CATEGORY="merge"
	;;
*"git push"*)
	CATEGORY="push"
	;;
*) exit 0 ;;
esac

# Resolve current cycle stage.
sha=$(git rev-parse HEAD 2>/dev/null || echo "")
sf="$REPO_ROOT/.claude/.session-state/ship-cycle/$sha.json"
STAGE=""
if [ -n "$sha" ] && [ -f "$sf" ] && command -v jq >/dev/null 2>&1; then
	STAGE=$(jq -r '.stage // ""' "$sf" 2>/dev/null || echo "")
fi

# Resolve graduation marker.
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
GRAD=""
if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
	# Find graduation marker by safe-name. Look for any *.json file
	# under phase-graduation/ that contains a matching .branch field.
	if [ -d "$REPO_ROOT/.claude/.session-state/phase-graduation" ] && command -v jq >/dev/null 2>&1; then
		for f in "$REPO_ROOT/.claude/.session-state/phase-graduation"/*.json; do
			[ -f "$f" ] || continue
			b=$(jq -r '.branch // ""' "$f" 2>/dev/null)
			if [ "$b" = "$branch" ]; then
				GRAD="yes"
				break
			fi
		done
	fi
fi

# Decision matrix.
allow=0
deny_reason=""
case "$CATEGORY" in
cr-cli)
	if [ "$GRAD" = "yes" ] && [ "$STAGE" = "phase2" ]; then
		allow=1
	else
		deny_reason="CR-CLI requires cycle stage=phase2 (current=$STAGE, graduated=${GRAD:-no})."
	fi
	;;
push)
	if [ "$STAGE" = "push" ]; then
		allow=1
	else
		deny_reason="git push requires cycle stage=push (current=$STAGE)."
	fi
	;;
merge)
	if [ "$STAGE" = "merge-gate" ]; then
		allow=1
	else
		deny_reason="gh pr merge requires cycle stage=merge-gate (current=$STAGE)."
	fi
	;;
esac

if [ "$allow" = "1" ]; then
	exit 0
fi

cat >&2 <<EOF
BLOCKED by ship-cycle-director-gate: $deny_reason

Run \`.claude/skills/ship-pr-cycle/run.sh next\` first to confirm the next step.
Or invoke via the matching skill wrapper:
  - CR-CLI:  github-pr-creation skill (auto-fires CR-CLI at phase2)
  - push:    handled by ship-pr-cycle.sh next at stage=push
  - merge:   github-pr-merge skill at stage=merge-gate

Bypass (audit-logged):  SHIP_CYCLE_GATE_SKIP=1 <cmd>
Sanctioned skill internal: SKILL_WRAPPER=1 <cmd>
EOF
exit 2
