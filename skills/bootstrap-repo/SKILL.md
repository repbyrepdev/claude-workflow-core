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
- `.claude/skills/ship-pr-cycle/` + `.claude/hooks/{review-log,phase0.5-copilot-prefilter,post-commit-ship-cycle}.sh` — consumer workflow shims (the latter two are the ship-pr-cycle runtime shims, #223)
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

## Conditional-SSOT hooks (repo-specific behavior, ONE SSOT file) — #223

A hook that only makes sense in ONE repo (e.g. the homelab Fusion-e2e /
Docker-deploy gates that belong to media-server, or the
coalesce-gracie-only-gate that belongs to pricing-team-toolkit) must NOT be a
local-only file living in that repo. A local-only hook can't be hash-tracked
(`scripts/hash-drift.sh`), rots silently, and isn't propagated by bootstrap —
the exact anti-pattern this plugin exists to kill.

Instead, ship it as ONE plugin-SSOT file under `hooks/` that **self-skips**
(cleanly no-ops) in every repo except its target(s), via `_lib/repo-guard.sh`:

```bash
#!/bin/bash
set -euo pipefail
# event: PreToolUse   (etc.)
_RG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
# shellcheck source=../_lib/repo-guard.sh
. "$_RG_LIB/repo-guard.sh"
repo_guard_require media-server || exit 0      # self-skip outside media-server
# ... target-repo-only hook body runs only here ...
```

Multiple targets: `repo_guard_require media-server homelab || exit 0`. Slug
matching is case-insensitive and tolerant of a `.git` suffix and `owner/`
prefix; detection prefers the git `origin` basename, then the git toplevel dir
basename, then `$PWD` basename (never hard-errors a hook). Because the file
lives under `hooks/`, it is hash-tracked + version-gated + bootstrap-shipped
like every other plugin hook — one SSOT, drift-gated, with zero per-repo
copies.

## Notes

- `--verify` is read-only drift detection; `--force` overwrites (NEVER `--force` an
  existing consumer — it clobbers their customized config).
- Generic skills (git-commit, github-*) come from the enabled **marketplace plugin**,
  NOT copied per-repo — one SSOT source, no per-repo drift. This skill provides only
  the repo-local wiring the plugin can't deliver via the marketplace.
