# AGENTS.md

Single source of truth for **non-Claude CLI agents** working in this repo
(GitHub Copilot, Gemini CLI, OpenAI Codex). Claude Code itself is configured
separately via `CLAUDE.md` plus the plugin's own skills and hooks.

## Repo purpose

`claude-workflow-core` is dual-purpose:

- A **Claude Code plugin** — portable workflow skills + session-resilience
  hooks shared across consumer repos (media-server, pricing-team-toolkit).
- A **pre-commit hooks repo** (`pre-commit-hooks/`) those consumers install.

It is its own first consumer — it dogfoods every skill, hook, and gate it
ships. See `README.md` for the inventory and `CLAUDE.md` for the full
workflow contract.

## Reviewer contract

When invoked as a **code reviewer**, you are READ-ONLY:

- Do **not** modify files. Return findings only.
- Emit findings as a JSON array; each entry:
  `{file, line, severity, category, description, suggestion}`.
- Severity is one of `critical | high | medium | minor | info`.
- Review only the diff on the current branch (`git diff main...HEAD`), not
  pre-existing code.

The canonical read-only reviewer definitions live under `agents/`:

| Agent | Lens |
| --- | --- |
| `code-reviewer-readonly.md` | Correctness, project-guideline adherence |
| `code-simplifier-readonly.md` | Clarity, dead code, redundancy |
| `comment-analyzer-readonly.md` | Comment accuracy vs code |
| `pr-test-analyzer-readonly.md` | Test coverage + edge-case gaps |
| `security-review-readonly.md` | High-confidence vulnerabilities only |
| `silent-failure-hunter-readonly.md` | Swallowed errors / bad fallbacks |

## Per-CLI invocation context

| CLI | Config | Notes |
| --- | --- | --- |
| **GitHub Copilot** | `.github/copilot-instructions.md` | Delegates here; see the Phase 0.5 section below |
| **Gemini CLI** | `.gemini/policy.toml`, `.gemini/settings.json` | Free-tier review lane |
| **OpenAI Codex** | `.codex/config.toml` | ChatGPT-Plus auth; gpt-5.x review models |

All three default to their best free / already-paid tier — never a paid API
key unless the operator opts in explicitly.

### When invoked as Copilot (Phase 0.5)

Phase 0.5 is the cheap pre-screen that runs BEFORE the Claude Phase 1 review
agents. As Copilot you:

- Draft commit / PR / issue bodies on request (0x premium-multiplier models).
- Flag only obvious, high-signal issues — Phase 1 does the deep pass.
- Never push, merge, or open / close issues; the operator drives those
  through the plugin skills.

## Conventions

Reference the SSOT rather than restating it here:

- Commits: `.github/commit-template.yml`
- Labels: `.github/labels.yml`
- Required checks: `.github/required-checks-list.yml`
- PR body: `.github/pull_request_template.md`
- Review pipeline: `skills/ship-pr-cycle/SKILL.md`
