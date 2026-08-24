#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# enforcement: inform — state housekeeping on PR close
# PostToolUse hook — after any successful `gh pr merge` or `gh pr close`, run
# `git fetch --prune origin` to sync local remote-tracking refs with reality.
# Without this, `git branch -r` keeps showing branches that GitHub already
# deleted (via delete_branch_on_merge or delete-branch-on-close.yml), which
# causes false "stale branch" diagnostics.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
EXIT_CODE=$(printf '%s' "$INPUT" | jq -r '.tool_response.exitCode // 1' 2>/dev/null || echo "1")

# Only run on successful `gh pr close` or `gh pr merge`
if [[ $EXIT_CODE != "0" ]]; then exit 0; fi
if [[ $COMMAND != *"gh pr close"* ]] && [[ $COMMAND != *"gh pr merge"* ]]; then exit 0; fi

# Prune silently; surface only if something was actually deleted
PRUNED=$(git -C "${CLAUDE_PROJECT_DIR:-.}" fetch --prune origin 2>&1 | grep -cE "^\s*- \[deleted\]" || true)
if [ "$PRUNED" -gt 0 ]; then
	echo "Pruned $PRUNED stale remote-tracking ref(s) after PR action — local 'git branch -r' now matches remote."
fi
