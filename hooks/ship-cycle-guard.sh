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
# This is a hardened-but-not-airtight mechanical boundary. The Bash
# deny path uses python3 shlex tokenization with basename + arg
# matching (the deny check now lives inside python3 — bash command-
# substitution strips NUL bytes, breaking the previous NUL-separated
# token-passing approach end-to-end). Defeats DIRECT syntactic
# bypasses from PR #82 Phase 1 security-review:
#   - `\gh pr merge`       (backslash escape)
#   - `/usr/bin/gh pr merge` (abs-path prefix → basename gh)
#   - `'gh' pr merge`      (quoted command name)
#   - `GH_TOKEN=x gh pr merge` (env-var prefix stripped)
#
# Documented residual bypass classes (NOT defeated — operator must
# rely on memory + post-hoc review to catch these):
#   - Wrapper commands: `bash -c "gh pr merge"`, `eval "gh ..."`,
#     `xargs gh pr merge`, `env gh pr merge`, `sudo gh pr merge`,
#     `command gh pr merge`. basename(first command) is bash/eval/
#     xargs/env/sudo/command, not gh. Defeating these requires
#     recursive expansion of wrapper args (tracked as follow-up).
#   - Compound chains: `true && gh pr merge`, `cmd; gh pr merge`,
#     `cmd | gh pr merge`. basename of FIRST command in the chain
#     doesn't match. (Follow-up: walk chain operators.)
#   - Command substitution: `$(echo gh) pr merge`. shlex doesn't
#     expand $(), so tokens[0] = '$(echo' (literal).
#   - python3 missing → fail-closed (denies all Bash). Hard
#     bootstrap dep.
#
# The Agent deny path validates a UUID nonce embedded in the
# orchestrator-emitted sentinel against the state JSON's
# `phase1_directive_nonce` field — `touch`-bypassing the empty
# sentinel no longer unlocks pr-review-toolkit Agent calls.
#
# Residual Agent-path threats:
#   - Single-use NOT enforced: once a valid nonce-sentinel is
#     emitted, unlimited pr-review-toolkit Agent calls succeed
#     until the orchestrator's _set_stage transition clears it.
#     Follow-up: PostToolUse counter / per-call invalidation.
#   - Nonce-replay via state-JSON read: an attacker with read
#     access to .claude/.session-state/ship-cycle/<sha>.json
#     (sibling to the sentinel, same perms) can read the nonce
#     and write a matching sentinel. The hardening defeats `touch`
#     of an empty file, not full state-dir-write access.
#   - Write-order race: orchestrator writes sentinel first, then
#     state JSON. A guard read interleaved between them sees
#     mismatch → denies (fail-closed — safe, but may produce
#     false-positive 'touch-bypass detected' messages).
#
# WHAT IT BLOCKS (when on an active feat/chore/fix branch with
# in-flight ship-pr-cycle state):
#   - Bash:   `coderabbit review` invocation (Phase 2 hand-roll)
#   - Bash:   `gh pr merge` invocation (merge-gate hand-roll)
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

# v0.34.32 (#2237): phase1 directive PROTOCOL SSOT — shared with the writer
# (scripts/ship-pr-cycle.sh). Best-effort: if absent, the Agent-path handshake
# below falls back to expecting protocol 1. Resolves ../_lib relative to THIS
# hook so it works at the plugin hooks/ layout AND a consumer .claude/hooks/.
_SCG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" 2>/dev/null && pwd || echo "")"
if [ -n "$_SCG_LIB_DIR" ] && [ -r "$_SCG_LIB_DIR/ship-cycle-protocol.sh" ]; then
	# shellcheck source=../_lib/ship-cycle-protocol.sh
	. "$_SCG_LIB_DIR/ship-cycle-protocol.sh" || true
fi

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
	state_dir="$repo_root/.claude/.session-state/ship-cycle"
	state_file="$state_dir/$sha.json"
	[ -f "$state_file" ] || return 1
	local stage
	if ! stage=$(jq -r '.stage // ""' "$state_file" 2>/dev/null); then
		export _SHIP_CYCLE_GUARD_CORRUPT_STATE=1
		return 1
	fi
	# CR PR #99 MAJOR: '' is a corrupt-state shape (missing .stage,
	# null .stage), NOT a legitimate-pass-through signal. Treating
	# it as inactive silently re-enables raw gh pr merge / coderabbit
	# review. merged → no-op (legitimate); empty → fail-closed deny.
	case "$stage" in
	merged) return 1 ;;
	"")
		export _SHIP_CYCLE_GUARD_CORRUPT_STATE=1
		return 1
		;;
	esac
	# Export for downstream Agent-path nonce lookup.
	export _SHIP_CYCLE_GUARD_REPO_ROOT="$repo_root"
	export _SHIP_CYCLE_GUARD_SHA="$sha"
	export _SHIP_CYCLE_GUARD_STATE_FILE="$state_file"
	return 0
}

if ! _is_active_feature_branch; then
	if [ "${_SHIP_CYCLE_GUARD_CORRUPT_STATE:-0}" = "1" ]; then
		deny "ship-pr-cycle state file is corrupt JSON — failing closed. Inspect .claude/.session-state/ship-cycle/<sha>.json or run 'ship-pr-cycle.sh start' to re-initialize."
	fi
	exit 0
fi

# v0.10.0 (#92): tokenize via python3 shlex.split, strip leading env-
# assignment tokens (VAR=value), basename + first-arg compare against
# deny set. Moved the deny-pattern check INTO python (Phase 1 r1:
# bash command-substitution strips NUL bytes, breaking the previous
# NUL-separated string-passing approach end-to-end). Python now
# returns the verdict directly via exit code: 0=allow, 10=coderabbit
# review, 11=gh pr merge, 12=tokenization failure (unbalanced quotes
# or no command after env-strip).
_classify_bash_command() {
	local cmd=$1
	if ! command -v python3 >/dev/null 2>&1; then
		return 12
	fi
	python3 - "$cmd" <<'PY' 2>/dev/null
import shlex
import os
import sys

try:
    tokens = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(12)

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
    sys.exit(0)  # no real command after env-strip — pass through

# basename(first_real_command) + look at next args.
cmd_basename = os.path.basename(tokens[i])
rest = tokens[i + 1:]

# Deny patterns: basename + first arg(s) match exactly.
if cmd_basename == "coderabbit" and len(rest) >= 1 and rest[0] == "review":
    sys.exit(10)
if cmd_basename == "gh" and len(rest) >= 2 and rest[0] == "pr" and rest[1] == "merge":
    sys.exit(11)

sys.exit(0)
PY
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
	# Classify via python3. Exit codes: 0=allow, 10=coderabbit-review,
	# 11=gh-pr-merge, 12=tokenize-failure. Use `|| rc=$?` form so
	# set -e doesn't abort on nonzero classification codes (per
	# feedback_rc_capture_set_e memory).
	cls_rc=0
	_classify_bash_command "$CMD" || cls_rc=$?
	case "$cls_rc" in
	0) exit 0 ;;
	10)
		deny "raw 'coderabbit review' detected (post-tokenize) — use scripts/cr/local-review.sh (which the ship-pr-cycle.sh orchestrator drives at Phase 2). Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
		;;
	11)
		deny "raw 'gh pr merge' detected (post-tokenize) — use .claude/skills/github-pr-merge/run.sh (which ship-pr-cycle.sh drives at the merge-gate stage). Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
		;;
	12)
		deny "command tokenization failed (python3 missing or unbalanced quotes) — failing closed. Install python3 or rewrite the command with balanced quoting. Bypass: SHIP_PR_CYCLE_BYPASS=1 prefix."
		;;
	*)
		deny "_classify_bash_command returned unexpected code — failing closed"
		;;
	esac
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
		sentinel="$repo_root/.claude/.session-state/ship-cycle/$sha.phase1-directive.txt"
		if [ ! -f "$sentinel" ]; then
			deny "raw $SUBAGENT Agent call detected outside an active Phase 1 directive — invoke 'ship-pr-cycle.sh next' first; the orchestrator emits a templated prompt + creates the directive-pending sentinel. Bypass: SHIP_PR_CYCLE_BYPASS=1 env."
		fi
		# v0.34.32 (#2237): PROTOCOL handshake. The sentinel exists → a
		# directive WAS emitted; but a STALE consumer driver (the #2237 root
		# cause) emits the old marker format with no protocol stamp. Detect
		# that (and any writer/reader version skew) and fail LOUD with a
		# remediation message instead of the historical silent "no nonce"
		# deadlock. Runs BEFORE the nonce checks so the actionable message wins.
		expected_protocol="${SHIP_CYCLE_PHASE1_PROTOCOL:-1}"
		if ! state_protocol=$(jq -r '.phase1_directive_protocol // "absent"' "$state_file" 2>/dev/null); then
			deny "could not read .phase1_directive_protocol from $state_file — failing closed"
		fi
		if [ "$state_protocol" != "$expected_protocol" ]; then
			if [ "$state_protocol" = "absent" ]; then
				deny "ship-pr-cycle driver is STALE — the emitted directive in $state_file carries no phase1_directive_protocol (this guard expects v$expected_protocol). Your consumer is running a frozen scripts/ship-pr-cycle.sh instead of the pinned-cache driver. Fix: bump the claude-workflow-core pin in .pre-commit-config.yaml + run scripts/refresh-from-source.sh (the v0.34.32+ wrapper resolves the pinned-cache driver automatically). Bypass: SHIP_PR_CYCLE_BYPASS=1 env."
			else
				deny "ship-pr-cycle PROTOCOL SKEW — driver wrote phase1_directive_protocol v$state_protocol but this guard expects v$expected_protocol (driver and guard are different plugin versions). Re-pin + refresh, or sync the dev-checkout. Bypass: SHIP_PR_CYCLE_BYPASS=1 env."
			fi
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
