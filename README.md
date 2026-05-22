# claude-workflow-core

Damien Adams' Claude Code plugin — 8 portable workflow skills shared across multiple repos (media-server, pricing-team-toolkit, etc.).

**Marketplace + plugin in one repo** (per Claude Code's standard pattern, see `.claude-plugin/`).

## Skills bundled

| Skill | Purpose |
| --- | --- |
| `ack` | Batch-acknowledge pending hook-ack entries |
| `brainstorm` | Structured Problem/Options/Tradeoffs/Recommendation discussion mode |
| `creating-skills` | Meta-skill: how to write SKILL.md (Anthropic-style) |
| `deep-audit` | N parallel agents + triple-check, fix-in-place |
| `memory-consolidate` | Dedupe + merge memory files |
| `prove-yourself-audit` | Mechanical enforcement of the prove-yourself rule |
| `retro` | Session retrospective from `.claude/session-log.jsonl` |
| `cr-plan` | CodeRabbit Issue Planner parser → epic + sub-issues |

## Installation

```bash
# 1. Add the marketplace (one-time per machine)
/plugin marketplace add repbyrepdev/claude-workflow-core

# 2. Install the plugin
/plugin install claude-workflow-core@claude-workflow-core
```

After install, the 8 skills are available globally under the `claude-workflow-core:` namespace.

## v0.2.0 — session-resilience hooks bundled

The 3 cwd-aware session hooks now ship in `hooks/`:

| Hook | Event | Purpose |
| --- | --- | --- |
| `pre-compact-flush.sh` | `PreCompact` | Snapshot session log + state before /compact summarization |
| `persist-session-state.sh` | `PostToolUse` | Write current PR/branch/cmd to `.claude/.session-state/` |
| `restore-session-state.sh` | `SessionStart` | Surface `additionalContext` from .session-state on resume |

All 3 use `git rev-parse --show-toplevel` so they write to the CURRENT repo's `.claude/` dir, NOT a hardcoded media-server path. Compaction safety works in any cwd.

**Registration:** `~/.claude/settings.json` references each hook script's absolute path. After plugin install (or update), update settings.json to point at the plugin cache:

```
~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.2.0/hooks/<name>.sh
```

(Damien can also keep references to media-server hook paths during a transition — both work since the hook content is identical.)

## Versioning + rollback

Plugin versions are tagged: `v0.1.0`, `v0.2.0`, etc. See `ROLLBACK.md` for recovery if a release breaks a consumer.

## Consumers

| Repo | Status |
| --- | --- |
| `repbyrepdev/plex_arr_media_stack` | Migrating in PR (deletes 8 local copies) |
| `FCP-Euro-Pricing-Team/pricing-team-toolkit` | Migrating in PR (deletes 8 local copies) |

## Why these 8?

These skills have ZERO domain-specific references in their bodies — pure workflow primitives that apply equally to any Claude Code repo. Domain skills (homelab's `deploy`/`add-container`, FCP's `sigma-lineage-trace`/`column-lineage`) stay in their respective repos.
