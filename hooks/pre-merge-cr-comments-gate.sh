#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# v0.8.3 — refuse `gh pr merge` (including --admin + SKILL_WRAPPER=1 paths)
# while the target PR has unresolved CodeRabbit review threads, stranded
# outdated threads, walkthrough Pre-merge failures, or outside-diff-range
# findings.
#
# Why this hook exists (FCP toolkit + plugin #33 lesson):
# The github-pr-merge skill already invokes `_pr-cr-findings.sh` as its
# Step 3 (CodeRabbit cleanliness). But that check lives INSIDE the skill;
# raw `gh pr merge` or `gh pr merge --admin` bypasses it. SKILL_WRAPPER=1
# in the command preamble is the sanctioned bypass for skill-bypass-guard,
# but it doesn't replay the skill's internal checks. Result: an operator
# (or AI assistant — see this hook's filing PR) can admin-merge a PR with
# unaddressed CR inline comments.
#
# This hook closes the gap: PreToolUse Bash matcher intercepts every
# `gh pr merge` invocation, extracts the PR number, runs the same
# `_pr-cr-findings.sh` helper, and refuses on findings > 0.
#
# Resolution paths (mirror existing helper semantics):
#   1. Fix the code → push → CR re-reviews → auto-resolves matching threads
#   2. Reply with dogfood evidence + post `@coderabbitai resolve` → CR
#      bulk-marks all comments resolved when satisfied
#   3. (Last-resort) Fire `resolveReviewThread` GraphQL mutation per
#      stranded thread — same path the github-pr-merge skill documents.
#
# Bypass: PRE_MERGE_CR_GATE_SKIP=1 in command preamble (audit-logged).
# Use ONLY when CR-CLI sandbox limitations produce verified false-positive
# findings that have prove-yourself rejection-with-evidence records.

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"
LIB_SENTINEL="${HOOK_DIR}/../_lib/hook-inline-sentinel.sh"

if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi
if [ -f "$LIB_SENTINEL" ]; then
	# shellcheck source=../_lib/hook-inline-sentinel.sh
	source "$LIB_SENTINEL"
else
	hook_inline_sentinel_check() { return 1; }
fi

# Read tool-call payload. Fail-closed on stdin/jq failures (matches the
# rest of the plugin hook chain — silent coercion to {} hid real bugs in
# the past per pre-push-pipeline-gate.sh's defense docs).
if ! PAYLOAD=$(cat 2>/dev/null); then
	hook_deny "pre-merge-cr-comments-gate" "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null); then
	hook_deny "pre-merge-cr-comments-gate" "hook payload not valid JSON — failing closed"
fi
[ -z "$CMD" ] && exit 0

# Scope: only fire on `gh pr merge` invocations (with or without other
# flags, with or without `--admin`, with or without leading env vars).
# Anchor `gh pr merge` to either command-start OR a shell separator
# (`;`/`&&`/`||`/`|`) so the substring inside a quoted commit-message or
# `--body` doesn't false-fire — same anchor pattern as
# phase1-before-cr.sh + skill-bypass-guard.
case "$CMD" in
*\ gh\ pr\ merge\ * | *\ gh\ pr\ merge | gh\ pr\ merge\ * | gh\ pr\ merge | *\;[[:space:]]*gh\ pr\ merge* | *\&\&[[:space:]]*gh\ pr\ merge* | *\|[[:space:]]*gh\ pr\ merge*) ;;
*)
	exit 0
	;;
esac

# Inline-sentinel bypass — operator-acknowledged escape. Logged so
# repeated use surfaces in the audit feed for review.
if hook_inline_sentinel_check "PRE_MERGE_CR_GATE_SKIP" "$CMD" "pre-merge-cr-comments-gate"; then
	exit 0
fi

# Extract PR number from the command. Patterns supported:
#   gh pr merge <N>
#   gh pr merge --pr <N>
#   gh pr merge (no arg — uses current branch's PR, look up via gh)
PR_NUM=""
# Try `gh pr merge <N>` form first (most common).
if printf '%s' "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+'; then
	PR_NUM=$(printf '%s' "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1)
fi
# Fallback: extract `--pr <N>` if present.
if [ -z "$PR_NUM" ]; then
	PR_NUM=$(printf '%s' "$CMD" | grep -oE '\-\-pr[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1)
fi
# Final fallback: resolve from current branch.
if [ -z "$PR_NUM" ]; then
	PR_NUM=$(gh pr list --head "$(git branch --show-current 2>/dev/null)" --state open --json number --jq '.[0].number' 2>/dev/null || true)
fi
if [ -z "$PR_NUM" ] || ! [ "$PR_NUM" -eq "$PR_NUM" ] 2>/dev/null; then
	hook_deny "pre-merge-cr-comments-gate" "could not extract PR number from command. Pass it explicitly: gh pr merge <N>."
fi

# Locate the helper. Prefer in-repo (so consumers can override) then
# fall back to the plugin-cache copy this hook ships from.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
HELPER=""
for cand in \
	"$REPO_ROOT/.claude/hooks/_pr-cr-findings.sh" \
	"$HOOK_DIR/_pr-cr-findings.sh"; do
	if [ -x "$cand" ]; then
		HELPER="$cand"
		break
	fi
done
if [ -z "$HELPER" ]; then
	hook_deny "pre-merge-cr-comments-gate" "_pr-cr-findings.sh helper not found in $REPO_ROOT/.claude/hooks/ or $HOOK_DIR/"
fi

# Run the helper. Exit 0 = clean. Any other code = findings present (the
# helper writes its own stderr breakdown of per-bucket counts which we
# pass through verbatim so the operator sees exactly which class is
# unresolved).
if ! "$HELPER" "$PR_NUM" >&2; then
	hook_deny "pre-merge-cr-comments-gate" "PR #$PR_NUM has unresolved CodeRabbit findings. Address each via (1) fix in code → push, (2) reply with evidence + '@coderabbitai resolve', or (3) fire 'resolveReviewThread' GraphQL on stranded threads. Then retry. Bypass (audit-logged): PRE_MERGE_CR_GATE_SKIP=1 PRE_MERGE_CR_GATE_SKIP_REASON=\"<text>\" gh pr merge ..."
fi
exit 0
