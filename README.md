# claude-workflow-core

Damien Adams' Claude Code plugin — **portable workflow skills + session-resilience hooks** shared across multiple repos (media-server, pricing-team-toolkit, etc.).

**Marketplace + plugin in one repo** (per Claude Code's standard pattern, see `.claude-plugin/`).

## What's in v0.3.0

### Skills (15 total)

**Ship-PR workflow (NEW in v0.3.0)** — extracted from homelab and FCP toolkit where they were duplicated:

| Skill | Purpose |
| --- | --- |
| `git-commit` | Conventional Commits + project schema, Copilot-assisted draft |
| `github-issue-creation` | Read template + label + milestone + ai-triage + board-sync per repo |
| `github-epic-creation` | Parent epic + N sub-issues with `addSubIssue` GraphQL linkage |
| `github-pr-creation` | Branch + PR open + body-from-template + Copilot draft |
| `github-pr-review` | Multi-agent local review (Phase 0/1/2) wrapper |
| `github-pr-merge` | Verifier + user gate + post-merge housekeeping |
| `session-start` | Memory check + board state + open PRs + Renovate dashboard + git state |

**Meta + workflow primitives (v0.2.0 baseline)**:

| Skill | Purpose |
| --- | --- |
| `ack` | Batch-acknowledge pending hook-ack entries |
| `brainstorm` | Structured Problem/Options/Tradeoffs/Recommendation discussion mode |
| `creating-skills` | Meta-skill: how to write SKILL.md (Anthropic-style) |
| `deep-audit` | N parallel agents + triple-check, fix-in-place |
| `memory-consolidate` | Dedupe + merge memory files |
| `retro` | Session retrospective from `.claude/session-log.jsonl` |
| `prove-yourself-audit` | Mechanical enforcement of the prove-yourself rule |
| `cr-plan` | CodeRabbit Issue Planner parser → epic + sub-issues |

### Session-resilience hooks (3)

| Hook | Event | Purpose |
| --- | --- | --- |
| `pre-compact-flush.sh` | `PreCompact` | Snapshot session log + state before `/compact` summarization |
| `persist-session-state.sh` | `PostToolUse` | Write current PR/branch/cmd to `.claude/.session-state/` |
| `restore-session-state.sh` | `SessionStart` | Surface `additionalContext` from .session-state on resume |

All hooks use `git rev-parse --show-toplevel || pwd` so they work in any cwd.

## Installation

```bash
# 1. Add the marketplace (one-time per machine)
/plugin marketplace add repbyrepdev/claude-workflow-core

# 2. Install the plugin
/plugin install claude-workflow-core@claude-workflow-core
```

After install, skills are available under the `claude-workflow-core:` namespace.

## Per-repo customization

Skills carry homelab-flavored notes in some areas (e.g. `github-pr-merge` Step 8-10 about Docker recreate / Fusion e2e tests). These are illustrative — adapt or skip per your repo:

- **homelab** (`repbyrepdev/plex_arr_media_stack`) — full chain including docker recreate, e2e, tag+release
- **FCP toolkit** (`FCP-Euro-Pricing-Team/pricing-team-toolkit`) — skip Steps 8-10 (no docker; promotion to upstream is manual via Catalog UI)

If divergence becomes problematic, future v0.x can split content into `recipes/<repo>.md` overlays.

## Coming in v0.4 - v0.7

| Version | Content |
| --- | --- |
| v0.4 | 15 generic pre-commit-hooks + `.pre-commit-hooks.yaml` for gold-standard pre-commit `repo:` consumption |
| v0.5 | 18 `_lib/` helpers |
| v0.6 | ~40 generic `.claude/hooks/` (Phase 0.5/1, lint-gate, memory-guard, etc.) |
| v0.7 | Portable scripts (try-free.sh, board helpers); canonical version both consumers pin to |

See FCP toolkit issue [#22](https://github.com/FCP-Euro-Pricing-Team/pricing-team-toolkit/issues/22) for the full unification roadmap.

## Versioning + rollback

Plugin versions are tagged: `v0.1.0`, `v0.2.0`, `v0.3.0`. See `ROLLBACK.md` for recovery if a release breaks a consumer.

## Consumers

| Repo | Status |
| --- | --- |
| `repbyrepdev/plex_arr_media_stack` | Migration to plugin v0.7.0 tracked in [#22-PR6](https://github.com/FCP-Euro-Pricing-Team/pricing-team-toolkit/issues/28) |
| `FCP-Euro-Pricing-Team/pricing-team-toolkit` | Migration tracked in [#22-PR7](https://github.com/FCP-Euro-Pricing-Team/pricing-team-toolkit/issues/29) |
