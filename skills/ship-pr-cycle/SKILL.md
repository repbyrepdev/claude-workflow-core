---
name: ship-pr-cycle
description: Drive the local PR review pipeline (Phase 0.5 → Phase 1 → Phase 2 → push → CR-in-CI → merge-gate) as a state machine. Use when user says "ship", "advance the cycle", "ship this PR", "what's next on the pipeline", or after `git commit` to auto-progress. Maintains per-HEAD state at .claude/.session-state/ship-cycle/<sha>.json.
---

# ship-pr-cycle

Mechanical driver for the staged local PR review pipeline. Operator interaction goal: AT MOST ONE gate (approve-to-ship at merge time) — and none at all when `MERGE_GATE_AUTO=1` and the PR is provably green (#2549). Everything else autonomous.

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
    ↓ next (gate-checked: EXIT CONTRACT #2570 — see below)
[phase2]          local CR-CLI invocation
    ↓ next (gate-checked: 0 findings; >0 emits operator directive)
[push]            git push -u origin <branch>
    ↓ next
[cr-in-ci-wait]   gh pr list + watch-until-done.sh
    ↓ next (gate-checked: CR-in-CI terminal state)
[auto-triage]     classify CR threads via scripts/cr/auto-triage.sh (#733); routes by unresolved count
    ↓ next
[cr-thread-reply]  reply-with-evidence to verified-fixed / false-positive / rejected threads (#2548);
                   only UNADDRESSED threads block — `replied-awaiting-CR` passes through
    ↓ next (gate-checked: unaddressed == 0)
[cr-conflict-check] route a DIRTY PR through CR's resolver (#190); CLEAN passes straight through
    ↓ next
[merge-gate]      OPERATOR APPROVES HERE — unless MERGE_GATE_AUTO=1 and the PR is
                  provably green (#2549), in which case native auto-merge is armed
    ↓ next (after explicit user "go", or automatically when armed)
[merged]          terminal
```

## Env

- `BASE_BRANCH` — comparison branch for "commits on branch" check (default: `main`)
- `SHIP_CYCLE_POST_COMMIT_SKIP=1` — disables the post-commit auto-fire (operator toggle)

## Phase 1 firing — operator-driven

When state advances to `phase1`, neither exit-contract door is open, AND the branch round count is under the cap (or the audited override is set), `next` prints a DIRECTIVE FOR OPERATOR block; at the cap it refuses instead (rc 2, no directive). Phase 1's `security-review` MUST be fired in a separate Claude turn from the 5 parallel Agent calls — the pending-file gate kills the Skill when bundled. The directive layout:

1. Block A: 5 parallel Agent calls (code-reviewer, code-simplifier, comment-analyzer, pr-test-analyzer, silent-failure-hunter)
2. Barrier: log all 5 via `.claude/hooks/review-log.sh phase1 <round> <agent> <findings-count> ok`
3. Run semgrep against the PR diff and log: invoke the `semgrep:semgrep_scan` MCP tool against the changed files (auto-config), then log via `.claude/hooks/review-log.sh phase1 <round> semgrep <findings-count> ok`. (The MCP tool is the canonical entry — direct CLI invocation works too but bypasses the MCP-side rate budgeting.)
4. Fire `Skill(security-review)` SEPARATELY (NOT in same parallel block — pending-file gate kills the Skill)
5. Log security-review: `.claude/hooks/review-log.sh phase1 <round> security-review <findings-count> ok`
6. Re-run `next` — the orchestrator advances to phase2 through one of the
   exit-contract doors below

**Why operator-driven:** bash can't fire Claude agents. A future enhancement (#732) would wire a UserPromptSubmit hook that emits the directive into Claude's context after a post-commit cascade; until then, the operator runs the agent calls.

## Phase 1 EXIT CONTRACT (#2570, enforced by #2575)

Phase 1 ends through exactly TWO doors — this section is the SSOT (the
old "2-clean-streak" wording described only door 1 with a hardcoded 2;
the cap comes from the scaler tier, and door 2 is how real branches
with findings converge without treadmilling):

1. **Clean convergence:** `clean_streak >= cap` — consecutive TRAILING
   rounds with zero findings and all expected agents logged, read from
   the CURRENT HEAD's review log only (clean rounds on earlier fix-
   commit shas count toward the cap, never toward the streak).
2. **Covered at cap:** the branch has spent `>= cap` rounds AND EVERY
   findings-bearing branch sha has its findings covered by
   prove-yourself records (cumulative covers >= cumulative findings,
   PER SHA — a fresh 0-finding commit cannot wash out older uncovered
   findings), with at least ONE findings-bearing sha as positive
   evidence (all-zero rounds at the cap mean errored/partial panels,
   not cleanliness). `next` then GRADUATES to phase2 without arming
   another round. The refusal clears the directive marker, so Edit/
   Write stay available for the record-fix/record-rejection remedies.

Anything else at the cap is a REFUSAL (`_phase1_cap_gate`, rc 2,
hook-ack routed): cover the findings, then re-run `next`. A deliberate
extra round past the cap requires the audited escape —
`PIPELINE_GATE_SKIP=1 PIPELINE_GATE_SKIP_REASON="why"` — which refuses
to proceed unless the audit row is durably written (same posture as the
phase-2 cap, #2545). Branch-level graduation (`phase-graduation.sh`)
still short-circuits phase 1 entirely once the branch converged on any
earlier sha (#63/#792).

## Phase 1 SendMessage resume — agent-team peer review (#193)

Requires `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (the env that exposes the `SendMessage` tool). **Flag off → none of this fires; the launcher prints the normal fresh-Agent lines, byte-identical to pre-#193.** Mechanics live in the `phase1-*` hook family — `phase1-agent-id.sh` (agentId registry + read-only `directive` decision + `resumed` commit), `phase1-resume-message.sh` (peer-review message body), `phase1-agent-ids-session-clear.sh` (SessionStart staleness wipe).

On round N>1 the launcher's agent line becomes `[RESUME] SendMessage to=<agentId> …` instead of a fresh `Agent`. The point: the resumed teammate keeps its prior file reads in context, so it re-reviews only the delta — and it argues back instead of one-way emitting. The main-loop protocol per round:

1. **Fresh spawn (round 1, or any fall-through):** after the `Agent` returns, capture `agentId` from its result JSON and record it:
   `.claude/hooks/phase1-agent-id.sh record <agent> <agentId> $SHA`
2. **Resume (round N>1, `[RESUME]` line shown):** send the launcher-emitted message body VERBATIM as the `SendMessage` `message` (it already contains the delta scope + dismissed-findings-with-dogfood-evidence + the response contract). The teammate replies with a single JSON object:
   - `new_findings` — issues in the delta only. `review-log` findings-count = `len(new_findings)`; triage each (apply-fix or prove-yourself reject) exactly as a fresh finding.
   - `refutations` — dismissed findings it still believes, each with `counter_evidence` (a concrete repro the rejection's dogfood missed). For EACH: **re-dogfood against the counter-evidence.** If it reproduces → the finding is real: reopen it (fix in-PR + `prove-yourself-audit record-fix`). If the original rejection still holds → `prove-yourself-audit record-rejection` again with the counter-evidence addressed in `decision_data` (so the audit trail shows the dispute was weighed, not ignored). Either way, surface the refutation to the operator — never silently absorb it.
   - `accepted_rejections` — dismissed findings whose evidence the teammate now accepts (the resume message asks it to list these so they're "retired from future rounds"). No operator action: they're already covered by the existing rejection record; the teammate is just confirming it won't re-raise them.
   Then commit the resume event: `.claude/hooks/phase1-agent-id.sh resumed <agent> $SHA`
3. **Resume failure** (SendMessage errors — teammate reaped / not resumable): fall back to a fresh `Agent`, then `.claude/hooks/phase1-agent-id.sh clear <agent>` so the next round records a new agentId.

**Cap:** `PHASE1_RESUME_CAP` (default 3) consecutive resumes per agent, then the launcher forces a fresh spawn (bounds subagent context growth). **Staleness:** the SessionStart hook wipes the agentId registry every session — in-process teammates don't survive a restart, so a resume never targets a dead teammate from a prior session. **Round is clean** iff every agent's `new_findings` is empty (refutations/accepted_rejections don't change convergence — they route through prove-yourself, not review-log). Schema is prompt-format JSON (same as fresh Phase 1 agents — no StructuredOutput regression).

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

### Two failure modes that look identical (#2549)

A merge that does not happen has two very different causes, and they are worth
telling apart before debugging:

1. **A repo/cycle gate refused** — `merge-gate` held, the CR gate denied, the
   branch ruleset blocked. The remedy is in this repo: address the signal it
   named.
2. **The harness permission layer refused** — the Claude Code auto-mode
   classifier declined the invocation shape (e.g. `APPROVE=1 <script>`, or a
   repo-settings `PATCH`). Nothing in this plugin can fix that; it needs a
   Bash permission rule in the operator's settings.

From the cycle's point of view both look like "merge did not happen". Native
auto-merge also requires `allow_auto_merge` on the repository — if it is off,
`--auto` fails with `enablePullRequestAutoMerge` and the gate holds.


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

- **`next` advanced a stage** → re-run `next` to continue; the state machine drives branch-ready → phase0.5 → phase1 → phase2 → push → cr-in-ci-wait → auto-triage → (cr-autofix) → cr-thread-reply → cr-conflict-check → merge-gate.
- **phase1 directive emitted** → fire the 5 parallel review agents + semgrep + security-review, log each via `review-log.sh`, then re-run `next`.
- **phase2 / CR findings** → apply or reject-with-prove-yourself in-PR, commit, let post-commit resume re-fire; do not advance with open findings.
- **cr-thread-reply reached** → classify each UNADDRESSED thread and reply with evidence via `scripts/cr/thread-reply.sh`. Never resolve a thread by hand — the reply is the action, CR resolving is the outcome. `verified-fixed` is gated on `git show HEAD:<path>`; `actionable` is not repliable and goes back to autofix.
- **merge-gate reached** → operator approval point by default. Auto-merge is **OPT-IN**: with `MERGE_GATE_AUTO=1`, and only if the PR is provably green (every required check green AND `hooks/_pr-cr-findings.sh` clean across all four of its sources AND `mergeStateStatus == CLEAN`), the stage arms GitHub native auto-merge and returns. Otherwise it holds for operator approval. A `needs-operator` label forces the human gate regardless, and drafts are never auto-merged. Fails closed: a signal that cannot be READ holds the gate, and a check that passed WITHOUT running (CR "rate limited" / "review paused", or a SKIPPED required check) is not green. It ships opt-in because the first review of that predicate found four independent ways it returned "green" on a PR that should have held — see `_lib/merge-auto-ok.sh`.
- **`resume`** → auto-advances until it hits phase1 (needs agents), merge-gate (needs operator), or a terminal state.
