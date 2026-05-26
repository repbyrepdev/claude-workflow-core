#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Agent
# auto-register: true
# v0.9.5 (#82) — PreToolUse guard that mechanically enforces the
# ship-pr-cycle.sh orchestrator as the entry point for the
# branch→merge flow. Without this gate, nothing prevents the agent
# from hand-rolling each stage individually (calling Phase 1 agents
# directly, invoking coderabbit review by hand, raw `gh pr merge`,
# etc.) and bypassing the convergence/budget/CR-finding logic the
# orchestrator centralizes.
#
# WHAT IT BLOCKS (when on an active feature branch with commits):
#   - Bash:   `coderabbit review` (Phase 2 hand-roll)
#   - Bash:   `gh pr merge` (merge-gate hand-roll)
#   - Bash:   `git push` of a feat/chore branch (push hand-roll —
#             optional; default OFF since orchestrator's resume now
#             also pushes, but operators do legitimate pushes too)
#   - Agent:  subagent_type prefixed `pr-review-toolkit:*` (Phase 1
#             agents fired without orchestrator's logging chain)
#
# BYPASS:
#   - SHIP_PR_CYCLE_BYPASS=1 (env OR command-string prefix) — operator
#     emergency override. Audit-logged to stderr.
#   - SKILL_WRAPPER=1 — orchestrator + wrapper scripts set this. The
#     guard honors it so ship-pr-cycle.sh's own internal calls don't
#     trigger denials.
#   - Branch not matching feat/...  | chore/... (no active feature
#     branch — guard is a no-op).
#   - ship-pr-cycle state file absent OR stage=merged (no in-flight
#     work — guard is a no-op).
#
# WHY NOT A MEMORY RULE:
# Operator framing 2026-05-26: "mechanical enforcement is NOT memory
# files. Memory is discipline-based and the agent will forget." This
# hook is specifically the tool-call-layer mechanical enforcement,
# not yet-another memory rule.

# jq load-bearing for the deny path
command -v jq >/dev/null 2>&1 || {
	echo "ship-cycle-guard: jq not found — cannot emit deny JSON" >&2
	exit 2
}

deny() {
	local reason="$1" json
	echo "ship-cycle-guard: $reason" >&2
	json=$(jq -nc --arg r "$reason" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "ship-cycle-guard: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

# Fail-closed on stdin / jq parse
if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi

# Identify tool — the payload shape differs for Bash vs Agent.
# Fail-closed on jq parse error so malformed payloads can't slip past.
if ! TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	deny "payload unparseable — failing closed"
fi

# Skill-wrapper / orchestrator bypass — honored across all tools
if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	exit 0
fi

# Operator emergency bypass — both env + command-string-prefix paths
if [ "${SHIP_PR_CYCLE_BYPASS:-0}" = "1" ]; then
	echo "ship-cycle-guard: SHIP_PR_CYCLE_BYPASS=1 (env) — passing through, audit logged" >&2
	exit 0
fi

# Helper: is the current branch an active feature/chore branch with
# in-flight ship-pr-cycle state? If NO, guard is a no-op.
_is_active_feature_branch() {
	local branch repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	branch=$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null) || return 1
	case "$branch" in
	feat/* | chore/* | fix/*) ;;
	*) return 1 ;;
	esac
	# State file under .claude/.session-state/ship-pr-cycle/<sha>.json
	# means the orchestrator has been initialized for this HEAD.
	local sha state_dir
	sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null) || return 1
	state_dir="$repo_root/.claude/.session-state/ship-pr-cycle"
	[ -f "$state_dir/$sha.json" ] || return 1
	# Skip if already merged
	local stage
	stage=$(jq -r '.stage // ""' "$state_dir/$sha.json" 2>/dev/null) || return 1
	case "$stage" in
	merged | "") return 1 ;;
	esac
	return 0
}

if ! _is_active_feature_branch; then
	exit 0 # no in-flight branch — guard inactive
fi

# Branch is active. Apply tool-specific rules.

case "$TOOL_NAME" in
Bash)
	CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""')
	if [ -z "$CMD" ]; then
		exit 0
	fi
	# Inline-prefix bypass — operator can include `SHIP_PR_CYCLE_BYPASS=1`
	# at the start of the command to bypass for that one invocation.
	if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])SHIP_PR_CYCLE_BYPASS=1([[:space:]]|;|&|$)'; then
		echo "ship-cycle-guard: SHIP_PR_CYCLE_BYPASS=1 (inline prefix) — passing through, audit logged" >&2
		exit 0
	fi
	# Phase 2 hand-roll: `coderabbit review` outside the wrapper
	if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])coderabbit[[:space:]]+review([[:space:]]|$)'; then
		# Allow the wrapper itself: scripts/cr/local-review.sh sets
		# SKILL_WRAPPER above. If we got here without it set, it's a
		# raw call.
		deny "raw 'coderabbit review' detected — use scripts/cr/local-review.sh (which the ship-pr-cycle.sh orchestrator drives at Phase 2). Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
	fi
	# Merge-gate hand-roll: `gh pr merge`
	if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
		deny "raw 'gh pr merge' detected — use .claude/skills/github-pr-merge/run.sh (which ship-pr-cycle.sh drives at the merge-gate stage). Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
	fi
	exit 0
	;;
Agent)
	SUBAGENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.subagent_type // ""')
	# Phase 1 hand-roll: pr-review-toolkit:* agent invocations.
	# The orchestrator's Phase 1 directive prints the templated prompts
	# AND fires the review-log.sh barrier. A raw Agent call skips the
	# log barrier → ship-pr-cycle stalls or double-spends rounds.
	#
	# NOTE: this is a controversial block. The orchestrator EXPECTS me
	# to fire 5 parallel Agent calls at Phase 1. So the legitimate
	# Phase 1 invocation path IS direct Agent. The guard differentiates
	# by checking whether the orchestrator's directive was logged
	# recently (within 5 minutes) — if so, the Agent call is the
	# operator following the directive; if not, it's a hand-roll.
	case "$SUBAGENT" in
	pr-review-toolkit:*)
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
		directive_log="$repo_root/.claude/.session-state/ship-pr-cycle/phase1-directive-pending.txt"
		if [ -f "$directive_log" ]; then
			# Orchestrator has just emitted a Phase 1 directive —
			# this Agent call is the operator following it. Allow.
			# Sentinel is cleared by review-log.sh barrier on
			# completion.
			exit 0
		fi
		deny "raw pr-review-toolkit:$SUBAGENT Agent call detected outside an active Phase 1 directive — invoke 'ship-pr-cycle.sh next' first; the orchestrator emits a templated prompt + creates the directive-pending sentinel. Bypass: SHIP_PR_CYCLE_BYPASS=1 env (not inline — Agent has no command-string for prefix)."
		;;
	esac
	exit 0
	;;
*)
	exit 0
	;;
esac
