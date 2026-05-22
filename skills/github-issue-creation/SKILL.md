---
name: github-issue-creation
description: Create GitHub issues following this repo's template + label conventions. Use when user wants to create an issue, open a bug report, file a feature request, log a task, or add a sub-issue to a parent. Handles the "templates only work in web UI" constraint by reading the YAML template and replicating its structure manually via gh issue create.
---

# GitHub Issue Creation

Creates GitHub issues matching the repo's template + label conventions.

## Preferred entry point (v4.20 #519): `run.sh` wrapper

Invoke `.claude/skills/github-issue-creation/run.sh` to get the full flow
(template validation → auto-milestone → create → optional parent-link → cap-
deferral ai-triage + project-board-sync) in one call. Sets `SKILL_WRAPPER=1`
internally so skill-bypass-guard honors its gh calls.

```bash
# v4.28-W3-CD #746: Copilot-default — body-file optional now.
.claude/skills/github-issue-creation/run.sh \
  --template task --title "…" \
  [--body-file /tmp/body.md] \
  [--label …] [--milestone vX.Y] [--parent N] [--assignee @me] \
  [--no-copilot]
```

### Copilot-default body (v4.28-W3-CD #746)

When `--body-file` is omitted, the wrapper auto-drafts the issue body via
Copilot free-tier. Mirrors the pattern from #743 (git-commit) and #745
(github-pr-creation).

```bash
# Default — wrapper auto-drafts body for the template:
.claude/skills/github-issue-creation/run.sh --template task --title "…" --parent N

# Explicit body overrides:
.claude/skills/github-issue-creation/run.sh --template task --title "…" --body-file body.md --parent N

# Opt-out per-invocation (must supply --body-file):
.claude/skills/github-issue-creation/run.sh --template task --title "…" --no-copilot --body-file body.md --parent N

# Opt-out via env:
COPILOT_DRAFT_OFF=1 .claude/skills/github-issue-creation/run.sh --template task --title "…" --body-file body.md --parent N
```

**Behavior:**
- Default (no `--body-file` + Copilot helper present): wrapper drafts body, runs required-section preflight, then asks for create approval
- Explicit `--body-file`: precedence over draft
- `--no-copilot` or `COPILOT_DRAFT_OFF=1` + no body-file: refuses with rc=2
- Copilot helper missing or returns empty: refuses with rc=3
- Copilot draft fails required-section preflight: refuses with rc=4 (operator-supplied bodies stay rc=2)

The inline flow documented below is the **pre-v4.20 manual path**, preserved
as a fallback when the wrapper is unsuitable (e.g. custom args not yet
flagged, debugging a specific step). Prefer the wrapper.

## Core constraint

GitHub issue templates (`.github/ISSUE_TEMPLATE/*.yml`) **only auto-populate when created via the web UI**. From the `gh` CLI, `--template` is silently ignored when `--body`/`--body-file` is provided. **I must read the YAML template and replicate its structure manually.**

## Issue templates in this repo

| Template | Required fields |
|---|---|
| `bug.yml` | Area + `--parent` (mechanically required) |
| `feature.yml` | Area + `--parent` (mechanically required) |
| `task.yml` | Area + `--parent` (mechanically required) |
| `epic.yml` | Area + goal + scope + sub_issues + acceptance + rollout + rollback (`--parent` rejected) |
| `brainstorm.yml` | Area + topic |

Read `.github/ISSUE_TEMPLATE/<name>.yml` before creating — match the template's exact field headings in the `--body` content.

**Labels are applied server-side by `.github/workflows/ai-triage.yml` (Claude-driven) as of v3.23.E — do NOT pass `--label` to `gh issue create`.** Template frontmatter auto-applies the type label (`bug` / `enhancement` / `epic` / `brainstorm`), and ai-triage sets `priority:*` + `area:*` + (for epics) the board `Type=Epic` pill. Confidence <0.7 → `priority:needs-triage` for human classification.

## Core workflow

### 1. Determine issue type

- **Bug** (something broken) → use `bug.yml` structure
- **Feature** (new capability) → use `feature.yml` structure
- **Task** (sub-issue under an epic; infrastructure work) → use `task.yml` structure

If unclear, ask the user. If the work is part of an existing parent epic (e.g., v3.5), it's a task.

### 2. Read the matching template

```bash
# Example for a task
cat .github/ISSUE_TEMPLATE/task.yml
```

Extract the field labels, required markers, and placeholder text. Your `--body` content should match this structure.

### 3. Labels — server-side, do NOT pass `--label`

Since v3.23.E, `.github/workflows/ai-triage.yml` applies `priority:*` + `area:*` labels automatically on issue open + edited events. Template frontmatter handles the type label (`bug` / `enhancement` / `epic` / `brainstorm`). Do **NOT** pass `--label` to `gh issue create` — a manually-applied label at open time blocks ai-triage from re-classifying (by design, so humans can override).

For epics, use `.github/ISSUE_TEMPLATE/epic.yml` — auto-applies `epic` + `enhancement`; ai-triage sets board `Type=Epic` pill.

### 4. Determine milestone

```bash
# Find open milestones — assign to the active one
gh api repos/$(gh repo view --json nameWithOwner -q '.nameWithOwner')/milestones \
  --jq '.[] | select(.state == "open") | "\(.number): \(.title)"'
```

- One open milestone → assign the issue to it
- Multiple → ask user which
- None → skip (don't create one automatically)

### 5. Determine parent (REQUIRED for bug/feature/task, REJECTED for epic)

**v4.28-W2 (#646): `--parent` is now MECHANICALLY REQUIRED for `--template bug`, `--template feature`, and `--template task`.** The wrapper exits 2 with `--parent <issue-num> is required` if omitted; YAML templates also have `validations.required: true` on the parent field so manual web-UI creation refuses too. Sub-issues without parents orphan into Backlog with no epic-progress correlation — past misses (#526 board-field skip class) followed the same shape, so we made it not-optional.

For epics: `--parent` is REJECTED (`error: --parent is not valid for --template epic — epics are top-level`).

If genuinely standalone work exists (no epic to attach to), file an epic first via `--template epic`, then file the sub-issue under it.

GitHub's sub-issue linking is a separate API call after creation; the wrapper handles it via `skc_graphql_add_sub_issue` when `--parent N` is passed:

```bash
# After creating issue $NEW_NUM under parent $PARENT_NUM:
gh api graphql -f query='
  mutation {
    addSubIssue(input: {issueId: "<NEW_NODE_ID>", subIssueId: "<PARENT_NODE_ID>"}) {
      issue { number }
    }
  }'
```
(Easier: add via web UI → "Add sub-issue" button. Sub-issues still show up on the project board.)

### 6. Show content for user approval — GATE

**ALWAYS show title, body, labels, milestone, and parent link for user approval BEFORE running `gh issue create`.**

Template:
```
Creating issue:
  Type: <bug|feature|task>
  Title: <title>
  Labels: <enhancement|bug>, <area>
  Milestone: <title> (or none)
  Parent: #<N> (or none)

Body:
<full body matching template structure>

Approve? (yes / edit / no)
```

### 7. Create

```bash
gh issue create \
  --title "<title>" \
  --milestone "<milestone-title>" \
  --body "$(cat <<'EOF'
**Area:** <area>

**What needs to be done?**
<clear description>

**Context:**
<background, constraints, links to related issues>
EOF
)"
```

- No `--label` flag — ai-triage applies labels server-side
- HEREDOC for multi-line body to preserve formatting
- No `--template` — it's ignored when `--body` is present

### 8. Link as sub-issue (if applicable)

If a parent was specified, run the sub-issue GraphQL mutation above.

### 8b. Assign PARENT issues at creation (board-transition trigger)

**v4.5.D note:** during the Actions cap (#366), also fire
`.claude/local-backups/project-board-sync.sh --on-assign "$NEW_NUM"`
immediately after the parent-epic auto-assign. Without it, the parent
sits in Backlog on the board until someone manually syncs — exactly
the gap v4.5 is closing.



**If this new issue IS a parent/epic** (meaning: sub-issues will be attached to it, usually a version-bumping epic like "v3.5 feature X"), **auto-assign it to the user at creation AND fire the board-sync** (v4.5.D — otherwise parent stays in Backlog during cap):

```bash
gh issue edit "$NEW_NUM" --add-assignee "@me"
# v4.5.D: fire Status=In Progress on the board since project-automation.yml
# is disabled during the cap. When the workflow is re-enabled post-cap,
# this call is idempotent (no-op on already-correct Status).
.claude/local-backups/project-board-sync.sh --on-assign "$NEW_NUM"
```

**Why:** without this, the parent sits in Backlog the whole time its sub-issues are being worked on. The `.github/workflows/project-automation.yml` only moves issues to "In Progress" on `issues.assigned` events — and during the cap it isn't firing at all. Both the assign AND the sync are needed.

**How to know it's a parent:** title starts with a version (`v3.5: ...`), description says "Epic" or "parent of sub-issues", or user explicitly says "this is a parent/epic". Sub-issues (task.yml/feature.yml/bug.yml) themselves are NOT parents — don't auto-assign them unless user asks.

**Skip for non-parent:** don't auto-assign individual task/bug/feature sub-issues — those get assigned when the user picks them up for work.

### 9. Post-create board sync (v4.5.C) — MANDATORY during Actions cap

When `.github/workflows/ai-triage.yml` is disabled (detectable via `.claude/hooks/detect-actions-cap.sh` → exit 1), the server-side triage + board-field dual-write does NOT happen. Run the local equivalent immediately after creation:

```bash
# 1. Local triage — get Priority/Area/Type classification using the same
#    prompt the workflow would have used. Invoke Claude (me) with the
#    classification prompt resolved by ai-triage.sh:
.claude/local-backups/ai-triage.sh "$NEW_NUM"
# Read the output, apply classification via gh issue edit:
gh issue edit "$NEW_NUM" --add-label priority:pX --add-label area:Y [--add-label epic]

# 2. Dual-write Priority/Area/Type fields to the Homelab board:
.claude/local-backups/project-board-sync.sh "$NEW_NUM"

# 3. If assigning self (auto-continue case), also fire Status=In Progress:
gh issue edit "$NEW_NUM" --add-assignee @me
.claude/local-backups/project-board-sync.sh --on-assign "$NEW_NUM"
```

Skip steps 1-2 if cap is NOT active (workflow will fire). The github-pr-creation skill similarly calls `--on-pr-open` and `--on-close` at the right moments.

**v4.20 (#504) investigation note:** verified today (2026-04-21) on #526 — filed via the skill-tool invocation path, it got `enhancement`+`area:infrastructure` from `--label` flags but NO `priority:*` and NO Priority/Area board-field dual-write because Claude skipped Step 9. The gap is Claude-behavior (forgot-to-run), not a script gap — ai-triage.sh and project-board-sync.sh themselves work correctly (re-ran them on #526 and all 3 fields populated). Mechanical enforcement (a SKILL_WRAPPER-style script that packages ai-triage+sync as one call and asserts success) is deferred to the v4.20 skill-as-script-wrappers sub-issue under #519.

### 10. Verify

```bash
gh issue view <NEW_NUM> --json number,title,state,labels,milestone,assignees -q '"#\(.number) \(.title) | labels=\(.labels | map(.name)) | milestone=\(.milestone.title // "none")"'
```

Confirm labels, milestone, and state match intent. If cap-era, also verify the board fields populated:

```bash
gh api graphql -f query='query($n:Int!){repository(owner:"repbyrepdev",name:"plex_arr_media_stack"){issue(number:$n){projectItems(first:5){nodes{fieldValues(first:20){nodes{... on ProjectV2ItemFieldSingleSelectValue{field{... on ProjectV2SingleSelectField{name}} name}}}}}}}}' -F n=<NEW_NUM> | jq '.data.repository.issue.projectItems.nodes[0].fieldValues.nodes | map(select(.name)) | map("\(.field.name)=\(.name)")'
```

Expect: `["Status=...", "Priority=PX", "Area=...", "Type=..."]`.

## Board automation (fires automatically after creation)

Currently disabled per issue #366 (Actions cap). When re-enabled:
- `ai-triage.yml` handles Priority/Area/Type field dual-write
- `project-automation.yml` handles Status transitions (Backlog → In Progress on assign → Review on PR open → Done on close)

While disabled, the post-create board sync block above is the manual equivalent + the built-in Projects workflows still handle auto-add-to-Backlog + auto-add-sub-issues + auto-archive.

## Auto-continue

After successful issue creation:
- If this is the user's next work item → auto-run `gh issue edit $N --add-assignee @me` + `project-board-sync.sh --on-assign $N` + create a branch
- If this is backlog/future work → report the new issue number, no further action (user will pick it up later)
- If parent was linked → the parent's sub-issue progress updates automatically (GitHub native)

**If creating 3+ sub-issues under the same epic at once** → surface the batching option to the user: "These are all sub-issues of #P — want to work them on ONE branch with ONE PR (`Closes #A #B #C` in body) to save CodeRabbit rate limit?" See `github-pr-creation` SKILL.md "Batching related sub-issues + local-iterate" for the full pattern.

GATE: no post-creation gate needed; issue creation is low-risk. The gate is BEFORE creation (show-for-approval in step 6).

## Rules

- **ALWAYS** fire Step 9 (ai-triage.sh + project-board-sync.sh) after `gh issue create` during Actions cap. v4.11.F 2026-04-20 miss: created 7 sub-issues #451-#457 with only `--label` at creation, skipped Step 9, left board fields empty. Manual cleanup was 7×gh-edit + 7×board-sync calls. Never again — Step 9 is part of the verb "create an issue", not optional polish.
- **ALWAYS** show issue content for approval before `gh issue create`
- **ALWAYS** read the matching ISSUE_TEMPLATE YAML first to match its structure
- **ALWAYS** check for open milestones and assign if one is active
- **ALWAYS** use HEREDOC for body to preserve formatting
- **NEVER** pass `--label` to `gh issue create` — ai-triage applies `priority:*` + `area:*` server-side (v3.23.E). A manually-applied label blocks auto-classification.
- **NEVER** combine `--template` with `--body` — `--template` gets silently ignored
- **NEVER** create a milestone automatically
