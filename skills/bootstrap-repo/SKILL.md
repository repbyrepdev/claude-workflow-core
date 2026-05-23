---
name: bootstrap-repo
description: Scaffold a new consumer repo with full gold-standard SSOT wiring. Use when starting a new project that needs the ship-pr-cycle workflow (.pre-commit-config.yaml, .claude/ skills/hooks, .github/ templates + labels + workflows, .coderabbit.yaml, project board). Triggers: "bootstrap a new repo", "scaffold a new project", "set up workflow in this repo".
---

# bootstrap-repo

Scaffolds a new consumer repo to consume the `claude-workflow-core` plugin gold-standard workflow.

## Usage

```bash
.claude/skills/bootstrap-repo/run.sh --name <repo-name> [options]
```

Or via natural language: "bootstrap a new repo called <name>".

## What it does

1. **Verify prereqs**: plugin cache installed, gh authed, current dir is empty or `--in <dir>`
2. **git init** + initial commit
3. **Write `.pre-commit-config.yaml`** with pinned plugin rev + standard hook list (yamllint, shellcheck, shfmt, actionlint, ruff, gitleaks, markdownlint-cli2 + 20 plugin hooks)
4. **Write `.claude/skills/ship-pr-cycle/{SKILL.md,run.sh}`** wrapper (resolves to plugin cache)
5. **Write `.claude/hooks/review-log.sh`** shim (resolves to plugin cache)
6. **Write `.github/` scaffolding**:
   - `.github/labels.yml` — type/priority/area/plan-me labels
   - `.github/labeler.yml` — glob-based path → label mapping
   - `.github/required-checks-list.yml` — CR + lint-CI + gitleaks
   - `.github/commit-template.yml` — Conventional Commits schema
   - `.github/pull_request_template.md`
   - `.github/ISSUE_TEMPLATE/{bug,feature,task,epic,brainstorm}.yml`
   - `.github/workflows/` — minimum set: lint-ci, gitleaks
7. **Write `.coderabbit.yaml`** with full CR config (labeling_instructions + auto_planning + path_instructions)
8. **Write `.gemini/`, `.codex/`** baseline configs
9. **Write `.gitleaks.toml`** baseline
10. **Write `CLAUDE.md`** template (operator fills in repo-specific judgment rules)
11. **GitHub repo creation** via `gh repo create` (optional flag `--create-remote`)
12. **GitHub project board** via `gh project create` with Backlog/Ready/In Progress/Review/Done columns + Priority/Area/Type fields
13. **Print operator-action checklist**: enable workflows in Actions UI, configure branch protection, sync labels

## Options

- `--name <repo>` — repo name (required)
- `--in <dir>` — bootstrap in existing dir (default: ./<name>)
- `--plugin-rev <vX.Y.Z>` — plugin pin (default: latest)
- `--create-remote` — also `gh repo create`
- `--with-board` — create GitHub project board
- `--dry-run` — show what would happen

## Operator actions (manual after bootstrap)

The skill cannot do these for you (they require human decision or GitHub UI):

1. **Enable workflows** in `Actions` tab UI — workflows are created disabled by default
2. **Configure branch protection** on `main` (required reviews, status checks)
3. **Add secrets** in `Settings → Secrets`:
   - `CR_API_KEY` (if using CodeRabbit Pro)
   - `GEMINI_API_KEY` (if using Gemini review)
   - Any repo-specific secrets
4. **Run `pre-commit install --install-hooks`** in the new repo

## Acceptance

A new repo bootstrapped via this skill should have:
- Working `bash .claude/skills/ship-pr-cycle/run.sh status` (resolves to plugin cache)
- Working `pre-commit run --all-files` (all framework + plugin hooks)
- `gh issue list` showing 0 issues
- Project board ready for first issue

## Related

- `scripts/bootstrap-machine.sh` — sets up the machine itself (run BEFORE this skill)
- `bootstrap-machine.sh` + `bootstrap-repo` together = one-machine + one-repo from scratch in ~5 min
