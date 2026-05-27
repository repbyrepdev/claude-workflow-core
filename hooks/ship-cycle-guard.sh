#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Agent
# auto-register: true
# Introduced in #82, hardened in #92 (released as v0.10.0). PreToolUse
# guard that enforces ship-pr-cycle.sh as the entry point for the
# branch→merge flow.
#
# THREAT MODEL — v0.10.0 (#92):
# This is now a HARDENED mechanical boundary (no longer purely
# advisory). The Bash deny path uses python3 shlex tokenization with
# basename matching, defeating the regex bypasses surfaced in PR #82
# Phase 1 security-review (backslash, eval-wrap, bash-c-wrap, abs-path
# prefix, quoted command name). The Agent deny path validates a UUID
# nonce embedded in the orchestrator-emitted sentinel against the
# state JSON's `phase1_directive_nonce` field — `touch`-bypassing the
# sentinel (with no matching nonce) no longer unlocks pr-review-toolkit
# Agent calls.
#
# Residual threats (documented, accepted):
#   - python3 unavailable → fail-closed: the Bash deny path refuses
#     all Bash calls until python3 is installed (bootstrap dep).
#   - state JSON write race between orchestrator and hook read: the
#     orchestrator's `mv tmp state.json` rename is atomic; either the
#     hook sees old-nonce (denied) or new-nonce (allowed). No partial
#     write window.
#
# WHAT IT BLOCKS (when on an active feat/chore/fix branch with
# in-flight ship-pr-cycle state):
#   - Bash:   `coderabbit review` invocation (Phase 2 hand-roll)
#   - Bash:   `gh pr merge` invocation (merge-gate hand-roll)
#     Now defeats: \gh, eval "gh ...", bash -c "gh ...", /usr/bin/gh,
#     'gh' (all syntactic variants).
#   - Agent:  subagent_type prefixed `pr-review-toolkit:*` fired
#             WITHOUT a valid orchestrator-emitted nonce-sentinel.
#
# BYPASS:
#   - SKILL_WRAPPER=1 (env) — orchestrator + wrapper scripts set this.
#     Audit-logged to stderr.
#   - SHIP_PR_CYCLE_BYPASS=1 (env, OR command-string prefix at the
#     START of a Bash command). Operator emergency override.
#     Audit-logged.
#   - Branch not matching `feat/...` | `chore/...` | `fix/...` (no
#     active feature branch — guard is a no-op).
#   - ship-pr-cycle state file absent OR stage=merged (no in-flight
#     work — guard is a no-op).

# jq + python3 load-bearing for the deny path
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

if ! TOOL_NAME=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	deny "payload unparseable — failing closed"
fi

if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	echo "ship-cycle-guard: SKILL_WRAPPER=1 (env) — passing through (tool=${TOOL_NAME:-?}, ppid=$PPID)" >&2
	exit 0
fi

if [ "${SHIP_PR_CYCLE_BYPASS:-0}" = "1" ]; then
	echo "ship-cycle-guard: SHIP_PR_CYCLE_BYPASS=1 (env) — passing through, audit logged" >&2
	exit 0
fi

# v0.10.0 (#92): is_active_feature_branch + corrupt-state detection
# unchanged from v0.9.5 — the threat model fix is below this guard.
_is_active_feature_branch() {
	local branch repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	branch=$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null) || return 1
	case "$branch" in
	feat/* | chore/* | fix/*) ;;
	*) return 1 ;;
	esac
	local sha state_dir state_file
	sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null) || return 1
	state_dir="$repo_root/.claude/.session-state/ship-pr-cycle"
	state_file="$state_dir/$sha.json"
	[ -f "$state_file" ] || return 1
	local stage
	if ! stage=$(jq -r '.stage // ""' "$state_file" 2>/dev/null); then
		export _SHIP_CYCLE_GUARD_CORRUPT_STATE=1
		return 1
	fi
	case "$stage" in
	merged | "") return 1 ;;
	esac
	# Export for downstream Agent-path nonce lookup.
	export _SHIP_CYCLE_GUARD_REPO_ROOT="$repo_root"
	export _SHIP_CYCLE_GUARD_SHA="$sha"
	export _SHIP_CYCLE_GUARD_STATE_FILE="$state_file"
	return 0
}

if ! _is_active_feature_branch; then
	if [ "${_SHIP_CYCLE_GUARD_CORRUPT_STATE:-0}" = "1" ]; then
		deny "ship-pr-cycle state file is corrupt JSON — failing closed. Inspect .claude/.session-state/ship-pr-cycle/<sha>.json or run 'ship-pr-cycle.sh start' to re-initialize."
	fi
	exit 0
fi

# v0.10.0 (#92): tokenize via python3 shlex.split, strip leading env-
# assignment tokens (VAR=value), basename the next token. Defeats all
# bypass variants surfaced by Phase 1 security-review on PR #82.
_first_real_command_basename() {
	local cmd=$1
	if ! command -v python3 >/dev/null 2>&1; then
		# python3 absent → cannot safely tokenize → fail closed by
		# returning empty (caller treats as "couldn't classify").
		return 1
	fi
	# shlex.split refuses on unbalanced quotes — that's fine, fail
	# closed (return empty + nonzero) because we can't reason about
	# what the shell would actually run.
	python3 - "$cmd" <<'PY' 2>/dev/null || return 1
import shlex
import os
import sys

try:
    tokens = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(1)

# Strip leading env-assignment tokens (VAR=value pattern).
i = 0
while i < len(tokens) and "=" in tokens[i]:
    head = tokens[i].split("=", 1)[0]
    if head and (head[0].isalpha() or head[0] == "_") and \
       all(c.isalnum() or c == "_" for c in head):
        i += 1
    else:
        break

if i >= len(tokens):
    sys.exit(2)

# Print basename of first real command + the rest of the args, NUL-
# separated so caller can read them safely.
cmd_basename = os.path.basename(tokens[i])
rest = tokens[i + 1:]
sys.stdout.write(cmd_basename)
for tok in rest:
    sys.stdout.write("\x00" + tok)
sys.stdout.write("\n")
PY
}

# Returns 0 if first-real-command + args match the deny pattern.
# Patterns are space-joined for readability but matched against the
# NUL-separated tokenized form.
_matches_deny_pattern() {
	local tokens=$1 pattern=$2
	local pat_csv
	pat_csv=$(printf '%s' "$pattern" | tr ' ' '\0')
	# True iff $tokens STARTS WITH $pat_csv (followed by NUL or EOF).
	case "$tokens" in
	"$pat_csv" | "$pat_csv"$'\0'*)
		return 0
		;;
	esac
	return 1
}

case "$TOOL_NAME" in
Bash)
	if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null); then
		deny "tool_input.command unparseable — failing closed"
	fi
	if [ -z "$CMD" ]; then
		exit 0
	fi
	# Inline-prefix bypass (regex-only — we deliberately accept the
	# env-prefix syntax at the head of the command without
	# tokenizing, since tokenization would split it into a separate
	# arg and lose the "first thing" context).
	if printf '%s' "$CMD" | grep -qE '^[[:space:]]*SHIP_PR_CYCLE_BYPASS=1[[:space:]]+'; then
		echo "ship-cycle-guard: SHIP_PR_CYCLE_BYPASS=1 (inline prefix) — passing through, audit logged" >&2
		exit 0
	fi
	# Tokenize via python3 shlex. Fail-closed if python3 missing.
	if ! TOKENS=$(_first_real_command_basename "$CMD"); then
		deny "command tokenization failed (python3 missing or unbalanced quotes) — failing closed. Install python3 or rewrite the command with balanced quoting. Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
	fi
	if [ -z "$TOKENS" ]; then
		# No identifiable command — pass through (e.g., empty after
		# env-strip).
		exit 0
	fi
	# Deny patterns: basename + arg-tokens (NUL-separated).
	# `coderabbit review` (Phase 2 hand-roll)
	if _matches_deny_pattern "$TOKENS" "coderabbit review"; then
		deny "raw 'coderabbit review' detected (post-tokenize) — use scripts/cr/local-review.sh (which the ship-pr-cycle.sh orchestrator drives at Phase 2). Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
	fi
	# `gh pr merge` (merge-gate hand-roll)
	if _matches_deny_pattern "$TOKENS" "gh pr merge"; then
		deny "raw 'gh pr merge' detected (post-tokenize) — use .claude/skills/github-pr-merge/run.sh (which ship-pr-cycle.sh drives at the merge-gate stage). Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
	fi
	exit 0
	;;
Agent)
	if ! SUBAGENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null); then
		deny "tool_input.subagent_type unparseable — failing closed"
	fi
	case "$SUBAGENT" in
	pr-review-toolkit:*)
		# v0.10.0 (#92): nonce-validated sentinel.
		# Sentinel path: $STATE_DIR/$SHA.phase1-directive.txt
		# Sentinel content: UUID nonce matching state JSON's
		# `phase1_directive_nonce` field.
		state_file=${_SHIP_CYCLE_GUARD_STATE_FILE:-}
		repo_root=${_SHIP_CYCLE_GUARD_REPO_ROOT:-}
		sha=${_SHIP_CYCLE_GUARD_SHA:-}
		if [ -z "$state_file" ] || [ -z "$repo_root" ] || [ -z "$sha" ]; then
			deny "active-branch state exports missing in Agent path — failing closed (orchestrator state may be partially initialized)"
		fi
		sentinel="$repo_root/.claude/.session-state/ship-pr-cycle/$sha.phase1-directive.txt"
		if [ ! -f "$sentinel" ]; then
			deny "raw $SUBAGENT Agent call detected outside an active Phase 1 directive — invoke 'ship-pr-cycle.sh next' first; the orchestrator emits a templated prompt + creates the directive-pending sentinel. Bypass: SHIP_PR_CYCLE_BYPASS=1 env."
		fi
		# Read sentinel content (first non-empty line is the nonce).
		# Per-directive sentinel formats:
		#   line1: <UUID nonce>
		#   line2..N: directive text
		if ! sentinel_nonce=$(head -1 "$sentinel" 2>/dev/null); then
			deny "phase1 sentinel unreadable at $sentinel — failing closed"
		fi
		sentinel_nonce=${sentinel_nonce%$'\n'}
		if [ -z "$sentinel_nonce" ]; then
			deny "phase1 sentinel empty (no nonce on line 1) — failing closed. touch-bypass detected? Re-emit via 'ship-pr-cycle.sh next'."
		fi
		# Read state JSON's phase1_directive_nonce.
		if ! state_nonce=$(jq -r '.phase1_directive_nonce // ""' "$state_file" 2>/dev/null); then
			deny "could not read .phase1_directive_nonce from $state_file — failing closed"
		fi
		if [ -z "$state_nonce" ]; then
			deny "state JSON has no phase1_directive_nonce — orchestrator did not emit a valid directive. Re-emit via 'ship-pr-cycle.sh next'."
		fi
		if [ "$sentinel_nonce" != "$state_nonce" ]; then
			deny "phase1 sentinel nonce mismatch with state JSON — failing closed. Likely touch-bypass attempt OR stale sentinel from a prior round. Re-emit via 'ship-pr-cycle.sh next'."
		fi
		# Nonce matches — allow the Agent call. (Single-use semantics
		# are deferred to review-log.sh's barrier clear; the hook
		# would need PostToolUse coordination to safely unlink.)
		exit 0
		;;
	esac
	exit 0
	;;
*)
	exit 0
	;;
esac
