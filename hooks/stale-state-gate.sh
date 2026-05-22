#!/bin/bash
set -u
# NOTE: `set -u` only — no `-eo pipefail`. Multiple early-out `exit 0`
# paths (no sentinel, sentinel empty, Read tool, HOOK_ACK_CLEAR=1) make
# `set -e` actively wrong here. Critical paths have explicit error
# checks (jq rc, hook_deny on parse failure). set -u catches unset-var
# typos in the matcher routing without forcing exit-on-error.
# event: PreToolUse
# matcher: Bash|Edit|Write|MultiEdit
# v4.28-W3-C — universal hook-output acknowledgment gate.
#
# Reads .claude/.session-state/hook-output-pending.txt (written by any
# hook calling _lib/hook-ack.sh:hook_ack_append). If non-empty, BLOCKS
# the next Bash/Edit/Write/MultiEdit tool call with deny-JSON listing
# the un-acknowledged events.
#
# Cleared by: PostToolUse Read on the file_path in each entry (.claude/
# hooks/hook-ack-clear.sh) — when file_path is non-empty. Entries with
# empty file_path (rare; produced by hooks that ack without a diagnostic
# file) CANNOT be cleared via Read on a specific path — they require
# wholesale clear via HOOK_ACK_CLEAR=1. (v4.30 #706)
#
# Why: hooks emit stderr/JSON-context but the operator (Claude) reads
# past them and runs the next tool action without acknowledging. This
# forces a hard stop until the relevant file is Read.

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DENY="$HOOK_DIR/../_lib/hook-deny.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
SENTINEL="$REPO_ROOT/.claude/.session-state/hook-output-pending.txt"

# Migrate three legacy sentinel filenames (shfmt-stale.txt,
# stale-files.txt, lint-pending-acknowledge.txt — intermediate names
# from earlier in this PR) into the unified sentinel.
#
# v4.28-W4 #851 r1 (#705 Phase 3 Task 2): hot-path short-circuit.
# stale-state-gate fires on EVERY PreToolUse Bash/Edit/Write — without
# this guard, each invocation runs 3 stat calls + cmp + per-file
# `[ -f $legacy ]` even when migration is complete (the common case
# on any machine that's run a recent commit). One up-front 3-way OR
# collapses the cost to a single triple-stat for the empty path.
_LEGACY_A="$REPO_ROOT/.claude/.session-state/shfmt-stale.txt"
_LEGACY_B="$REPO_ROOT/.claude/.session-state/stale-files.txt"
_LEGACY_C="$REPO_ROOT/.claude/.session-state/lint-pending-acknowledge.txt"
if [ ! -f "$_LEGACY_A" ] && [ ! -f "$_LEGACY_B" ] && [ ! -f "$_LEGACY_C" ]; then
	_legacy_migration_skip=1
fi
for legacy in "$_LEGACY_A" "$_LEGACY_B" "$_LEGACY_C"; do
	[ "${_legacy_migration_skip:-0}" = "1" ] && break
	if [ -f "$legacy" ]; then
		mkdir -p "$(dirname "$SENTINEL")" 2>/dev/null || true
		# Convert legacy plain-path lines to the new tab-separated format.
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			# Already-formatted (4 tab fields)? Pass through.
			case "$line" in
			*$'\t'*$'\t'*$'\t'*) printf '%s\n' "$line" >>"$SENTINEL" ;;
			*) printf '%s\t%s\t%s\t%s\n' \
				"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "legacy" "migrated" "$line" >>"$SENTINEL" ;;
			esac
		done <"$legacy"
		rm -f "$legacy"
	fi
done

[ -f "$SENTINEL" ] || exit 0
[ -s "$SENTINEL" ] || exit 0

# Bypass: HOOK_ACK_CLEAR=1 wholesale-clear (audit-logged).
PAYLOAD=$(cat 2>/dev/null || echo "{}")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Allow Read tool calls to pass through unblocked — that's HOW the
# acknowledgment happens. Otherwise we'd deadlock (gate refuses Read,
# operator can't Read to clear the gate).
[ "$TOOL" = "Read" ] && exit 0

if [ "${HOOK_ACK_CLEAR:-0}" = "1" ] ||
	printf '%s' "$CMD" | grep -qE '(^|[;&|])[[:space:]]*HOOK_ACK_CLEAR=1[[:space:]]+'; then
	# v4.28-W4 (#680 F4): refuse the bypass if audit-log can't be
	# written. Prior `2>/dev/null || true` swallowed write failures
	# while the user-facing message claimed "audit-logged" — defeating
	# the audit trail. Now: surface mkdir/jq failures + refuse to
	# wholesale-clear when audit is unrecorded (operator can re-run
	# after fixing the underlying issue).
	if ! mkdir -p "$REPO_ROOT/.claude/logs"; then
		echo "stale-state-gate: HOOK_ACK_CLEAR=1 audit FAILED — cannot create $REPO_ROOT/.claude/logs (refusing bypass to preserve audit trail)" >&2
		exit 2
	fi
	if ! jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg files "$(awk -F'\t' '{print $4}' "$SENTINEL" | tr '\n' ',')" \
		'{ts: $ts, kind: "hook-ack-clear", cleared_files: $files}' \
		>>"$REPO_ROOT/.claude/logs/hook-ack-skip.jsonl"; then
		echo "stale-state-gate: HOOK_ACK_CLEAR=1 audit FAILED — jq/write to hook-ack-skip.jsonl errored (refusing bypass to preserve audit trail)" >&2
		exit 2
	fi
	echo "stale-state-gate: HOOK_ACK_CLEAR=1 — wholesale-clearing $(wc -l <"$SENTINEL" | tr -d ' ') pending acks (audit logged to .claude/logs/hook-ack-skip.jsonl)" >&2
	: >"$SENTINEL"
	exit 0
fi

pending_count=$(wc -l <"$SENTINEL" | tr -d ' ')
first_entry=$(head -1 "$SENTINEL")
first_hook=$(printf '%s' "$first_entry" | awk -F'\t' '{print $2}')
first_reason=$(printf '%s' "$first_entry" | awk -F'\t' '{print $3}')
first_path=$(printf '%s' "$first_entry" | awk -F'\t' '{print $4}')

REASON="BLOCKED: $pending_count hook output(s) need acknowledgment.
First: hook=$first_hook reason=$first_reason file=${first_path:-<no-file>}
Action: Read the file_path of each pending entry to acknowledge — each Read clears its entry. Entries with empty file_path (rare) cannot be cleared via Read; use HOOK_ACK_CLEAR=1.
List: cat .claude/.session-state/hook-output-pending.txt
Bypass: HOOK_ACK_CLEAR=1 <cmd> (audit-logged)."

# v4.28-W4 (#680 F5): jq deny-JSON construction failure was previously
# silent — `exit 0` after the if/else would have allowed the command
# through if jq emitted partial output then errored. Now: rc-check the
# jq invocation and fall back to exit-2 + stderr (the legacy failure
# path) so the gate still blocks even on jq malfunction.
if command -v jq >/dev/null 2>&1; then
	if ! jq -nc --arg r "$REASON" \
		'{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; then
		echo "stale-state-gate: jq deny-JSON construction FAILED — falling back to exit-2 block" >&2
		echo "$REASON" >&2
		exit 2
	fi
else
	echo "$REASON" >&2
	exit 2
fi
echo "stale-state-gate: $REASON" >&2
exit 0
