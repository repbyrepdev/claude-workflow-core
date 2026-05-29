---
name: ship-pr-cycle
description: Drive the local PR review pipeline (Phase 0.5 → Phase 1 → Phase 2 → push → CR-in-CI → merge-gate) as a state machine. Use when user says "ship", "advance the cycle", "ship this PR", "what's next on the pipeline", or after `git commit` to auto-progress. Maintains per-HEAD state at .claude/.session-state/ship-cycle/<sha>.json.
---

# ship-pr-cycle

Mechanical driver for the staged local PR review pipeline. Operator interaction goal: ONE gate (approve-to-ship at merge time). Everything else autonomous.

Consumer repos that need domain-specific overlays (e.g. deferring a stage until a dependency lands; adding a post-merge deploy step) declare them in `.claude/skills/ship-pr-cycle/domain-extension.md` next to their `local-overrides.yml`. The plugin's SKILL.md is the SSOT for everything not consumer-specific.

## Quick start

```bash
# Initialize state for current HEAD
.claude/skills/ship-pr-cycle/run.sh start

# Check current stage
.claude/skills/ship-pr-cycle/run.sh status

# Advance one stage (idempotent, gate-checked)
.claude/skills/ship-pr-cycle/run.sh next

# Auto-detect + advance once (post-commit cascade entry-point)
.claude/skills/ship-pr-cycle/run.sh resume
```

## State machine

```text
[branch-ready]    fresh branch, ≥1 commit ahead of base
    ↓ next
[phase0.5]        copilot prefilter logged for HEAD
    ↓ next (gate-checked: phase0.5-run.jsonl entry exists for sha)
[phase1]          claude review-log convergence (cap = scaler tier)
    ↓ next (gate-checked: 2-streak clean rounds with all expected agents)
[phase2]          local CR-CLI invocation
    ↓ next (gate-checked: 0 findings; >0 emits operator directive)
[push]            git push -u origin <branch>
    ↓ next
[cr-in-ci-wait]   gh pr list + watch-until-done.sh
    ↓ next (gate-checked: CR-in-CI terminal state)
[auto-triage]     (pending #733) classify findings — currently a passthrough; future classifier wires here
    ↓ next
[merge-gate]      OPERATOR APPROVES HERE
    ↓ next (after explicit user "go")
[merged]          terminal
```

## Env

- `BASE_BRANCH` — comparison branch for "commits on branch" check (default: `main`)
- `SHIP_CYCLE_POST_COMMIT_SKIP=1` — disables the post-commit auto-fire (operator toggle)

## Phase 1 firing — operator-driven

When state advances to `phase1` and clean-streak < 2, `next` prints a DIRECTIVE FOR OPERATOR block. Phase 1's `security-review` MUST be fired in a separate Claude turn from the 5 parallel Agent calls — the pending-file gate kills the Skill when bundled. The directive layout:

1. Block A: 5 parallel Agent calls (code-reviewer, code-simplifier, comment-analyzer, pr-test-analyzer, silent-failure-hunter)
2. Barrier: log all 5 via `.claude/hooks/review-log.sh phase1 <round> <agent> <findings-count> ok`
3. Run semgrep against the PR diff and log: invoke the `semgrep:semgrep_scan` MCP tool against the changed files (auto-config), then log via `.claude/hooks/review-log.sh phase1 <round> semgrep <findings-count> ok`. (The MCP tool is the canonical entry — direct CLI invocation works too but bypasses the MCP-side rate budgeting.)
4. Fire `Skill(security-review)` SEPARATELY (NOT in same parallel block — pending-file gate kills the Skill)
5. Log security-review: `.claude/hooks/review-log.sh phase1 <round> security-review <findings-count> ok`
6. Re-run `next` — orchestrator detects 2-streak clean and advances to phase2

**Why operator-driven:** bash can't fire Claude agents. A future enhancement (#732) would wire a UserPromptSubmit hook that emits the directive into Claude's context after a post-commit cascade; until then, the operator runs the agent calls.

## Auto-fire after commit

**Prerequisite:** the post-commit dispatcher must exist at `.claude/hooks/post-commit-ship-cycle.sh` in the consuming repo. The canonical implementation lives in the plugin at `hooks/post-commit-ship-cycle.sh`; consumer repos either:

- Install a shim via `scripts/bootstrap-repo.sh` (current shim coverage is partial — Sub 13 #151 expands the bootstrap to install this dispatcher).
- Or symlink / copy the plugin's `hooks/post-commit-ship-cycle.sh` to `.claude/hooks/post-commit-ship-cycle.sh` manually.

Once that's in place, wire the git post-commit hook one-time per clone:

```bash
# If .git/hooks/post-commit is new, write the file with shebang first.
# (When appending to an existing hook, skip this — `cat >>` keeps the
# existing shebang.)
[ -e .git/hooks/post-commit ] || printf '#!/bin/bash\n' > .git/hooks/post-commit
cat >> .git/hooks/post-commit <<'EOF'
REPO_ROOT=$(git rev-parse --show-toplevel)
[ -x "$REPO_ROOT/.claude/hooks/post-commit-ship-cycle.sh" ] && \
  "$REPO_ROOT/.claude/hooks/post-commit-ship-cycle.sh" || true
EOF
chmod +x .git/hooks/post-commit
```

The `[ -x ... ] && ... || true` guard intentionally no-ops when the dispatcher is absent — so the git post-commit hook is safe to install even before the dispatcher shim lands. Once the shim is in place, every `git commit` fires `ship-pr-cycle.sh resume` detached. Logs to `.claude/logs/ship-cycle-resume.jsonl` + `.claude/logs/ship-cycle-resume-<sha-prefix-8>.log` (SHA truncated to 8 chars via `head -c 8` in post-commit-ship-cycle.sh — chosen for log-filename brevity, not the `--short` default of 7).

## Convergence cap

`phase1-scaler.sh --explain` resolves the per-tier `ROUNDS=N` cap. Honored as ceiling on Phase 1 + Phase 2 iteration. Scaler error → falls back to 2 rounds with `scm_warn`.

## Out of scope (separate sub-issues)

- Phase 1 actual agent firing from bash (#732 — Claude-side directive hand-off)
- Auto-triage classifier for CR-in-CI findings (#733)
- Cross-PR orchestration (one PR at a time)

## Rules

- **NEVER** bypass the convergence gate without auditing — `PIPELINE_GATE_SKIP=1` bypasses the gate (audit-logged); set `PIPELINE_GATE_SKIP_REASON=...` to record the rationale in the bypass log.
- **ALWAYS** run `phase1-scaler.sh --explain` at start of a long PR cycle; iterate to ROUNDS=N target. Burning 17 rounds when the scaler said 2 is the explicit anti-pattern this orchestrator addresses.
- **NEVER** advance phase2 → push when CR-CLI returned a malformed `complete` event. The orchestrator now hard-fails this case (return 2) — do not work around.

## Related skills

- `cr-plan` (plan-me trigger) — issue planning before this skill starts at branch-ready.
- `git-commit` — standardized commit message format; this skill resumes from post-commit hooks.
- `github-pr-creation` — invoked at the `push` → PR-open transition.
- `github-pr-merge` — invoked at the `merge-gate` → merged transition after operator approval.
- `coderabbit:autofix` — invoked from `cr-in-ci-wait` when CR posts findings.

## Auto-continue

- **`next` advanced a stage** → re-run `next` to continue; the state machine drives branch-ready → phase0.5 → phase1 → phase2 → push → cr-in-ci-wait → auto-triage → (cr-autofix) → merge-gate.
- **phase1 directive emitted** → fire the 5 parallel review agents + semgrep + security-review, log each via `review-log.sh`, then re-run `next`.
- **phase2 / CR findings** → apply or reject-with-prove-yourself in-PR, commit, let post-commit resume re-fire; do not advance with open findings.
- **merge-gate reached** → operator approval point; on approval, invoke `github-pr-merge`. This is the one human gate.
- **`resume`** → auto-advances until it hits phase1 (needs agents), merge-gate (needs operator), or a terminal state.
