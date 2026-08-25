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

When invoked as a **code reviewer**, you are READ-ONLY — do **not** modify
files; return findings only.

The output contract is defined by the reviewer definitions under `agents/`
(each `*-readonly.md`) — they are canonical, so follow them exactly rather
than the summary here. Emit a JSON array of findings (empty `[]` if clean),
each of the shape:

```
{severity: high|medium|low, file: <path>, line: <number|null>, category: <string>, description: <1-2 sentences; fold any suggested change into this field>, confidence: 0-10}
```

`line` is the single source line for the finding, or `null` when it does not
map to one line (a missing file, or a structural / whole-file issue).

Review only the diff on the current branch (`git diff main...HEAD`), not
pre-existing code. The per-agent lenses:

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
| **OpenAI Codex** | `.codex/config.toml` | Scoped for a future Phase 0.7 — **not yet wired**; ChatGPT-Plus auth, gpt-5.x review models |

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

### The async Phase-1 panel hooks are REMOVED — do not reintroduce naively (#2564)

Four hook registrations (`phase1-log-pending-gate`,
`phase1-directive-pending-guard`, `phase1-post-agent-nudge`,
`phase1-launch-completeness-gate`) were deleted from operator settings on
2026-08-24. They assumed the `Agent` tool returned synchronously; the harness
runs agents asynchronously now, so the nudge fired at *launch*, the gate
demanded findings from agents that had not read a file yet, and the pair
stacked into a deadlock whose only exit pressured the operator into
fabricating review records — the exact dishonesty the gate exists to prevent.
The full post-mortem lives at the top of
`hooks/phase1-directive-pending-guard.sh` (pinned `auto-register: false` so
`register-hook.sh --all-auto-register` cannot silently reinstate it). If a
panel is ever rebuilt: key pending-state on agent **completion**, never let a
guard block the command that clears it, and keep `Read` available to
subagents.

### `# audits:` header for repo-wide meta-lint suites (#2572, convention only)

A bats file that POLICY-AUDITS many files (a repo-wide meta-lint) must not
claim `# covers:` on them — that hands out false behavioral-test credit in
`test-touched` and the mirror-drift gate. Declare `# audits: <paths…>`
instead. Consumers (test.sh coverage, test-touched, refresh-from-source)
treat `audits:` as routing-only — the suite still runs when its subjects
change, but earns no behavioral credit. Enforcement + the
`posttooluse-enforcement-contract.bats` migration are tracked under epic
#2581; until that lands this section is the convention's SSOT.
