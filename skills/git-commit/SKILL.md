---
name: git-commit
description: Creates git commits following Conventional Commits format with type/scope/subject. Use when user wants to commit changes, create commit, save work, or stage and commit. Enforces project-specific conventions from CLAUDE.md.
---

# Git commit

Creates git commits following Conventional Commits format.

## Recent project commits

!`git log --oneline -5 2>/dev/null`

## Quick start

```bash
# 1. Stage changes
git add <files>

# 2. Validate before commit
pre-commit run --files <files>
# (and run the relevant test command for changed code paths)

# 3. Create commit
git commit -m "type(scope): subject"
```

## Test discipline — exercise the thing before commit

**Lint passing is not "it works". Run the actual thing with representative input.**

Same rule as the health-check skill for containers (query every panel's PromQL, don't just check "dashboard loaded") applied to code/process changes. Pick the matching checklist below based on what you changed:

| Change type | What "exercise it" looks like |
|---|---|
| **Hook script** (`.claude/hooks/*.sh`) | `bash -n <file>` (syntax), `shellcheck <file>`, feed representative JSON via `echo '{"tool_input":{"command":"..."}}' \| ./hook.sh` — verify expected stdout. Test empty input, malformed input. |
| **Skill bash commands** | Copy each code block out of the SKILL.md and run it in a real shell. Verify output format, not just exit code. |
| **New `gh api`/`gh` query** | Run the query, inspect the JSON — did you get fields you expected? Did pagination cut off? Try `--paginate` if it's a list endpoint. |
| **Workflow file** (`.github/workflows/*.yml`) | `actionlint <file>`, then trigger locally via `act` if possible or push to a test branch. |
| **Pre-commit config** | `pre-commit validate-config`, then `pre-commit run --all-files` on a real repo state. |
| **Compose/stack change** | Deploy to the stack, health-check before + after, verify the feature actually does its job (not just "healthy") — use the `deploy` skill. |
| **Config file** (CodeRabbit, Renovate, etc) | Use context7 MCP to confirm schema first. Then push to a test branch or dry-run the tool. |
| **Doc/markdown** | Actually render or read the changed section top-to-bottom — does it still make sense? Are code blocks fenced correctly? |
| **Memory file** | Re-read the index after saving — is the new entry findable? |

**Before saying "done" or committing:** run the matching exercise. If you can't exercise it (e.g., requires production), say so explicitly rather than claiming it works.

## Project conventions

**SSOT: `.github/commit-template.yml`** — schema, required types, length limits, body rules, and canonical exemplars all live there. This section summarizes; the YAML is authoritative.

- Format: `<type>(<optional_scope>): <summary>` — 70-char subject max (per Conventional Commits 1.0.0)
- Scope is version-tagged for epic work (`v4.23`, `v4.24`) or kebab-case for scoped work (`validation`, `auth`)
- Required types: `feat`, `fix`, `refactor`, `perf`, `chore`, `test`, `docs`, `build`, `ci`, `revert`
- **Body required** for `feat`, `fix`, `refactor`, `perf` — explain WHY not WHAT
- HEREDOC for multi-line:

```bash
git commit -m "$(cat <<'EOF'
feat(v4.23): scaler + diff-hash cache (#547 #553)

Prior 5-round fixed Phase 1 was expensive on small diffs. Scaler computes
tier from LOC + sensitive-path + file-type; cache keys on per-agent diff
hash so unchanged files skip re-review. Measured 60-70% token reduction.

Closes #547 #553
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

## Copilot-drafted message (DEFAULT as of v4.28-W3-CD #675)

The wrapper now auto-drafts the commit message via Copilot free-tier when no `--message` / `--message-file` is supplied. 0 premium requests consumed on Enterprise seats (gpt-4.1 / gpt-5-mini / gpt-4o all have 0× multiplier).

```bash
# Default — wrapper auto-drafts:
.claude/skills/git-commit/run.sh

# Explicit message overrides the draft:
.claude/skills/git-commit/run.sh --message "fix(scope): subject"

# Opt out per-invocation (must supply --message / --message-file):
.claude/skills/git-commit/run.sh --no-copilot --message "fix(scope): subject"

# Opt out via env (useful for trusted-edit flows):
COPILOT_DRAFT_OFF=1 .claude/skills/git-commit/run.sh --message "..."
```

**Behavior:**
- Default (no flags + Copilot helper present): wrapper drafts via Copilot, runs pre-commit hooks, commits
- `--message` / `--message-file`: explicit message takes precedence, no Copilot call
- `--no-copilot` or `COPILOT_DRAFT_OFF=1` + no message: refuses with rc=2 (clear remediation)
- Copilot helper missing or returns empty: refuses with rc=3 (distinct from arg-error rc=2)

Post-commit validation fires automatically via `.claude/hooks/post-commit-template-lint.sh` (PostToolUse Bash hook) — warns if the committed message drifts from `.github/commit-template.yml` schema. Non-blocking; drift only triggers a stderr warning so you can fix in the next commit.

## Secret scanning — 3 layers

This repo has three independent gitleaks layers sharing the same `.gitleaks.toml`:

1. **Pre-commit** (local, on staged files) — 700+ secret patterns + blocks `.env` files. **Bypassable with `--no-verify`** — NEVER use `--no-verify` to skip this; if a scan fails, fix the secret or update `.gitleaks.toml` allowlist.
2. **Gitleaks GitHub Action** (server, on PR + push to main) — same config, server-side scan. Cannot be bypassed. Catches anything `--no-verify` slipped past.
3. **Full history scanned clean** — allowlists in `.gitleaks.toml` cover `.enc` files and pre-SOPS commits.

If pre-commit blocks a commit, DO NOT run `--no-verify`. Read the error, remove the secret, re-stage, try again. If the finding is a false positive, update `.gitleaks.toml` allowlist.

## Important rules

- **ALWAYS** read `.github/commit-template.yml` as the canonical schema source (SSOT)
- **ALWAYS** include type + scope per the template (scope required for version work: `feat(v4.24): ...`)
- **ALWAYS** run relevant tests/validation before committing
- **ALWAYS** use present tense imperative verb for the subject
- **ALWAYS** include `Co-Authored-By:` trailer on Claude-assisted commits (per template footer rules)
- **NEVER** end subject with a period
- **NEVER** exceed **70 chars** in the subject line (per commit-template.yml, updated from legacy 50)
- **NEVER** use anti-pattern messages listed in commit-template.yml (`fixed bug`, `wip`, `misc`, etc.)
- **NEVER** skip the body on `feat` / `fix` / `refactor` / `perf` — template requires the WHY
- Group related changes into a single focused commit

## Auto-continue

- **Commit succeeded, branch ready for review** → auto-run pr-review-toolkit → push → invoke github-pr-creation (GATE is at PR create, user approves title/body/labels)
- **Commit succeeded, more work coming** → stay on branch, keep editing
- **Pre-commit blocked** → auto-diagnose the error and fix:
  - Secret detected → SOPS-encrypt, commit `.enc`, NEVER `--no-verify`
  - False positive → update `.gitleaks.toml` allowlist
  - Lint issue → fix the code, re-stage, NEW commit (never `--amend`)

## References

- `references/commit_examples.md` - Extended examples by type, good/bad comparisons
