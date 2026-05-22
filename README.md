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

## Roadmap (v0.2+)

Plans to bundle the 3 cwd-aware session-resilience hooks (`pre-compact-flush`, `persist-session-state`, `restore-session-state`) into this plugin so compaction safety works everywhere the plugin is installed, without depending on media-server's hook directory.

## Versioning + rollback

Plugin versions are tagged: `v0.1.0`, `v0.2.0`, etc. See `ROLLBACK.md` for recovery if a release breaks a consumer.

## Consumers

| Repo | Status |
| --- | --- |
| `repbyrepdev/plex_arr_media_stack` | Migrating in PR (deletes 8 local copies) |
| `FCP-Euro-Pricing-Team/pricing-team-toolkit` | Migrating in PR (deletes 8 local copies) |

## Why these 8?

These skills have ZERO domain-specific references in their bodies — pure workflow primitives that apply equally to any Claude Code repo. Domain skills (homelab's `deploy`/`add-container`, FCP's `sigma-lineage-trace`/`column-lineage`) stay in their respective repos.
