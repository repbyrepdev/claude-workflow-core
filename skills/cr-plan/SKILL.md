---
name: cr-plan
description: Trigger CodeRabbit Issue Planner on a GitHub issue OR parse a CR-generated plan and auto-create epic+sub-issues. Use when an issue needs structured implementation planning before work begins.
---

# CodeRabbit Plan Skill

Drives the issue → plan → epic+subs flow programmatically using CodeRabbit's Issue Planner + our `github-epic-creation` skill for the linkage CR doesn't natively do.

## Two subcommands

### `trigger <issue-num>`

Apply `plan-me` label + post `@coderabbitai plan` comment on the issue. CR posts a structured plan comment within 5-10 min. Label add is idempotent; comment is skipped when `plan-me` already present (retry-safe — prevents duplicate planner runs). Only `no-plan` exits entirely.

```bash
.claude/skills/cr-plan/run.sh trigger 712
```

### `parse <issue-num>`

Read the CR plan comment from the issue, extract the `## Phases` OR `## Implementation Steps` section (CR's actual emitted format uses `Implementation Steps`; the older `Phases` form is also accepted for backward compatibility — see #788), invoke `github-epic-creation` skill to create epic + sub-issues per phase. Sub-issues are linked via GraphQL `addSubIssue` (CR doesn't do this — fills the gap). After parse, GitHub shows progress bar on the parent epic.

```bash
APPROVE=1 .claude/skills/cr-plan/run.sh parse 712
```

`APPROVE=1` is required (mirrors github-issue-creation skill's non-interactive guard).

## Flow

1. Operator (or ai-triage / CR Enrichment) labels issue `plan-me`
2. CR Issue Planner auto-plans → posts plan comment with `Implementation Steps` (or `Phases`) section
3. Operator runs `cr-plan parse <N>` → reads plan → creates epic + sub-issues with GraphQL linkage
4. GitHub native sub-issue progress bar appears on parent epic
5. Operator works subs → each merge closes sub → `auto-close-parent.yml` closes epic when all subs close

## Defensive fallback

CR's plan markdown structure isn't formally spec'd in their docs. The parser accepts either `## Implementation Steps` (CR's current emitted form) or `## Phases` (older form) as the section heading, with `### Phase N:` / `**Phase N:**` entries as the primary form and a numbered-list (`1. ...`) fallback. If structure differs from expectation:
- Skill prints the full plan
- Surfaces "operator: copy phase headings + invoke github-epic-creation manually"
- Exits rc=2 (fail loud, no half-baked epic created)

## Why not let CR do it all?

CR provides the AI plan generation — strong context awareness via issue history, related items, web search. CR does NOT do GitHub sub-issue linkage (`addSubIssue` GraphQL mutation). Our `github-epic-creation` skill fills that gap. Combined: AI planning from CR + structural linkage from us = full automation.

## Required tools

- `gh` (GitHub CLI) — authed
- `jq` — JSON parsing
- `.claude/skills/github-epic-creation/run.sh` — for the actual epic+subs creation

## Tests

`.claude/tests/skills/cr-plan-run.bats` covers:
- `trigger` happy path + idempotency + nonexistent-issue rejection
- `parse` with fixture plan markdown → invokes github-epic-creation correctly
- `parse` with malformed plan markdown → defensive fallback (rc=2)
- `parse` requires `plan-me` label (forces correct flow)
- `parse` requires APPROVE=1 (non-interactive guard)
