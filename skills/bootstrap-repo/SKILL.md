---
name: bootstrap-repo
description: Scaffold a NEW repository with the full claude-workflow-core workflow — pinned hooks, ship-pr-cycle wiring, .github SSOT, AI-reviewer configs, labels — at the plugin's CURRENT version. Use when starting a new project that should adopt the gold-standard workflow.
---

# bootstrap-repo

One call to scaffold a new repo so it consumes the SAME workflow as media-server
and pricing-team-toolkit, pinned to the plugin's CURRENT version (SSOT =
`.claude-plugin/plugin.json` — no hardcoded stale tag).

## Invoke

```bash
.claude/skills/bootstrap-repo/run.sh <target-dir>              # scaffold
.claude/skills/bootstrap-repo/run.sh <target-dir> --dry-run    # preview, no writes
.claude/skills/bootstrap-repo/run.sh <target-dir> --tag vX.Y.Z # pin a specific version
.claude/skills/bootstrap-repo/run.sh --verify                  # read-only drift check of an existing repo
```

The wrapper sets `SKILL_WRAPPER=1` and execs `scripts/bootstrap-repo.sh`.

## What it writes (idempotent — skips existing)

- `.pre-commit-config.yaml` — pinned plugin hooks (current version) + upstream linters
- `.claude/skills/ship-pr-cycle/` + `.claude/hooks/review-log.sh` — consumer workflow shims
- `.claude/local-overrides.yml`
- `.github/` — PR template, commit-template, labels, required-checks, `ISSUE_TEMPLATE/*`, labeler, gitleaks/pr-lint/pr-labeler workflows
- `.gemini/`, `.codex/config.toml`, `.coderabbit.base.yaml` (+ composes `.coderabbit.yaml`)
- applies labels via `gh label`

## After scaffolding (the script prints these)

1. `cd <target-dir> && git init && git add . && git commit -m 'initial: bootstrap from claude-workflow-core'`
2. `gh repo create <owner>/<repo> --source=. --push`
3. Enable GitHub Actions (Settings → Actions → General)
4. Branch protection on `main` (required checks per `.github/required-checks-list.yml`)
5. `pre-commit install`
6. Enable the marketplace plugin + add the repo to `MEMORY_DRIFT_EXTERNAL_ROOTS` (shell rc)
7. Run `scripts/bootstrap-machine.sh` if the machine isn't wired yet

## Notes

- `--verify` is read-only drift detection; `--force` overwrites (NEVER `--force` an
  existing consumer — it clobbers their customized config).
- Generic skills (git-commit, github-*) come from the enabled **marketplace plugin**,
  NOT copied per-repo — one SSOT source, no per-repo drift. This skill provides only
  the repo-local wiring the plugin can't deliver via the marketplace.
