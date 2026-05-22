---
name: session-start
description: Run at the start of every session to check memory, board state, open PRs, issues, and recent workflow runs. Auto-invoked when starting work in this repo.
allowed-tools: Bash(gh *), Bash(git *), Bash(cat *), Bash(python3 *), Read
---

# Session Start Check

Run ALL checks and report results. Flag anything needing attention.

## 1. Memory Check
Read the memory index for context from previous sessions:
```bash
MEMORY_INDEX="$HOME/.claude/projects/$(pwd | sed 's#/#-#g')/memory/MEMORY.md"
if [ -f "$MEMORY_INDEX" ]; then
  cat "$MEMORY_INDEX"
else
  echo "No MEMORY.md found for this project"
fi
```
Note any active projects, deferred items, recent feedback.

## 2. Board State
**CRITICAL:** use the paginated wrapper. Bare `gh project item-list 2 --owner
@me --limit 500` truncates at 500 — Homelab board hit that cap on 2026-04-27
and silently hid 9 newly-filed sub-issues. The wrapper paginates via GraphQL
+ filters Done client-side to keep result tight (real bug — see #653).
```bash
.claude/scripts/board/list-non-done.sh
```
The script emits one line per non-Done item: `[Status] [Priority] #N title`.
Returns ALL items regardless of board size (paginates `pageInfo.hasNextPage`).

## 3. Open PRs (including Renovate)
```bash
gh pr list --state open
```

## 4. Open Issues
```bash
gh issue list --state open
```

## 4b. Renovate Dependency Dashboard
Check for Renovate updates awaiting approval (major version bumps, blocked PRs):
```bash
# Find the Renovate-managed dashboard issue
DASH=$(gh issue list --label auto:renovate --state open --json number,title --jq '.[] | select(.title=="Dependency Dashboard") | .number' | head -1)
if [ -n "$DASH" ]; then
  echo "Dependency Dashboard: #$DASH"
  # Count pending sections (Rate Limited, PR Closed, Awaiting Schedule, Pending Approval)
  gh issue view "$DASH" --json body -q '.body' | grep -cE "^## (Rate Limited|PR Closed|Awaiting Schedule|Pending Approval|Blocked)" || echo "  (clean — nothing awaiting action)"
fi
```
Flag if any "Pending Approval" section has checkboxes — those are major updates Renovate won't auto-merge.

## 5. Recent Workflow Runs
```bash
gh run list --limit 5
```
Flag any failures — especially Project Automation, Gitleaks, Trivy, CodeRabbit.

## 6. Git State
```bash
# ALWAYS prune first — local remote-tracking refs lie without this, they show branches
# that GitHub already deleted via delete_branch_on_merge. Ignoring this gap burned a
# whole diagnostic detour once (chased "stale branches" that were just local cache).
git fetch --prune origin 2>&1 | tail -3
git branch -a
git status --short
git log --oneline -1
```
Flag dangling branches, uncommitted changes, or divergence from main.

### 6b. Orphan branches (closed-not-merged PRs)
`delete_branch_on_merge: true` only fires on MERGE. PRs CLOSED without merging
(e.g. abandoned test PRs) leave their branch as a true orphan on remote.
```bash
# List branches whose PR was closed-not-merged (genuine orphans)
gh pr list --state closed --limit 20 --json number,state,headRefName,mergedAt,headRepositoryOwner \
  --jq '.[] | select(.mergedAt == null) | .headRefName' | while read b; do
    # Check if branch still exists on remote
    gh api repos/{owner}/{repo}/branches/"$b" --silent 2>/dev/null && echo "  ORPHAN: $b (from closed-not-merged PR)"
done
```
If any orphans found: surface to user, ask to delete (`git push origin --delete <branch>`).

## 7. Environment sanity (silent unless issue)

```bash
# context7 plugin must be enabled (workflow rule: always look up docs before writing configs)
jq -r '.enabledPlugins["context7@claude-plugins-official"]' ~/.claude/settings.json 2>/dev/null | grep -q true || \
  echo "⚠ context7 plugin is DISABLED. Enable: /plugin enable context7@claude-plugins-official && /reload-plugins"

# Pre-commit git hook must be installed (otherwise commits skip all 7 hooks)
[ -x .git/hooks/pre-commit ] || echo "⚠ pre-commit git hook not installed. Fix: pre-commit install"

# Repo-level auto-merge must be enabled (Renovate patch/minor auto-merge depends on it)
# Distinguish API failure from config drift — gh exit code tells us which
if AM=$(gh api repos/{owner}/{repo} --jq '.allow_auto_merge' 2>/dev/null); then
  [ "$AM" = "true" ] || echo "⚠ allow_auto_merge=false on repo. Renovate patch/minor won't auto-merge. Fix: gh api -X PATCH repos/{owner}/{repo} -f allow_auto_merge=true"
else
  echo "ℹ unable to verify repo allow_auto_merge (auth/network/API). Skipping drift check."
fi

# Branch protection on main must require 'validate' — handle both GitHub API representations:
# .required_status_checks.contexts (legacy) AND .required_status_checks.checks[].context (newer)
if BP=$(gh api repos/{owner}/{repo}/branches/main/protection \
    --jq '((.required_status_checks.contexts // []) + ((.required_status_checks.checks // []) | map(.context))) | any(. == "validate")' 2>/dev/null); then
  [ "$BP" = "true" ] || echo "⚠ main branch protection missing required 'validate' check. Fix via repo Settings → Branches → main → Require status checks → validate"
else
  echo "ℹ unable to verify main branch protection (auth/network/API). Skipping drift check."
fi

# Teleport hub reachable (warn only — user decides when to sync)
gh api repos/repbyrepdev/claude-teleport-private --silent 2>/dev/null || \
  echo "ℹ teleport hub not reachable (offline or permission). OK to ignore if you're not syncing now."

# User-level .claude/ changes (plugins, settings, marketplaces) — teleport scope
# NOTE: project .claude/ is versioned in the repo and does NOT need teleport.
# Teleport only syncs ~/.claude/installed_plugins.json, ~/.claude/settings.json,
# ~/.claude/plugins/marketplaces/, and user-scoped ~/.claude/skills/ (none on this machine).
# Portable mtime: BSD `stat -f '%m'` (macOS), GNU `stat -c '%Y'` (Linux), python fallback
get_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || \
    python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1])))" "$1" 2>/dev/null
}
USER_CLAUDE_MTIME=$(
  for f in ~/.claude/installed_plugins.json ~/.claude/settings.json; do
    [ -e "$f" ] && get_mtime "$f"
  done | sort -rn | head -1
)
if [ -n "$USER_CLAUDE_MTIME" ] && [ "$USER_CLAUDE_MTIME" -gt "$(($(date +%s) - 86400))" ]; then
  echo "ℹ user-level ~/.claude/ config changed recently. Consider /claude-teleport:teleport-push if changes should sync to other machines."
fi
```
User decides on teleport-push (external write — gate).

## Report
Summarize:
- What's in progress / ready to work on
- Any PRs waiting for review or merge
- Any failed workflow runs
- Any Renovate PRs needing attention
- Git state (clean or issues)

## Auto-continue (Claude's decision tree — not a menu for the user)

After reporting state, continue with the highest-priority item from this list. Do NOT ask the user to pick — proceed with the default, surfacing only the brief "resuming X" update.

Priority order:
1. **PR needs attention** → invoke `/pr <number>` or coderabbit:autofix for unresolved comments
2. **Renovate major awaiting approval** → flag to user (this IS a gate — user decides on majors)
3. **In-progress sub-issue with clear next step** → continue that work (baseline → build → commit cycle)
4. **Dirty git state** → ask user what to do (uncommitted changes are user territory)
5. **Nothing pressing** → ask "what should I pick up?" (only time session-start asks the user)

User interrupt phrases at any step: "wait", "stop", "different", "let me check", or naming a specific action.
