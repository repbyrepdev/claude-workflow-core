#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Write|Edit|MultiEdit
# v4.28-W3-C (#664): refuse Write/Edit/MultiEdit when the content being
# written contains Edit-tool corruption signatures (literal `>>""`).
#
# WHY first-line guard, not just pre-commit: PR #660 (2026-04-25) hit
# this corruption mid-PR. The corrupted bytes landed in
# `.claude/hooks/phase0.5-copilot-prefilter.sh` via a compound MultiEdit
# on a heavily-quoted heredoc. Subsequent agent invocations sent the
# corrupted file content to the Anthropic API and triggered content
# filter aborts ("Usage Policy violation"), interrupting the session.
#
# Pre-commit guard alone is too late — by then the bytes have been on
# disk for the rest of the session and every API round-trip carrying
# the file content fails. Refusing the Write at PreToolUse keeps the
# corrupted bytes from EVER hitting the filesystem.
#
# Bypass via inline-sentinel: COMMIT_CORRUPT_GUARD_SKIP=1 (shared with
# pre-commit guard) for the meta-PR that adds bats fixtures with the
# literal pattern.

# Bypass for meta-PRs adding bats fixtures with the literal corruption pattern.
# r1 follow-up SFH HIGH: silent bypass = no audit trail. Mirror stale-state-gate
# HOOK_ACK_CLEAR=1 pattern: emit stderr breadcrumb + append JSONL audit record.
if [ "${COMMIT_CORRUPT_GUARD_SKIP:-0}" = "1" ]; then
	repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
	log_file="$repo_root/.claude/logs/edit-corrupt-guard-skip.jsonl"
	mkdir -p "$(dirname "$log_file")"
	audit_ok=0
	if command -v jq >/dev/null 2>&1; then
		if jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg reason "${COMMIT_CORRUPT_GUARD_SKIP_REASON:-no-reason}" \
			'{ts:$ts, kind:"edit-corrupt-guard-skip", reason:$reason}' \
			>>"$log_file"; then
			audit_ok=1
		else
			echo "edit-corruption-guard: bypass audit append failed: $log_file" >&2
		fi
	else
		echo "edit-corruption-guard: jq missing; bypass audit not recorded" >&2
	fi
	if [ "$audit_ok" = "1" ]; then
		echo "edit-corruption-guard: COMMIT_CORRUPT_GUARD_SKIP=1 — bypassing (audit-logged)" >&2
	else
		echo "edit-corruption-guard: COMMIT_CORRUPT_GUARD_SKIP=1 — bypassing (audit FAILED, see stderr above)" >&2
	fi
	exit 0
fi

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

if ! PAYLOAD=$(cat 2>/dev/null); then
	hook_deny "edit-corruption-guard" "stdin read failed — failing closed"
fi
if ! TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null); then
	hook_deny "edit-corruption-guard" "payload not JSON — failing closed"
fi

# Resolve content depending on tool.
#   Write       → tool_input.content
#   Edit        → tool_input.new_string
#   MultiEdit   → tool_input.edits[].new_string (concat all new_strings)
#
# r1 silent-failure-hunter #4: capture jq failure separately from empty
# content. Prior `2>/dev/null || echo ""` collapsed both into "" then
# `[ -z "$CONTENT" ] && exit 0` — corrupted JSON payload silently
# fail-OPEN (allows the Write). Now: jq failure → hook_deny (fail
# closed); legitimately-empty content → exit 0.
_jq_err=$(mktemp)
case "$TOOL" in
Write)
	CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.content // ""' 2>"$_jq_err") || {
		rm -f "$_jq_err"
		hook_deny "edit-corruption-guard" "jq failed to parse Write payload — failing closed"
	}
	;;
Edit)
	CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.new_string // ""' 2>"$_jq_err") || {
		rm -f "$_jq_err"
		hook_deny "edit-corruption-guard" "jq failed to parse Edit payload — failing closed"
	}
	;;
MultiEdit)
	CONTENT=$(printf '%s' "$PAYLOAD" | jq -r '[.tool_input.edits[]?.new_string] | join("\n")' 2>"$_jq_err") || {
		rm -f "$_jq_err"
		hook_deny "edit-corruption-guard" "jq failed to parse MultiEdit payload — failing closed"
	}
	;;
*)
	rm -f "$_jq_err"
	exit 0
	;;
esac
rm -f "$_jq_err"

# Empty content is legitimate (e.g. truncate-write); short-circuit.
[ -z "$CONTENT" ] && exit 0

# Skip the bats fixture file itself — it intentionally contains the pattern.
# Mirror fail-closed jq invocation pattern from earlier in this script.
if ! FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null); then
	hook_deny "edit-corruption-guard" "jq parse failed on file_path — failing closed"
fi
# r3 CR fix #3: exact-path whitelist (was suffix-glob which let
# /tmp/edit-corruption-guard.bats slip through). Match both repo-relative
# and absolute paths to cover the file_path forms Claude tools emit.
case "$FILE" in
.claude/tests/pre-commit-hooks/edit-corruption-guard.bats | \
	*/.claude/tests/pre-commit-hooks/edit-corruption-guard.bats | \
	.claude/tests/hooks/edit-corruption-pretooluse-guard.bats | \
	*/.claude/tests/hooks/edit-corruption-pretooluse-guard.bats | \
	.claude/hooks/edit-corruption-pretooluse-guard.sh | \
	*/.claude/hooks/edit-corruption-pretooluse-guard.sh | \
	.claude/pre-commit-hooks/edit-corruption-guard.sh | \
	*/.claude/pre-commit-hooks/edit-corruption-guard.sh)
	exit 0
	;;
esac

# Pattern detection — `>>""` literal.
if printf '%s' "$CONTENT" | grep -q '>>""'; then
	hook_deny "edit-corruption-guard" "content contains '>>\"\"' literal (Edit-tool corruption signature). Refused before bytes reach disk. Pattern triggers Anthropic API content filter on subsequent calls. If intentional (test fixture), set COMMIT_CORRUPT_GUARD_SKIP=1."
fi

exit 0
