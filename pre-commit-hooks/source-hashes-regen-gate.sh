#!/bin/bash
set -euo pipefail
# (#140) Pre-commit gate: SSOT-tracked file changes require regen of
# .claude/.source-hashes.json.
#
# The baseline at .claude/.source-hashes.json is the single source of
# truth for "what content does the producer ship". Without this gate,
# operator edits to hooks/ or _lib/ can land WITHOUT a hash refresh —
# consumer-side hash-drift.sh --verify would then false-flag the
# operator's intentional change as drift.
#
# Algorithm:
#   1. List staged files matching scripts/hash-drift.sh's tracked dirs:
#        hooks/*.sh
#        _lib/*.sh
#      (More dirs land in Sub 6 — workflows-source/, ISSUE_TEMPLATE/,
#      labels.yml. This gate will need updating per Sub 6.)
#   2. If any tracked file is staged AND .claude/.source-hashes.json is
#      NOT also staged, refuse the commit with a remediation pointer.
#   3. As belt-and-suspenders: run `scripts/hash-drift.sh --generate`
#      to a tmp file, diff against the staged manifest. If they differ,
#      the operator staged a stale .source-hashes.json — also refuse.
#
# Bypass: SOURCE_HASHES_REGEN_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (no tracked changes, OR tracked + hashes staged + current)
#   1 — tracked staged but hashes NOT staged (or staged but stale)
#   2 — precondition error (jq missing, hash-drift.sh missing, etc.)

if [ "${SOURCE_HASHES_REGEN_SKIP:-0}" = "1" ]; then
	echo "source-hashes-regen-gate: SOURCE_HASHES_REGEN_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "source-hashes-regen-gate: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

HASH_DRIFT="$REPO_ROOT/scripts/hash-drift.sh"
if [ ! -x "$HASH_DRIFT" ]; then
	echo "source-hashes-regen-gate: scripts/hash-drift.sh missing or non-exec" >&2
	exit 2
fi

MANIFEST=".claude/.source-hashes.json"

# 1. Any tracked file staged? --diff-filter=ACMRD includes deletions
# (code-reviewer #140 r1: `git rm hooks/foo.sh` left manifest stale).
TRACKED_STAGED=$(git diff --cached --name-only --diff-filter=ACMRD 2>/dev/null |
	grep -E '^(hooks/[A-Za-z0-9_.-]+\.sh|_lib/[A-Za-z0-9_.-]+\.sh)$' || true)

if [ -z "$TRACKED_STAGED" ]; then
	# No tracked changes — nothing to verify
	exit 0
fi

# 2. Is the manifest also staged? grep -Fx for line-exact match (code-reviewer #140 r1:
# loose -F substring would false-positive on `.claude/.source-hashes.json.bak`).
MANIFEST_STAGED=$(git diff --cached --name-only --diff-filter=ACMRD 2>/dev/null |
	grep -Fx "$MANIFEST" || true)

if [ -z "$MANIFEST_STAGED" ]; then
	echo "source-hashes-regen-gate: SSOT-tracked file(s) staged but $MANIFEST is NOT:" >&2
	# shellcheck disable=SC2001  # sed substitution is the clearest expression here
	echo "$TRACKED_STAGED" | sed 's/^/  - /' >&2
	echo "" >&2
	echo "  Fix: scripts/hash-drift.sh --generate && git add $MANIFEST" >&2
	echo "  Bypass (audit-log): SOURCE_HASHES_REGEN_SKIP=1 git commit ..." >&2
	exit 1
fi

# 3. Is the staged manifest STALE? Run regen to a tmp file + compare.
# Note: --generate writes to the working-tree path, so we capture +
# restore the on-disk state to avoid mutating during a pre-commit check.
SNAPSHOT=$(mktemp -t source-hashes-snapshot.XXXXXX)
trap 'rm -f "$SNAPSHOT"' EXIT
if [ -f "$MANIFEST" ]; then
	cp "$MANIFEST" "$SNAPSHOT"
fi

# Regenerate fresh
if ! "$HASH_DRIFT" --generate >/dev/null 2>&1; then
	# Restore + bail
	if [ -f "$SNAPSHOT" ]; then mv "$SNAPSHOT" "$MANIFEST"; fi
	echo "source-hashes-regen-gate: hash-drift.sh --generate failed" >&2
	exit 2
fi

# Compare freshly-generated to staged version
STAGED_CONTENT=$(git show ":${MANIFEST}" 2>/dev/null || echo "")
FRESH_CONTENT=$(cat "$MANIFEST" 2>/dev/null || echo "")

# Restore on-disk state (revert our regen)
if [ -f "$SNAPSHOT" ] && [ -s "$SNAPSHOT" ]; then
	mv "$SNAPSHOT" "$MANIFEST"
fi
trap - EXIT
rm -f "$SNAPSHOT"

if [ "$STAGED_CONTENT" != "$FRESH_CONTENT" ]; then
	echo "source-hashes-regen-gate: $MANIFEST is staged but STALE — diverges from current source content" >&2
	echo "" >&2
	echo "  Fix: scripts/hash-drift.sh --generate && git add $MANIFEST" >&2
	echo "  Bypass (audit-log): SOURCE_HASHES_REGEN_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
