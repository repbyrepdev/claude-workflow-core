#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Agent
# auto-register: true
# v0.9.5 (#82) — PreToolUse ADVISORY guard that nudges the agent
# toward the ship-pr-cycle.sh orchestrator as the entry point for
# the branch→merge flow. Without this gate, nothing prompts the
# agent to use the orchestrator instead of hand-rolling each stage.
#
# THREAT MODEL — read this before relying on this guard for
# anything load-bearing:
# This is an ADVISORY hook, not a security boundary. The agent has
# full control of the Bash command string and can syntactically
# evade the substring matchers (`\gh pr merge`, `eval "..."`,
# `/usr/bin/gh pr merge`, etc.) or `touch` the directive sentinel
# to unblock Agent calls. Hardening to a true mechanical boundary
# requires: (a) shell-tokenized command parsing with basename
# checks, and (b) sentinel-with-nonce validated against the
# orchestrator's state JSON. Both are tracked as follow-ups under
# epic #86 (see #90 / new sub-issue). For now the guard catches
# the COMMON case — naive hand-rolls — and surfaces a clear nudge
# toward the orchestrator. It is intentionally not a defense
# against an adversarial agent.
#
# WHAT IT BLOCKS (when on an active feat/chore/fix branch with
# in-flight ship-pr-cycle state):
#   - Bash:   `coderabbit review` (Phase 2 hand-roll)
#   - Bash:   `gh pr merge` (merge-gate hand-roll)
#   - Agent:  subagent_type prefixed `pr-review-toolkit:*` fired
#             WITHOUT the orchestrator's Phase 1 directive sentinel
#             (sentinel is created by the orchestrator when emitting
#             the directive; the hook checks file existence, not
#             freshness or provenance — see threat-model note above)
#
# BYPASS:
#   - SKILL_WRAPPER=1 (env) — orchestrator + wrapper scripts set this.
#     Audit-logged to stderr so leaked env vars are detectable.
#   - SHIP_PR_CYCLE_BYPASS=1 (env, OR command-string prefix at the
#     START of a Bash command, e.g. `SHIP_PR_CYCLE_BYPASS=1 gh pr
#     merge 91`) — operator emergency override. Audit-logged.
#     Inline-prefix form is Bash-only — Agent calls require the env
#     form (Agent has no command-string).
#   - Branch not matching `feat/...` | `chore/...` | `fix/...` (no
#     active feature branch — guard is a no-op).
#   - ship-pr-cycle state file absent OR stage=merged (no in-flight
#     work — guard is a no-op).
#
# WHY NOT A MEMORY RULE:
# Operator framing 2026-05-26: "mechanical enforcement is NOT memory
# files. Memory is discipline-based and the agent will forget." This
# hook is the tool-call-layer nudge — better than memory, weaker
# than full mechanical enforcement (which #90's follow-up will land).

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

# Skill-wrapper / orchestrator bypass — honored across all tools.
# Audit-log to stderr so leaked env vars (e.g. stale parent shell
# export) are detectable post-hoc by grepping operator output.
if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	echo "ship-cycle-guard: SKILL_WRAPPER=1 (env) — passing through (tool=${TOOL_NAME:-?}, ppid=$PPID)" >&2
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
	if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null); then
		deny "tool_input.command unparseable — failing closed"
	fi
	if [ -z "$CMD" ]; then
		exit 0
	fi
	# Inline-prefix bypass — operator can include `SHIP_PR_CYCLE_BYPASS=1`
	# ONLY at the start of the command (shell env-var assignment
	# syntax). The regex below anchors to the command start so
	# `gh pr merge 91 SHIP_PR_CYCLE_BYPASS=1` (token positioned after
	# the command) does NOT bypass — that was a regression vector
	# identified in Phase 1 security-review.
	if printf '%s' "$CMD" | grep -qE '^[[:space:]]*SHIP_PR_CYCLE_BYPASS=1[[:space:]]+'; then
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
	if ! SUBAGENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null); then
		deny "tool_input.subagent_type unparseable — failing closed"
	fi
	# Phase 1 hand-roll: pr-review-toolkit:* agent invocations.
	# The orchestrator's Phase 1 directive prints the templated prompts
	# AND fires the review-log.sh barrier. A raw Agent call skips the
	# log barrier → ship-pr-cycle stalls or double-spends rounds.
	#
	# NOTE: the orchestrator EXPECTS firing parallel Agent calls at
	# Phase 1. So the LEGITIMATE Phase 1 invocation path IS direct
	# Agent. The guard differentiates by checking for a directive
	# sentinel file the orchestrator creates when emitting Phase 1
	# directive. EXISTENCE-ONLY check: no freshness window, no
	# content/nonce validation. The sentinel is cleared by
	# review-log.sh barrier on completion. THREAT-MODEL note: this
	# is `touch`-bypassable — the agent can `touch` the sentinel
	# via a Bash tool call (touch is not in the blocklist) and
	# unblock Agent calls. Hardening to a nonce-validated sentinel
	# is tracked in follow-up under epic #86.
	case "$SUBAGENT" in
	pr-review-toolkit:*)
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
			deny "git rev-parse failed in Agent path — failing closed (branch + state checks already passed, so this is unexpected)"
		}
		directive_log="$repo_root/.claude/.session-state/ship-pr-cycle/phase1-directive-pending.txt"
		if [ -f "$directive_log" ]; then
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
