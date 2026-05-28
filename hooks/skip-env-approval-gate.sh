#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# auto-register: true
# v0.28.0 (#178) — mechanical per-call user-approval gate for ALL
# `*_SKIP=1`-style workflow bypass env vars.
#
# WHY: workflow gates (LINT_GATE_SKIP, TEST_GATE_SKIP, PIPELINE_GATE_SKIP,
# PHASE1_DIRECTIVE_GUARD_SKIP, MEMORY_DRIFT_GATE_SKIP, HOOK_ACK_CLEAR,
# SHIP_PR_CYCLE_BYPASS, etc.) exist because they paper over enforcement
# gaps when the underlying fix is too invasive in-the-moment. The intent
# is "operator-authorized escape hatch with audit log". In practice
# Claude-driven sessions slip skips through without the operator
# noticing — the post-PR cleanup work then accumulates as the "stuff
# that was skipped." User feedback 2026-05-28: every use must require
# explicit per-call approval, not session-wide grant.
#
# This hook fires on PreToolUse Bash. If the command starts with one or
# more `*_SKIP=N` (or `*_BYPASS=N` / `HOOK_ACK_CLEAR=N`) env-var prefixes,
# the hook refuses with a structured deny message that explains what
# skip was attempted and prompts the operator to authorize via a popup
# (AskUserQuestion). Approval is per-PID-keyed and consumed-on-use, so
# the operator can't accidentally grant a session-wide bypass.
#
# Approval state: $REPO_ROOT/.claude/.session-state/skip-approvals/${HASH}.txt
#   HASH = sha256(skip_var_name + cmd_first-50chars)
#   File contains: timestamp + skip-var + 50-char cmd preview
#   File is consumed (rm) on first hook fire that matches.
#
# Audit log: $REPO_ROOT/.claude/logs/skip-approvals.jsonl
#   Every approval grant, denial, and use is logged.
#
# Bypass-the-gate (operator-only, audit-logged):
#   SKIP_ENV_APPROVAL_BYPASS=1 <cmd>  — itself a SKIP, so it's recursively
#   intercepted unless the recursion-guard env SKIP_APPROVAL_GATE_RECURSED=1
#   is set (operator-only, not for Claude to set).

# Recursion guard — operator-set ONLY.
if [ "${SKIP_APPROVAL_GATE_RECURSED:-0}" = "1" ]; then
	exit 0
fi

# Resolve payload from $CLAUDE_PROJECT_DIR-style stdin if present.
PAYLOAD=""
if [ ! -t 0 ]; then
	PAYLOAD=$(cat 2>/dev/null || true)
fi
if [ -z "$PAYLOAD" ]; then
	# Nothing to evaluate — let it through.
	exit 0
fi

# Extract the Bash command.
CMD=""
if command -v jq >/dev/null 2>&1; then
	CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || true)
fi
[ -z "$CMD" ] && exit 0

# Recognized skip-style env-var name patterns. Matches:
#   *_SKIP=<anything>     workflow gate skips
#   *_BYPASS=<anything>   alternate naming
#   HOOK_ACK_CLEAR=<anything>  the orphan-cleanup escape
#   *_GATE_SKIP=<anything>  more explicit form
# All must be at command START, optionally preceded by other env-vars
# (same anchored-regex approach as ship-cycle-director-gate.sh Layer 4).
#
# Use bash regex against the whole string (string-anchored, not line-
# anchored). Capture the SKIP var name so we can show it in the deny.
SKIP_VAR=""
SKIP_RE='^([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*([A-Z_][A-Z0-9_]*(_SKIP|_BYPASS|HOOK_ACK_CLEAR))=[^[:space:]]+'
if [[ $CMD =~ $SKIP_RE ]]; then
	# Walk through env-prefix tokens to find which one is the skip-var.
	# Take the first token in CMD that matches *_SKIP / *_BYPASS / HOOK_ACK_CLEAR.
	for tok in $CMD; do
		case "$tok" in
		HOOK_ACK_CLEAR=* | *_SKIP=* | *_BYPASS=*)
			SKIP_VAR="${tok%%=*}"
			break
			;;
		*=*) continue ;;
		*) break ;;
		esac
	done
fi

# No skip detected — let it through.
[ -z "$SKIP_VAR" ] && exit 0

# Approval-state machinery.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="$PWD"
APPROVAL_DIR="$REPO_ROOT/.claude/.session-state/skip-approvals"
LOG_DIR="$REPO_ROOT/.claude/logs"
LOG_FILE="$LOG_DIR/skip-approvals.jsonl"
mkdir -p "$APPROVAL_DIR" "$LOG_DIR" 2>/dev/null || true

# Hash the skip-var + first 50 chars of cmd → approval-state filename.
# Per-invocation: operator approving SKIP_X for cmd-A doesn't grant
# approval for SKIP_X on cmd-B.
CMD_PREVIEW=$(printf '%s' "$CMD" | head -c 50)
HASH_INPUT="${SKIP_VAR}|${CMD_PREVIEW}"
if command -v sha256sum >/dev/null 2>&1; then
	HASH=$(printf '%s' "$HASH_INPUT" | sha256sum | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
	HASH=$(printf '%s' "$HASH_INPUT" | shasum -a 256 | awk '{print $1}')
else
	# No hash binary — fall back to refusing rather than fail-open.
	echo "skip-env-approval-gate: ERROR sha256sum/shasum missing — refusing skip" >&2
	exit 2
fi
APPROVAL_FILE="$APPROVAL_DIR/$HASH.txt"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# If a per-call approval file exists, consume it + let through.
if [ -f "$APPROVAL_FILE" ]; then
	rm -f "$APPROVAL_FILE" 2>/dev/null || true
	if command -v jq >/dev/null 2>&1; then
		jq -nc --arg ts "$TS" --arg var "$SKIP_VAR" --arg cmd "$CMD_PREVIEW" \
			'{ts:$ts, event:"approval-used", skip_var:$var, cmd_preview:$cmd}' \
			>>"$LOG_FILE" 2>/dev/null || true
	fi
	echo "skip-env-approval-gate: approval consumed for $SKIP_VAR" >&2
	exit 0
fi

# No approval — refuse with a structured deny so the operator sees what
# was attempted + can grant per-call approval via the AskUserQuestion
# flow the assistant should now invoke.
if command -v jq >/dev/null 2>&1; then
	jq -nc --arg ts "$TS" --arg var "$SKIP_VAR" --arg cmd "$CMD_PREVIEW" --arg hash "$HASH" \
		'{ts:$ts, event:"refused", skip_var:$var, cmd_preview:$cmd, approval_hash:$hash}' \
		>>"$LOG_FILE" 2>/dev/null || true
fi

cat >&2 <<DENY
BLOCKED by skip-env-approval-gate: command uses workflow-skip env var.
  skip_var:    $SKIP_VAR
  cmd_preview: $CMD_PREVIEW
  approval-state path: $APPROVAL_FILE

ALL *_SKIP / *_BYPASS / HOOK_ACK_CLEAR env vars require explicit per-call
user approval. Memory rule: "feedback_use_skills_no_bypass" + user
directive 2026-05-28: "i only want you to be able to skip if i approve and
i have to approve every single time".

To grant approval for THIS exact command + skip var, ask the user via
AskUserQuestion, then on their YES write:
  touch "$APPROVAL_FILE"
and retry the command. The approval file is consumed on first use.

Audit log: $LOG_FILE
DENY

exit 2
