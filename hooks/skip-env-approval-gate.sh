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
#   HASH = sha256(skip_var_name + "|" + full_cmd)
#   File is a sentinel (empty); presence == approval granted.
#   File is consumed via atomic rename on first hook fire that matches.
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

# Extract the Bash command. CR fix #2: jq missing must FAIL-CLOSED (not
# fail-open) to match the user's "every use requires approval" contract.
if ! command -v jq >/dev/null 2>&1; then
	echo "skip-env-approval-gate: ERROR jq missing — refusing skip (gate cannot evaluate payload)" >&2
	exit 2
fi
# CR fix #6: jq exit status checked explicitly; on parse failure fail-CLOSED.
_jq_err=$(mktemp)
_jq_rc=0
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>"$_jq_err") || _jq_rc=$?
if [ "$_jq_rc" -ne 0 ]; then
	echo "skip-env-approval-gate: ERROR jq failed to parse PAYLOAD (rc=$_jq_rc): $(head -c 200 "$_jq_err") — refusing skip" >&2
	rm -f "$_jq_err"
	exit 2
fi
rm -f "$_jq_err"
[ -z "$CMD" ] && exit 0

# CR fix #7: quote-aware detection via bash regex on the WHOLE string.
# Prior `for tok in $CMD` word-split on IFS, breaking quoted values:
# `FOO="bar baz" LINT_GATE_SKIP=1 cmd` → tokens FOO="bar / baz" /
# LINT_GATE_SKIP=1 / cmd. The case-glob saw `baz"` (no `=`) before
# reaching LINT_GATE_SKIP=1, breaking out of the loop. Regex below
# matches env-prefix tokens where the value is either non-quote-non-space,
# OR a double-quoted string, OR a single-quoted string. Skip-var name is
# captured in BASH_REMATCH[4] without needing a post-walk.
# v0.31 #224: also catch leading whitespace + a leading `export ` prefix
# (e.g. `  LINT_GATE_SKIP=1 cmd`, `export LINT_GATE_SKIP=1; cmd`) — the old
# `^`-anchored form let both slip past the approval popup. The `(export …)?`
# group is why the skip-var name is now BASH_REMATCH[4] (was [3]).
SKIP_RE='^[[:space:]]*(export[[:space:]]+)?([A-Z_][A-Z0-9_]*=([^[:space:]"'\'']+|"[^"]*"|'\''[^'\'']*'\'')[[:space:]]+)*(HOOK_ACK_CLEAR|[A-Z_][A-Z0-9_]*_SKIP|[A-Z_][A-Z0-9_]*_BYPASS)=([^[:space:]]+|"[^"]*"|'\''[^'\'']*'\'')'
SKIP_VAR=""
if [[ $CMD =~ $SKIP_RE ]]; then
	SKIP_VAR="${BASH_REMATCH[4]}"
fi

# No skip detected — let it through.
[ -z "$SKIP_VAR" ] && exit 0

# Approval-state machinery. CR fix #3: fail-CLOSED when REPO_ROOT can't
# be resolved via git. Falling back to $PWD writes approval state to an
# arbitrary cwd — could be a peer repo or non-repo entirely, breaking
# the "per-call approval, consumed-on-use" contract.
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO_ROOT" ]; then
	echo "skip-env-approval-gate: ERROR cannot resolve REPO_ROOT (not in a git work tree) — refusing skip rather than write approval state to ambiguous location" >&2
	exit 2
fi
APPROVAL_DIR="$REPO_ROOT/.claude/.session-state/skip-approvals"
LOG_DIR="$REPO_ROOT/.claude/logs"
LOG_FILE="$LOG_DIR/skip-approvals.jsonl"
# CR fix #8: fail-closed when approval/log directories can't be created.
# Silent degradation here would tell the operator to `touch` a file in a
# location that doesn't exist + lose the audit log silently.
if ! mkdir -p "$APPROVAL_DIR" "$LOG_DIR" 2>/dev/null; then
	echo "skip-env-approval-gate: ERROR cannot create approval/log directories under $REPO_ROOT — refusing skip" >&2
	exit 2
fi

# CR fix #4: hash the FULL CMD (not just first 50 chars). Prior 50-char
# preview window let two commands sharing a prefix collide on the same
# approval file — approving X granted approval for Y. CMD_PREVIEW stays
# for logging/display only.
CMD_PREVIEW=$(printf '%s' "$CMD" | head -c 50)
HASH_INPUT="${SKIP_VAR}|${CMD}"
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

# If a per-call approval file exists, consume it + let through. CR fix #5:
# use atomic rename for consumption — `rm -f ... || true` swallowed
# failures, letting an undeletable approval file persist (effectively
# session-wide grant). Atomic mv either succeeds (file gone) or fails
# (file claimed by another concurrent fire). Only treat approval as
# consumed when the mv succeeds.
if [ -f "$APPROVAL_FILE" ]; then
	_consumed="${APPROVAL_FILE}.consumed.$$"
	if mv "$APPROVAL_FILE" "$_consumed" 2>/dev/null; then
		rm -f "$_consumed" 2>/dev/null || true
		if command -v jq >/dev/null 2>&1; then
			jq -nc --arg ts "$TS" --arg var "$SKIP_VAR" --arg cmd "$CMD_PREVIEW" \
				'{ts:$ts, event:"approval-used", skip_var:$var, cmd_preview:$cmd}' \
				>>"$LOG_FILE" 2>/dev/null || true
		fi
		echo "skip-env-approval-gate: approval consumed for $SKIP_VAR" >&2
		exit 0
	fi
	# mv failed — either undeletable (permission, immutable) OR another
	# concurrent hook fire already claimed it. Don't treat as consumed.
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
