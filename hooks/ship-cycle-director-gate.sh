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
# Why: operator (Claude) repeatedly fired `coderabbit review`, `git push`,
# `gh pr merge`, and Phase 1 agents WITHOUT first asking the cycle what
# stage allowed them. Burned 4+ hours + 3+ CR-budget cycles on a single-
# line pin-bump PR (FCP #59 dogfood, 2026-05). The cycle's directive
# surfacing was ambiguous (CONVERGED signal buried by boilerplate);
# a PreToolUse refusal is the only reliable enforcement.
#
# Refusal patterns + graduation-aware behavior:
#
#   COMMAND PATTERN              | not-graduated     | graduated
#   coderabbit review            | REFUSE            | OK at stage=phase2
#   scripts/cr/local-review.sh   | REFUSE            | OK at stage=phase2
#   git push                     | REFUSE            | OK at stage=push
#   gh pr merge                  | REFUSE            | OK at stage=merge-gate
#
# Other commands (git commit, agent invocations, etc.) are not matched
# by the case statement below and exit silently rc=0. The decision-matrix
# stops here — substring match, not word-boundary, so `echo 'git push docs'`
# would also trigger; the trade-off is acceptable because PreToolUse only
# fires on actual command invocations, not file contents.
#
# Refusal stderr ALWAYS quotes the literal directive:
#   Run `.claude/skills/ship-pr-cycle/run.sh next` first.
#
# Bypasses (both audit-logged to .claude/logs/ship-cycle-gate-skip.jsonl
# with the bypassed command captured):
#   - SHIP_CYCLE_GATE_SKIP=1 — emergency override
#   - SKILL_WRAPPER=1 — sanctioned skill-internal invocation
#
# Fail-open chosen for: jq missing, malformed PreToolUse stdin, git failure.
# Rationale: a security-adjacent hook that fails CLOSED on infra glitches
# locks the operator out of ALL Bash. Trade-off: fail-open emits an audible
# WARN on stderr so the failure mode is visible, not silent.
#
# Input:  PreToolUse JSON on stdin with .tool_input.command.
# Output: rc=0 to allow; rc=2 + stderr to deny; rc=0 with stderr WARN on
#         infrastructure failure (jq missing, malformed stdin, etc.).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_DIR="$REPO_ROOT/.claude/logs"
AUDIT_LOG="$LOG_DIR/ship-cycle-gate-skip.jsonl"

# v0.8.4 CR r1 F1/F4 fix: jq-missing check at top level (not inside a
# subshell-invoked function), so `exit 0` actually exits the script.
if ! command -v jq >/dev/null 2>&1; then
	echo "ship-cycle-director-gate: WARN — jq missing, fail-open" >&2
	exit 0
fi

# JSON-line audit log helper. Always emits valid JSONL so consumers
# (memory-consolidate, retro, capture-signal) can jq-walk the file.
_audit() {
	local event="$1" cmd="$2"
	mkdir -p "$LOG_DIR"
	local cmd_json
	cmd_json=$(printf '%s' "$cmd" | jq -Rs . 2>/dev/null || printf '"%s"' "<jq-quote-failed>")
	printf '{"ts":"%s","event":"%s","cmd":%s}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$cmd_json" >>"$AUDIT_LOG"
}

# Read stdin once. jq stderr captured so we can WARN on malformed input
# (the prior fail-silent path would let dangerous commands through with
# no diagnostic).
INPUT=$(cat)
jq_err=$(mktemp -t scgate-jq.XXXXXX) || jq_err="/dev/null"
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>"$jq_err") || {
	[ -s "$jq_err" ] && echo "ship-cycle-director-gate: WARN — malformed PreToolUse JSON (jq err): $(head -c 200 "$jq_err") — fail-open" >&2
	[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
	exit 0
}
[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
[ -z "$CMD" ] && exit 0

# Honored bypasses (BOTH audit-logged with command captured, per F6/F7).
if [ "${SHIP_CYCLE_GATE_SKIP:-0}" = "1" ]; then
	_audit "SHIP_CYCLE_GATE_SKIP" "$CMD"
	exit 0
fi
if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	# Sanctioned but still logged so 'why didn't the gate fire' is answerable.
	_audit "SKILL_WRAPPER" "$CMD"
	exit 0
fi

# Detect command category.
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
if [ -n "$sha" ] && [ -f "$sf" ]; then
	stage_err=$(mktemp -t scgate-stage.XXXXXX) || stage_err="/dev/null"
	STAGE=$(jq -r '.stage // ""' "$sf" 2>"$stage_err") || {
		[ -s "$stage_err" ] && echo "ship-cycle-director-gate: WARN — state file $sf unparseable: $(head -c 200 "$stage_err")" >&2
		STAGE=""
	}
	[ "$stage_err" != "/dev/null" ] && rm -f "$stage_err"
fi

# Resolve graduation marker via the SSOT library (F2/F4 fix — was
# reimplementing the lookup via glob+jq).
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
GRAD=""
if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
	grad_lib="$REPO_ROOT/_lib/phase-graduation.sh"
	# Cache-resolved plugin path fallback for consumer repos where
	# _lib/ lives under .claude/plugins/cache/...
	if [ ! -f "$grad_lib" ]; then
		grad_lib=$(find "$HOME/.claude/plugins/cache/claude-workflow-core" \
			-maxdepth 4 -type f -name "phase-graduation.sh" 2>/dev/null | head -1)
	fi
	if [ -n "$grad_lib" ] && [ -f "$grad_lib" ]; then
		# Subshell isolation: any source/parse error inside the lib
		# cannot abort the gate script. rc=0 from graduation_check means
		# graduated; rc=1 means not graduated (silent); rc>1 means lib
		# error (surface stderr).
		grad_err=$(mktemp -t scgate-grad.XXXXXX) || grad_err="/dev/null"
		grc=0
		(
			# shellcheck source=/dev/null
			. "$grad_lib" 2>/dev/null
			command -v graduation_check >/dev/null 2>&1 || exit 99
			graduation_check "$branch"
		) 2>"$grad_err" || grc=$?
		if [ "$grc" -eq 0 ]; then
			GRAD="yes"
		elif [ "$grc" -gt 1 ] && [ -s "$grad_err" ]; then
			echo "ship-cycle-director-gate: WARN — graduation_check rc=$grc: $(head -c 200 "$grad_err")" >&2
		fi
		[ "$grad_err" != "/dev/null" ] && rm -f "$grad_err"
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
		deny_reason="CR-CLI requires cycle stage=phase2 (current=${STAGE:-<unset>}, graduated=${GRAD:-no})."
	fi
	;;
push)
	if [ "$STAGE" = "push" ]; then
		allow=1
	else
		deny_reason="git push requires cycle stage=push (current=${STAGE:-<unset>})."
	fi
	;;
merge)
	if [ "$STAGE" = "merge-gate" ]; then
		allow=1
	else
		deny_reason="gh pr merge requires cycle stage=merge-gate (current=${STAGE:-<unset>})."
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

Bypasses (audit-logged):  SHIP_CYCLE_GATE_SKIP=1 <cmd>  |  SKILL_WRAPPER=1 <cmd>
EOF
exit 2
