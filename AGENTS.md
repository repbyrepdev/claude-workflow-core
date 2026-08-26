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

### `# audits:` header for repo-wide meta-lint suites (#2572 — LIVE)

A bats file that POLICY-AUDITS many files (a repo-wide meta-lint) must not
claim `# covers:` on them — that hands out false behavioral-test credit in
`test-touched` and the mirror-drift gate. Declare `# audits: <paths…>`
instead. Both headers are per-file, read with `grep -m1`, space-separated.

```bash
# covers: _lib/event-frontmatter.sh    ← what this file EXECUTES
# audits: hooks/*.sh                   ← what it SWEEPS but never runs
```

The two headers answer different questions, and the three consumers read
them differently:

| consumer | `covers:` | `audits:` |
|---|---|---|
| `test-touched.sh` (routing) | re-run | **re-run** |
| `test.sh --coverage` (credit) | counts | ignored |
| `refresh-from-source.sh` drift gate (credit) | accepts as the verifying test | ignored |

Routing on both is the point: an audit must re-run when something it
polices changes. Crediting only `covers:` is equally the point: an audit
that swept 40 mirror hooks without executing one of them would otherwise
tell the drift gate they were all verified.

`audits:` entries may be globs (`hooks/*.sh`); `covers:` entries are exact
paths. A file may carry both, one, or neither — a suite with only `audits:`
routes correctly and simply contributes no coverage, which is accurate.

First user: `.claude/tests/_lib/event-frontmatter-audit.bats`.

### Assertions must fail on every bash (#2631)

bats reports a failed test through an `ERR` trap. On **bash 3.2** — the 2007
build macOS ships at `/bin/bash`, frozen because bash 4.0 relicensed to
GPLv3 — a failing bare `[[ ]]` fires neither that trap nor `set -e`, so the
test PASSES anyway:

```bash
/bin/bash -c 'set -eET; trap "echo TRAP" ERR; [[ a == b ]]; echo REACHED'
# → REACHED          (bash 5 prints TRAP and stops)
```

A bare `[[ ]]` therefore only fails a test when it happens to be the block's
**last command**. An assertion whose enforcement depends on its position is
not an assertion — 749 such no-ops existed across 96 files when this was
found, and 8 of them were hiding something false.

Write assertions in a form that fails everywhere:

```bash
[ "$status" -eq 0 ]                       # single-bracket builtin
[[ $output == *x* ]] || return 1          # the `||` supplies the failure
case "$output" in *x*) ;; *) return 1 ;; esac
assert_output_contains "x"                # helper returning non-zero
```

Enforced mechanically, in layers:

1. **`pre-commit-hooks/bats-assertion-gate.sh`** refuses any *increase* in
   non-portable assertions, per file, against
   `.claude/bats-assertion-baseline.tsv`.
2. **The baseline is 0 and a test pins it there**, so the refresh script
   cannot be used to launder new debt into the baseline.
3. **`scripts/test.sh --shell <bash>`** runs the suite under a chosen shell.
   The acceptance test for portability is the same verdict on the oldest and
   newest supported bash:

   ```bash
   TEST_SH_FULL_OK=1 scripts/test.sh --shell /bin/bash              # 3.2
   TEST_SH_FULL_OK=1 scripts/test.sh --shell "$(brew --prefix)/bin/bash"
   ```

   Green on 3.2 implies green on 4, 5, Linux and GitHub runners — 3.2 is the
   weakest link, which is why it is the one worth checking.
