---
name: memory-consolidate
description: Use when user says "consolidate memory", "audit memory", "clean up memories", "dedupe memories", or when the weekly drift validator flags overlap. Scans `~/.claude/projects/-Users-adamsfamily/memory/*.md` for topic duplication, outdated references, split-by-accident feedback files, and underspecified memories. Proposes explicit merges — never auto-mutates. User approves each merge before applying.
allowed-tools: Bash(*), Read, Edit, Write, Grep
---

# Memory Consolidate — dedupe and maintain the memory corpus

Companion to `claude-md-management` (CLAUDE.md audits) and `validate-meta-freshness.sh` (#232). This skill scopes to the `memory/` directory: detect redundancy, propose merges, keep the corpus tight.

## When to invoke

- User says "consolidate memory", "audit memory", "clean up memories", "dedupe memories"
- Weekly meta-freshness validator (#232) flags overlap
- Proactive: every time memory/ crosses a round number of files (20, 30, 40...)

## Step 1: Inventory

```bash
MEM="$HOME/.claude/projects/-Users-adamsfamily/memory"
ls -la "$MEM"/*.md | wc -l    # count
```

For each file, extract:
- Frontmatter `name:` and `description:`
- First 500 chars of body
- Last-modified timestamp
- Type (user / feedback / project / reference from frontmatter)

## Step 2: Find overlap

Four detection patterns:

### A. Topic duplication

Compute pairwise similarity of `description:` fields (Jaccard on word sets, threshold 0.4). Pairs above threshold are merge candidates.

Example detectable overlap:
- `feedback_full_cycle_rebuild.md` — "PRs touching maintain.sh ... aren't done until every stack is rebuilt"
- `feedback_deep_audit.md` — "triple-check every finding before acting"

If they cover the SAME scenario from different angles → merge candidate.

### B. Outdated references

For each memory, grep the body for:
- File paths → check `ls` existence
- Issue/PR refs → check state (closed >180 days ago = stale)
- Version tags → check current latest tag

Report stale refs per memory.

### C. Split-by-accident

Memories with similar names but no explicit delineation (`feedback_autonomy_gates.md` + `feedback_workflow_pattern.md` + `feedback_batch_related_subissues.md` — do they cover distinct ground or overlap?)

Read bodies, look for:
- Same rule appearing in 2+ files
- Rules that reference each other (indicate tight coupling — could be one file)

### D. Underspecified feedback

Every `feedback_*.md` must have `**Why:**` + `**How to apply:**` per CLAUDE.md memory rule. Pre-commit hook #239 blocks new violations; this skill scans existing files + proposes additions for grandfathered ones.

## Step 3: Propose merges

For each candidate, produce:

```markdown
## Merge proposal: `<source-files>` → `<target-file>`

**Rationale:** <why they overlap — cite specific sentences>

**Proposed target:** `<new or existing filename>`

**Proposed content:**
<markdown preview of merged file>

**Files to delete:** <list>

**MEMORY.md diff:**
  - [Before] <old line>
  + [After]  <new line>

[ ] Approve merge
[ ] Skip
```

Present all merge candidates in one review; user ticks which to apply.

## Step 4: Apply approved merges

For each approved:
1. Write target file
2. Delete source files
3. Update MEMORY.md index
4. Run `.claude/pre-commit-hooks/memory-index-valid.sh` to confirm integrity post-merge
5. Stage changes (do NOT commit — let user drive)

## Step 5: Report

Summary:
- N memories before, M after
- K merges applied
- X stale refs fixed
- Y underspecified memories updated

## Rules

- **Never** auto-merge without user approval per-candidate
- **Never** delete a source file before writing the target (ordering for safety)
- **Always** preserve all information from source files — merge = combine, not discard
- **Always** re-run memory-index-valid hook after merges to confirm integrity
- **Never** reduce below the minimum useful count — if consolidation would leave <5 memories, pause and reconsider (usually signals over-aggressive merging)

## Current memory corpus (snapshot as of v3.19)

16 files:
- 1 user profile, 2 homelab refs, 1 secrets, 1 project
- 11 feedback memories (candidates for overlap review)

Likely merge candidates (analyze first):
- `feedback_autonomy_gates.md` + `feedback_workflow_pattern.md` (both cover workflow gates)
- `feedback_deep_audit.md` + `feedback_full_cycle_rebuild.md` (both cover verification discipline)
- `feedback_batch_related_subissues.md` (standalone — specific scope, likely keep)

Run the skill to produce concrete proposals.

## Acceptance criteria

- Running on current memory produces ≥1 merge candidate OR explicit "no overlap found"
- Proposed merges preserve all information
- User approval gate explicit
- Memory-index-valid hook clean post-merge
