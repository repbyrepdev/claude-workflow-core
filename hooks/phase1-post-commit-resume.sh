#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# enforcement: inform — orchestration resume; the stage gates enforce
# v4.15.H #496 — PostToolUse hook: post-commit of workflow-infra files
# mid-dogfood → resume-loop reminder.

# v4.15.R: unconditional debug log of hook firing. Absolute path bypasses
# any CWD confusion. Note: strict mode is on line 2 now (frontmatter
# tagging in v4.28-W1 didn't change that); this debug is unconditional
# rather than "before set -euo" — kept for fail-loud telemetry.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) phase1-post-commit-resume FIRED pid=$$" >>/tmp/claude-phase1-hooks.log 2>/dev/null || true

_HOOK_START=$(date +%s)
# Source the shared lib relative to this script's path. Fail loudly if it's
# missing — silent fallback would leave hook_log_run undefined, turning the
# EXIT trap into a no-op and breaking telemetry without any visible signal.
LIB_DIR=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=/dev/null
if ! source "$LIB_DIR/_lib.sh"; then
	echo "phase1-post-commit-resume: failed to load $LIB_DIR/_lib.sh" >&2
	# Fail closed (exit 1) per the comment block above — exit 0 would
	# silently report success while telemetry is broken.
	exit 1
fi
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

# WHY: v4.15.F/G closed agent-return→log and log→next-round stalls.
# Third stall point: after committing a workflow-infra fix (Bash tool),
# no hook fires because there's no Agent/Skill return event. Observed
# 2026-04-20 — Claude commits the fix and stops, waiting for user.
#
# HOW: fires on PostToolUse/Bash. If the command was a `git commit`
# AND the commit touched .claude/hooks/*, .claude/skills/*, or
# CLAUDE.md AND a review-log for the PREVIOUS HEAD exists (we were
# mid-dogfood), emit a stderr directive: "resume on new HEAD,
# launch Round 1, do not wait for user."

# v4.15.X: fail-closed on stdin/jq parse. Prior `|| echo '{}'` / `|| echo ""`
# silently masked broken hook plumbing.
PAYLOAD=$(cat) || {
	echo "phase1-post-commit-resume: stdin read failed — skipping" >&2
	exit 0
}
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""') || {
	echo "phase1-post-commit-resume: payload unparseable — skipping" >&2
	exit 0
}
[ "$TOOL" != "Bash" ] && exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""')
# v4.28-W4 #748: match direct `git commit` OR `.claude/skills/git-commit/run.sh`
# wrapper invocations. Prior regex missed wrapper commits, leaving
# phase1-post-commit-resume idle on the new HEAD.
# shellcheck source=../_lib/cmd-anchor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/cmd-anchor.sh"
match_git_commit_or_wrapper "$CMD" || exit 0
# v4.15.U: verify the commit actually succeeded. Failed commits (pre-commit
# reject, nothing to commit) shouldn't fire the resume-loop directive.
# v4.15.GG: default to 'unknown' (not 0) when neither exit_code nor exitCode
# is present, so a payload schema change doesn't silently treat unknown as
# success. Unknown AND non-zero both skip.
EXIT_CODE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_response.exit_code // .tool_response.exitCode // "unknown"' 2>/dev/null || echo "unknown")
[ "$EXIT_CODE" != "0" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -z "$REPO_ROOT" ] && exit 0
cd "$REPO_ROOT" || exit 0

# v4.29 #792 — branch-graduation short-circuit. Once a branch has
# graduated past Phase 0.5/1 (one clean Phase 1 round), further commits
# don't need the resume-loop directive — Phase 2/3 cover the changes.
# CR Phase 2 MAJOR: fail-closed on git rev-parse error (was || echo "" —
# silent swallow could let a broken repo state look like "ungraduated").
GRAD_LIB="$(dirname "$0")/../_lib/phase-graduation.sh"
if [ -r "$GRAD_LIB" ]; then
	if ! GRAD_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>&1); then
		echo "phase1-post-commit-resume: graduation branch resolution failed: $GRAD_BRANCH" >&2
		exit 1
	fi
	if [ -n "$GRAD_BRANCH" ]; then
		# shellcheck source=/dev/null
		. "$GRAD_LIB"
		if graduation_check "$GRAD_BRANCH"; then
			exit 0
		fi
	fi
fi

# Verify the last commit actually touched workflow-infra paths. We can't
# know from the payload alone — inspect the just-made HEAD.
CHANGED=$(git show --name-only --pretty=format: HEAD 2>/dev/null | grep -E '^(\.claude/hooks/|\.claude/skills/|CLAUDE\.md$)' || true)
[ -z "$CHANGED" ] && exit 0

# Skip on main (workflow-infra commits to main aren't dogfood — they're
# post-merge). Otherwise fire on every workflow-infra commit.
# v4.15.L: removed the "review-log exists" MID_DOGFOOD gate — it was
# circular. H could never fire on the FIRST commit of a workflow-infra
# PR because no review-log existed yet. Review-logs only get created
# AFTER Claude runs review-log.sh. Review-log.sh only runs after Claude
# follows the G directive. G only fires after Claude launches agents.
# Claude launches agents only when H directs. Deadlock. Broad-firing on
# any non-main workflow-infra commit is the right trigger.
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$BRANCH" in
main | master | HEAD) exit 0 ;;
esac

NEW_SHA=$(git rev-parse HEAD 2>/dev/null)
# v4.15.M: JSON stdout hookSpecificOutput.additionalContext — working
# injection mechanism per Claude Code hook spec (exit 2 + stderr did
# not inject in live test 2026-04-20).
CHANGED_CSV=$(echo "$CHANGED" | tr '\n' ',' | sed 's/,$//')
jq -n --arg ctx "=== Workflow-infra commit during active dogfood (v4.15.H) ===
Committed: ${NEW_SHA:0:12}
Changed paths: $CHANGED_CSV

IMMEDIATE NEXT ACTION (do NOT stall / summarize / wait for user):
Resume Phase 1 Round 1 on the new HEAD. The prior review-log is stranded at the old SHA — the new diff needs fresh review. Launch ALL expected agents in ONE parallel Agent tool-call block. Helper: .claude/hooks/phase1-launcher.sh 1 prints the exact checklist. After each agent returns, the v4.15.G nudge fires reminding you to log via review-log.sh. After the last agent logs, v4.15.F's round-complete directive fires. Follow the chain; never hand control back to the user between any two links until ≥MIN_ROUNDS × MIN_CLEAN_STREAK convergence OR a fix requires user input." \
	'{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0
