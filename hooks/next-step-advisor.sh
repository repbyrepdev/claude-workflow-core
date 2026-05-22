#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# PostToolUse hook: tell Claude what the default next action is after a transition.
#
# This is guidance for CLAUDE to auto-continue — NOT a menu shown to the user.
# Default = the [1] option. Claude proceeds with it unless blocked by an
# approval gate (pre-PR, pre-merge, post-deploy verification, milestone close)
# or the user interrupts with a phrase.
#
# Silent on failures, unrelated commands, destructive git operations.
# Registered in .claude/settings.json PostToolUse on Bash matcher.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat) || {
	echo "next-step-advisor: stdin read failed — skipping" >&2
	exit 0
}
[ -z "$INPUT" ] && INPUT="{}"
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
EXIT_CODE=$(printf '%s' "$INPUT" | jq -r '.tool_response.exitCode // 1' 2>/dev/null || echo "1")

[ "$EXIT_CODE" = "0" ] || exit 0
[ -z "$COMMAND" ] && exit 0

emit() {
	printf '%s' "$1" | jq -Rs '{additionalContext: .}'
}

# Order: more specific patterns first.
case "$COMMAND" in

*"gh pr merge"*)
	# POST-MERGE — autonomous cleanup, no approval needed (merge already happened).
	# Note: teleport-push hint removed in v3.6 (#155) — detected PROJECT .claude/
	# changes (versioned in repo), but teleport only syncs USER-level ~/.claude/
	# (plugins, settings, marketplaces). False-positive. session-start's
	# env-sanity block surfaces genuine teleport divergence.
	emit "Auto-continuing after merge: run post-merge cleanup (git checkout main && git pull && git remote prune origin && gh poi), verify auto-close-parent fired, check milestone. If milestone now complete, GATE: ask user before tagging + releasing. User interrupt phrases: 'wait', 'stop', 'let me check'."
	;;

*"gh issue create"*)
	# POST-ISSUE-CREATE — if 3+ sibling sub-issues of same parent exist in Backlog, suggest batching
	# (The issue was just created; detecting "3+ siblings" is expensive, so emit a lighter suggestion.)
	emit "Auto-continuing after issue create: if this is a sub-issue of an epic that has 2+ other Backlog sub-issues with tightly-related scope, consider batching all of them into ONE PR (see github-pr-creation SKILL.md 'Batching related sub-issues + local-iterate' — saves CodeRabbit 10/hr Pro Plus budget; refill 6min/token)."
	;;

*"gh pr create"*)
	# POST-PR-CREATE — autonomous: watch checks, handle CR comments when they arrive
	emit "Auto-continuing after PR create: run 'gh pr checks \$PR --watch --fail-fast' to block until checks settle. If CodeRabbit posts comments, auto-fetch via coderabbit:autofix, apply in one batch, push once. GATE: present to user for merge approval ONLY after all checks green + CR addressed. User interrupt phrases: 'wait', 'stop', 'let me check first'."
	;;

*"git push"*)
	BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
	PR_NUM=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
	if [ -z "$PR_NUM" ] && [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ]; then
		emit "Auto-continuing after push (no PR yet): invoke github-pr-creation skill. GATE: show title + body + labels + milestone for user approval BEFORE gh pr create runs. User interrupt phrases: 'wait', 'different title', 'let me check'."
	elif [ -n "$PR_NUM" ]; then
		emit "Auto-continuing after push to PR #$PR_NUM: run 'gh pr checks $PR_NUM --watch --fail-fast' to block until checks settle. Handle any new CR comments via coderabbit:autofix, push once. GATE: wait for user approval before merge. User interrupt phrases: 'wait', 'stop'."
	fi
	;;

*"git commit"*)
	# Skip amend/reset — those are recovery operations
	case "$COMMAND" in
	*"--amend"* | *"reset"*) exit 0 ;;
	esac
	emit "Auto-continuing after commit: if branch has more work planned, keep editing. If this was the last commit for the feature, run pr-review-toolkit local review, then push + invoke github-pr-creation. GATE: user approval shown at PR create step. User interrupt phrases: 'wait', 'more changes', 'stop'."
	;;

*"docker compose"*"up"*)
	# POST-DEPLOY — autonomous health check, THEN user gate
	emit "Auto-continuing after deploy: sleep 15, run health-check skill (5-step diff vs baseline), scan all container logs for errors, verify new metrics end-to-end. GATE: show diff to user for verification BEFORE committing. User interrupt phrases: 'wait', 'rollback', 'something is off'."
	;;

*"gh issue edit"*"--add-assignee"*)
	# ISSUE ASSIGNED — autonomous: create branch, baseline
	emit "Auto-continuing after issue assign: create branch (git checkout -b <area>/<descriptive-name>), take health-check baseline, start the work. No user gate until PR create. User interrupt phrases: 'different branch name', 'wait'."
	;;

*"git tag"*)
	# POST-TAG — autonomous: push tag (release.yml handles the rest)
	emit "Auto-continuing after tag: run 'git push --tags' — this triggers release.yml which auto-generates the changelog. GATE: none needed (user already approved by requesting the tag). User interrupt: 'wait' if they want to review first."
	;;

*"mkdir"*"stacks/"*)
	# NEW STACK DIRECTORY — invoke add-container skill for guided workflow
	emit "New stack directory detected — invoke the add-container skill for the full guided workflow (context7 lookup → compose template with required invariants → SOPS-first encryption with auto round-trip → maintain.sh + restore.sh sync → trivy → deploy → health → Prometheus target → homepage labels → issue + PR). User interrupt phrases: 'wait', 'different approach', 'I'll do it manually'."
	;;

*"sops encrypt"* | *"age -r "*"-o "*".enc"*)
	# POST-ENCRYPT — remind about round-trip test (pre-commit hook enforces, but nudge earlier)
	emit "Auto-continuing after encrypt: verify round-trip immediately — decrypt the .enc back to a temp file and diff against the plaintext. If it's a config .enc file, also confirm the path is in BOTH scripts/maintain.sh decrypt_all_configs() AND scripts/restore.sh Step 2b. Pre-commit hooks (check-enc-sync, roundtrip-encrypt) will block the commit if you skip these — verify up-front to avoid the block."
	;;

*"gh pr close"*)
	# POST-PR-CLOSE — closed without merge; auto-delete-branch-on-close workflow
	# handles the remote branch, but nudge to prune locally + audit orphans.
	# v3.22 #212: previously missing — operator had to remember to prune manually.
	emit "Auto-continuing after PR close: run 'git fetch --prune' to drop the remote-tracking ref (the delete-branch-on-close workflow removed the remote head). If the issue linked in the closed PR body is still open, confirm with the user whether to re-open the issue or mark wontfix. User interrupt: 'wait, was that intentional?'."
	;;

*"gh issue close"*)
	# POST-ISSUE-CLOSE — auto-close-parent workflow handles epic rollup; nudge to
	# verify parent-closure propagated + milestone progress updated.
	# v3.22 #212: previously missing.
	emit "Auto-continuing after issue close: if this was a sub-issue of an open epic, the auto-close-parent workflow fires on close — verify the parent issue's 'Sub-issues progress' bar updated + milestone percentage moved. If all siblings are now closed, the parent should auto-close within ~30s; if not, check auto-close-parent.yml logs. User interrupt: 'wait, check first'."
	;;

esac

exit 0
