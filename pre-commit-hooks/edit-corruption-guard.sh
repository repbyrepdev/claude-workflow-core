#!/bin/bash
set -euo pipefail
# v4.28-W3-C (#664): refuse commits when staged .sh / .bats / .yml /
# .yaml / .json / .md files contain Edit-tool corruption signatures.
#
# Why this exists: the Edit/MultiEdit tool escape sequences corrupt
# heavily-quoted shell files, leaving content like `>>""` that lexes as
# valid bash but triggers downstream API content filters (PR #660
# incident, 2026-04-25). The corrupted bytes survived shfmt + shellcheck
# because they ARE syntactically valid — only this targeted pattern
# check catches them.
#
# Patterns refused (exact-byte regex, applied to staged blob content):
#
#   * Literal `>>""` outside a string — heredoc-redirect collision from
#     a corrupted Edit sequence. Real bash never emits this.
#
# (A second pattern for stray `\\\n` was scoped but not implemented —
# see Wave 2 follow-up issue tracking the second corruption class.)
#
# Bypass: COMMIT_CORRUPT_GUARD_SKIP=1 git commit ... (audit-logged).
# Use only when committing intentionally test-content that shouldn't
# trigger (e.g. a bats fixture that exercises this guard).

# Pre-commit hooks operate on the working tree they're invoked from
# (git's pre-commit context), not on the install path of the hook
# script. `git rev-parse --show-toplevel` is the correct source — a
# BASH_SOURCE-derived REPO_ROOT would point at the install location
# and break test fixtures that cd into a tmpdir before invoking. Note:
# AGENTS.md's BASH_SOURCE rule is about CLI scripts that need to find
# their own install root, not pre-commit hooks.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "edit-corruption-guard: not in a git repo — refusing to scan" >&2
	exit 2
}
cd "$REPO_ROOT" || exit 2

if [ "${COMMIT_CORRUPT_GUARD_SKIP:-0}" = "1" ]; then
	SKIP_LOG="$REPO_ROOT/.claude/logs/commit-guard-skip.jsonl"
	mkdir -p "$(dirname "$SKIP_LOG")"
	if ! jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg kind "edit-corruption-guard" \
		--arg reason "${COMMIT_CORRUPT_GUARD_SKIP_REASON:-}" \
		'{ts: $ts, kind: $kind, reason: $reason}' \
		>>"$SKIP_LOG"; then
		echo "edit-corruption-guard: failed to append bypass audit log: $SKIP_LOG" >&2
	fi
	echo "edit-corruption-guard: COMMIT_CORRUPT_GUARD_SKIP=1 — bypassing" >&2
	exit 0
fi

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
[ -z "$STAGED" ] && exit 0

FAIL=0

while IFS= read -r f; do
	[ -z "$f" ] && continue
	# Scope: only files where this corruption pattern is plausible.
	case "$f" in
	*.sh | *.bats | *.yml | *.yaml | *.json | *.md) ;;
	*) continue ;;
	esac

	# Read STAGED content (not working tree) so a fix-on-disk doesn't
	# mask a still-corrupt staged blob.
	# r2 sfh #13: capture git show stderr — a corrupt index / missing
	# object / read-perm error must surface, not silently skip a
	# security-relevant scan.
	gs_err=$(mktemp)
	gs_rc=0
	content=$(git show ":$f" 2>"$gs_err") || gs_rc=$?
	if [ "$gs_rc" -ne 0 ]; then
		echo "edit-corruption-guard: ERROR: git show \":$f\" failed (rc=$gs_rc):" >&2
		cat "$gs_err" >&2
		rm -f "$gs_err"
		echo "edit-corruption-guard: aborting commit (fail-closed: staged content unreadable)." >&2
		exit 1
	fi
	rm -f "$gs_err"

	# Pattern 1: `>>""` literal — heredoc-redirect collision signature.
	if printf '%s' "$content" | grep -q '>>""'; then
		echo "edit-corruption-guard: $f contains '>>\"\"' literal (Edit-tool corruption signature)" >&2
		FAIL=$((FAIL + 1))
	fi
done <<<"$STAGED"

if [ "$FAIL" -gt 0 ]; then
	echo "" >&2
	echo "edit-corruption-guard: $FAIL file(s) corrupted." >&2
	echo "  Restore from git: git checkout -- <file>" >&2
	echo "  Re-apply changes via separate Edit calls (avoid compound MultiEdit on heavily-quoted files)" >&2
	echo "  Emergency override: COMMIT_CORRUPT_GUARD_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
