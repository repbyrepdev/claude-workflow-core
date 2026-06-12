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

# Scope: fire ONLY when `gh pr merge` is invoked at a COMMAND position. Reuse the
# canonical command-anchor SSOT (_lib/cmd-anchor.sh, #677) + the CR-hardened
# ENV_PREFIX byte-copied from skill-bypass-guard.sh — the SAME detection that
# guard uses for `gh pr merge`, so the two gates cannot drift. #2393: the prior
# glob `*\ gh\ pr\ merge\ *` matched the phrase ANYWHERE, including inside a
# quoted `-m "... gh pr merge ..."` commit message, so a benign commit that
# merely mentioned the phrase false-fired the gate (it even false-fired the
# issue-creation command that filed #2393). The anchor requires command-start or
# a shell separator, so a quoted mid-string `gh pr merge` no longer matches;
# ENV_PREFIX peels a leading `VAR=val` preamble incl. quoted values (`X="a b"`);
# a `bash -c '...'` wrapper's inner command is also checked.
#
# Out of scope HERE (matching skill-bypass-guard.sh): `sudo`/`command`/`env`
# wrappers and `{ }`/`( )` grouping. Extending coverage belongs in the shared
# _lib/cmd-anchor.sh so every gate benefits in ONE place — adding it bespoke here
# is the exact regex drift #677 created the lib to prevent.
ANCHOR_LIB="${HOOK_DIR}/../_lib/cmd-anchor.sh"
if [ -f "$ANCHOR_LIB" ]; then
	# shellcheck source=../_lib/cmd-anchor.sh
	source "$ANCHOR_LIB"
else
	# Fallback when the SSOT lib is unavailable: keep the same anchor inline.
	CMD_SEGMENT_ANCHOR='(^|[;&|][[:space:]]*)'
	CMD_SEGMENT_END='([[:space:]]|$)'
fi
# CR-hardened env-assignment prefix — byte-identical to skill-bypass-guard.sh so
# the two gates stay in lockstep (unquoted values must NOT start with a quote,
# forcing the quoted alternations to own quoted values; CR #634 finding 136).
ENV_PREFIX='([A-Za-z_][A-Za-z0-9_]*=('"'"'[^'"'"']*'"'"'|"[^"]*"|[^"'"'"'[:space:]][^[:space:]]*)[[:space:]]+)*'
GHM_PATTERN="${CMD_SEGMENT_ANCHOR}${ENV_PREFIX}gh[[:space:]]+pr[[:space:]]+merge${CMD_SEGMENT_END}"
# Inner command of a `bash -c '...'` style wrapper (CR #634 finding 177).
WRAPPED_CMD=$(printf '%s' "$CMD" | sed -nE "s|.*(bash\|sh\|zsh\|/bin/bash\|/bin/sh\|/bin/zsh)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*['\"]([^'\"]+)['\"].*|\3|p" | head -1)
_ghm_fires=0
if printf '%s' "$CMD" | grep -qE "$GHM_PATTERN"; then
	_ghm_fires=1
elif [ -n "$WRAPPED_CMD" ] && printf '%s' "$WRAPPED_CMD" | grep -qE "$GHM_PATTERN"; then
	_ghm_fires=1
fi
if [ "$_ghm_fires" != "1" ]; then
	exit 0
fi

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
# `|| true` on these extraction substitutions is load-bearing under
# `set -euo pipefail`: a grep with no match exits non-zero, pipefail
# propagates that, and a bare `PR_NUM=$(failing-pipeline)` would then ABORT
# the whole hook (exit 1) — which Claude Code treats as a NON-blocking error,
# letting the `gh pr merge` proceed UNGATED. The `|| true` keeps a no-match
# as empty-PR_NUM so control reaches the branch fallback + the friendly
# `could not extract PR number` deny below (which DOES block).
if printf '%s' "$CMD" | grep -qE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+'; then
	PR_NUM=$(printf '%s' "$CMD" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+$' | head -1 || true)
fi
# Fallback: extract `--pr <N>` if present.
if [ -z "$PR_NUM" ]; then
	PR_NUM=$(printf '%s' "$CMD" | grep -oE '\-\-pr[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
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
