#!/bin/bash
set -u
# event: PostToolUse
# matcher: Bash
# enforcement: inform — deliberate warn-only; the git-commit wrapper fails closed for Copilot-drafted messages, operator-supplied stay warn-only by design (see header)
# v4.24 (#597) — PostToolUse hook: lint just-made commit message against
# .github/commit-template.yml schema. Non-blocking: emits stderr warning on
# drift so the next commit can fix. Does NOT block or rewrite commits.
#
# Registered via ~/.claude/settings.json hooks.PostToolUse matcher=Bash.
# Fires after ANY Bash tool call, no-ops unless the call was `git commit`.
#
# Why post-commit (not pre-commit)?
#   - pre-commit refusing a commit for subject-length or missing-body is too
#     aggressive. Not every user context warrants enforcement. Let the commit
#     land, warn after, let the next commit or amend fix it.
#   - The commit-template-check.sh pre-commit hook DOES block — but only on
#     the TEMPLATE FILE drift (schema changes). This hook is about individual
#     commit-message quality, which is softer.

# v4.28-W4 #851 r1 (#705 Phase 2): payload parsing + commit detection +
# exit_code gate extracted to .claude/_lib/post-commit-detect.sh. Both
# this hook and phase0.5-post-commit-rerun.sh had near-identical
# boilerplate; SSOT-first centralizes the schema. Exports PAYLOAD/CMD/
# EXIT_CODE on success; returns 1 to skip (non-commit, empty CMD, or
# failed commit). Skip → exit 0 (advisory hook, never blocks).
# shellcheck source=../_lib/post-commit-detect.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/post-commit-detect.sh"
post_commit_detect_init || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -z "$REPO_ROOT" ] && exit 0
cd "$REPO_ROOT" || exit 0

# The commit just landed — inspect its message.
MSG=$(git log -1 --format='%B' 2>/dev/null || echo "")
[ -z "$MSG" ] && exit 0

# v4.28-W3-CD #743 r2: delegate validation to factored-out validator.
# Single SSOT for commit-message rules: .claude/scripts/commit/validate-message.sh
# Keeps post-commit warn-only behavior (non-blocking) while sharing logic
# with the pre-commit fail-closed path in git-commit/run.sh.
VALIDATOR="$REPO_ROOT/.claude/scripts/commit/validate-message.sh"
[ -x "$VALIDATOR" ] || exit 0

VALIDATOR_OUT=$(printf '%s' "$MSG" | "$VALIDATOR" 2>&1 >/dev/null) || true
# The .claude/-touched heuristic is post-commit-specific (uses git-show on
# the committed SHA); the validator can't infer it pre-commit, so handle it
# here. The validator already warns on missing Co-Authored-By unconditionally,
# but only mention "touched .claude/ paths" when the heuristic fires.
CLAUDE_FILES=$(git show --name-only --pretty=format: HEAD 2>/dev/null | grep -c '^\.claude/')
EXTRA_WARN=""
if [ "${CLAUDE_FILES:-0}" -gt 0 ] && ! printf '%s' "$MSG" | grep -q 'Co-Authored-By:'; then
	EXTRA_WARN="
  • Commit touched .claude/ paths but lacks Co-Authored-By trailer"
fi

# If validator emitted warnings OR the .claude/-touched heuristic fired,
# print a single advisory stderr block (non-blocking). The validator's own
# "Missing Co-Authored-By trailer" line is a duplicate when EXTRA_WARN fires —
# strip it here to avoid the doubled message.
if [ -n "$VALIDATOR_OUT" ] || [ -n "$EXTRA_WARN" ]; then
	if [ -n "$EXTRA_WARN" ]; then
		VALIDATOR_OUT=$(printf '%s\n' "$VALIDATOR_OUT" | grep -v 'Missing Co-Authored-By trailer' || true)
	fi
	# Strip the validator's leading "commit-message validation drift:" header
	# so the post-commit advisory framing is clean.
	BODY_OUT=$(printf '%s\n' "$VALIDATOR_OUT" | sed -e 's/^commit-message validation drift://')
	{
		echo ""
		echo "⚠ commit-template-lint drift (advisory, commit landed):${BODY_OUT}${EXTRA_WARN}"
		echo "   SSOT: .github/commit-template.yml"
		echo "   Next commit or --amend to fix. This warning is non-blocking."
	} >&2
fi

exit 0
