---
name: github-pr-creation
description: Creates GitHub Pull Requests with automated validation and task tracking. Use when user wants to create PR, open pull request, submit for review, or check if ready for PR. Analyzes commits, validates task completion, generates Conventional Commits title and description, suggests labels. NOTE - for merging existing PRs, use github-pr-merge instead.
---

# GitHub PR creation

Creates Pull Requests with task validation, test execution, and Conventional Commits formatting.

## Preferred entry point (v4.20 #519): `run.sh` wrapper

Invoke `.claude/skills/github-pr-creation/run.sh` for the full flow
(body-template + auto-milestone + area-label passthrough + `gh pr create`)
in one call. Sets `SKILL_WRAPPER=1` so skill-bypass-guard allows the call.

```bash
# v4.28-W3-CD #745: Copilot-default — body-file is optional now.
.claude/skills/github-pr-creation/run.sh \
  --title "…" \
  [--body-file /tmp/pr-body.md] \
  [--label …] [--milestone vX.Y] [--base main] [--draft] \
  [--no-copilot]
```

### Copilot-default body (v4.28-W3-CD #745)

When `--body-file` is omitted, the wrapper auto-drafts the PR body via
Copilot free-tier (gpt-4.1 / gpt-5-mini / gpt-4o, 0× premium multiplier
on Enterprise seats). Mirrors the pattern from `git-commit` (#743).

```bash
# Default — wrapper auto-drafts body from branch diff:
.claude/skills/github-pr-creation/run.sh --title "feat(scope): subject"

# Explicit body overrides the draft:
.claude/skills/github-pr-creation/run.sh --title "…" --body-file body.md

# Opt-out per-invocation (must supply --body-file):
.claude/skills/github-pr-creation/run.sh --title "…" --no-copilot --body-file body.md

# Opt-out via env (useful for trusted-edit flows):
COPILOT_DRAFT_OFF=1 .claude/skills/github-pr-creation/run.sh --title "…" --body-file body.md
```

**Behavior:**
- Default (no `--body-file` + Copilot helper present): wrapper drafts body, runs `pr-lint-check.sh` preflight, then asks for create approval
- Explicit `--body-file`: precedence over draft, no Copilot call
- `--no-copilot` or `COPILOT_DRAFT_OFF=1` + no body-file: refuses with rc=2
- Copilot helper missing or returns empty: refuses with rc=3 (distinct from rc=2)
- Copilot draft fails pr-lint preflight: refuses with rc=4 (operator-supplied bodies stay rc=2 — same UX as before)

The pre-create lint runs BEFORE the approval prompt so a broken body
refuses upfront without bothering the operator.

The inline flow below is the **pre-v4.20 manual path**, preserved as a
fallback when the wrapper doesn't fit the use case. Prefer the wrapper.

## Current state

!`git rev-parse --abbrev-ref HEAD 2>/dev/null`
!`git log @{u}..HEAD --oneline 2>/dev/null || echo "(no upstream tracking)"`

## Core workflow

### Pipeline awareness

When you push and create a PR, this automated pipeline fires:
1. **Pre-commit framework** (local, before commit): yamllint, shellcheck, shfmt, gitleaks, actionlint, hadolint — configured in `.pre-commit-config.yaml`
2. **Claude Code hooks** (local, after edits): auto-lint yaml/shell/actions — configured in `.claude/settings.json`
3. **GitHub Actions** (server, on PR push):
   - `validate` — compose/YAML/script syntax check (REQUIRED for merge)
   - `gitleaks` — secret scan with `.gitleaks.toml` allowlist (REQUIRED)
   - `pr-lint` — single job (v4.3.E consolidation) with 3 sequential steps: area label present · `Closes #N` body ref · all 6 template section headings present (Summary/Changes/Testing/Encryption/Pre-merge/Rollback). REQUIRED.
   - `scan-images` — container CVE scan (from trivy workflow, only on compose changes, advisory only)
   - `project-automation` — board transitions (assign→In Progress, PR→Review)
   - `auto-close-parent` — closes parent when all sub-issues done
4. **CodeRabbit** (server, on PR push): AI review with assertive profile, shellcheck, yamllint, actionlint, hadolint, gitleaks, checkov. Skips markdown/templates. v4.1: REQUIRED status check.
5. **Branch protection** (v4.3.E, was v4.1): 4 required checks must all pass — `validate`, `gitleaks`, `pr-lint`, `CodeRabbit`. Any failure blocks merge. (Was 6 before v4.3.E consolidated the 3 pr-lint jobs into 1.)

The PR creation skill must ensure the PR will pass all of these before pushing.

### 0. Pre-push review pipeline — MANDATORY, two phases

v4.1 made CodeRabbit a required merge gate, so CR finding anything in CI means the local pipeline missed it. Layer 0 is automatic (hooks + `security-guidance`, fires during editing — no manual action). The two manual phases below run before push.

**Phase 1 — N-agent iteration loop** (v4.15 #488 gold-standard, mechanically enforced by `.claude/hooks/phase1-before-cr.sh` + `pre-push-pipeline-gate.sh`). Launch ALL expected agents IN PARALLEL every round (one Agent-tool message). The agent list is SSOT-derived from `.claude/review-config.yml` via `.claude/hooks/list-phase1-agents.sh` — helper `.claude/hooks/phase1-launcher.sh` prints the exact checklist per round. Currently 7 for shell/YAML repos; increases if typed code lands (type-design-analyzer re-enters).

**The Phase 1 agent set (current — SSOT is `list-phase1-agents.sh`):**

1. `pr-review-toolkit:code-reviewer` — architecture, coupling, CLAUDE.md compliance
2. `pr-review-toolkit:silent-failure-hunter` — `|| true`, `2>/dev/null`, ignored exit codes, `set +e`
3. `pr-review-toolkit:comment-analyzer` — comment rot, lies, stale refs, behavior mis-claims
4. `pr-review-toolkit:pr-test-analyzer` — test coverage gaps
5. `pr-review-toolkit:code-simplifier` — polish, preserve functionality
6. `/security-review` skill — security-focused pass (vulns, injection paths, auth bypass)
7. `semgrep` — `mcp__plugin_semgrep_semgrep__semgrep_scan` (MCP) OR `semgrep scan --config=auto --error` (CLI)

`pr-review-toolkit:type-design-analyzer` is NOT in the list — auto-skipped by `review-config.yml` on shell/YAML-only repos. `/code-review` is NOT a Phase 1 agent — it's a different skill requiring a live PR URL, used in limited scenarios outside the Phase 1 loop.

**Iteration rules (v4.15):**

- **Every round**, launch ALL expected agents (from `list-phase1-agents.sh`) in ONE parallel Agent-tool message. Not "whichever ones seem relevant" — always all of them.
- **Review scope per round = `git diff main..HEAD`** (the WHOLE cumulative diff). After a fix, increment round and re-launch all 7 on the whole diff — NEVER "just re-review the file I fixed".
- **Log each agent** via `.claude/hooks/review-log.sh phase1 <round> <agent> <findings> ok`. The log script rejects unknown agent names (v4.15.B).
- **Minimum 5 rounds** (`PHASE1_MIN_ROUNDS=5` default). Go higher if findings keep surfacing.
- **Convergence = 2 consecutive clean rounds** (`PHASE1_MIN_CLEAN_STREAK=2` default). A clean round = every agent returns `findings=0 status=ok`. One clean round is not enough; catches flaky/drift-triggered findings.
- **The `phase1-before-cr.sh` PreToolUse hook MECHANICALLY BLOCKS Phase 2 CR invocation** until the log shows ≥5 rounds + last 2 all-clean + every expected agent present per round. Override only via `PHASE1_GATE_SKIP=1` for emergencies (logged to stderr).
- **Accept-with-reason** only after minimum rounds hit AND ≥2 agents contradict at the same round. Log via `.claude/hooks/review-log.sh accept-with-reason "<reason>"` + `Review-accept-reason:` commit trailer. Never used to dismiss a single agent's persistent finding.
- **DO NOT STALL AFTER THE LAST AGENT RETURNS.** The failure mode caught 2026-04-20: Claude launches all 7 agents, receives all 7 responses (especially /security-review which has long output), and stops, waiting for user input instead of continuing. Hard rule: **the moment the last of the 7 agents returns for round N, the very next action is either (a) apply fixes + commit + launch Round N+1 if findings>0, or (b) check the streak and launch Round N+1 if streak<2, or (c) proceed to Phase 2 CR if converged.** Never hand control back to the user between "all 7 returned" and "round N+1 launched or Phase 2 invoked". `review-log.sh` emits a "Round N COMPLETE" stderr nudge (v4.15.F) with the exact next step after the last agent's log-write — follow it. No acknowledgement of the findings, no status summary, no pause — fix → commit → next round, in that order.
- **DO NOT STALL AFTER AGENT RETURN OR AFTER WORKFLOW-INFRA COMMIT.** Two further stall points caught 2026-04-20 (v4.15.G/H #495 #496): (1) agent returns → I don't call review-log.sh → v4.15.F's trigger never fires; (2) I commit a workflow-infra fix → no hook fires because Bash commits aren't Agent returns. Both closed by PostToolUse hooks using JSON `hookSpecificOutput.additionalContext` output (v4.15.M #497 — exit 2 + stderr does NOT inject to Claude, must use JSON stdout). When either directive appears as system context, it IS the next action — no "should I" questions, just execute.
- **NO WORKAROUNDS WHEN MECHANISMS BREAK.** If during dogfood a hook/gate/directive isn't working, file a sub-issue under the active epic and FIX IT in this PR — do not "fall back to discipline" or work around. Paper-tiger mechanisms are worse than no mechanism. Live-test every fix by triggering the hook and verifying the side-effect actually surfaces (exit code + stderr capture ≠ context injection). The mechanism IS the enforcement.

**Batch-PR discipline (v4.3.C, from v4.2 empirical lesson):** when working multiple sub-issues on one branch (the CR-budget-optimal pattern), **re-read the FULL current diff vs base** before each sub-issue commit — not just the delta of the sub-issue you just worked on. `git diff main` from HEAD, top-to-bottom. Fragmented mental model across sub-issues is the root cause of CR's "outside diff range" findings: new code in sub-issue D contradicts new code from sub-issue A that already landed on the same branch, and CR catches the contradiction. Re-reading the full diff at each commit keeps the batch internally coherent.

### Layer 0 scope (v4.2.B / v4.3.C)

Runs automatically during editing — no manual action — via the `security-guidance` plugin wrapped by `.claude/hooks/security-reminder.sh`. PreToolUse on `Edit|Write|MultiEdit`. Exit 2 blocks the edit. Current ruleNames (upstream plugin): `github_actions_workflow`, `child_process_exec`, `new_function_injection`, `eval_injection`, `react_dangerously_set_html`, `document_write_xss`, `innerHTML_xss`, `pickle_deserialization`, `os_system_injection`. See CLAUDE.md Rule 5 for the full prose description.

### Fail-closed handling (v4.2.C + v4.3.C flowchart)

The silent-failure pattern this pipeline exists to catch applies to the pipeline itself. Per-agent status classification:

- **`ok`** — agent returned a parseable response. `findings=N` is the real count.
- **`errored`** — agent crashed, timed out, or returned empty/unparseable output. `findings` is meaningless.

```
┌────────────────────────────────────────────────────────────┐
│ End of round: how many of the 6 agents had status=errored? │
└────────────────────────────────────────────────────────────┘
         │
         ├─ 0 errored
         │   ├─ all 6 findings=0 → CLEAN ROUND ✓ (proceed to Phase 2)
         │   └─ any findings>0   → fix, re-run round
         │
         ├─ 1 errored (same tool flaky-but-transient)
         │   ├─ Retry just the errored agent manually.
         │   │   ├─ 2nd run succeeds → count as clean (flaky tool)
         │   │   └─ 2nd run also fails → surface to user:
         │   │       "Tool X errored twice. Known issue / rate-limit /
         │   │        broken? Reply 'ok skip' with reason to proceed."
         │   │       User explicit text (not y/n) logs the decision.
         │   └─ Phase 1 NOT complete until resolved.
         │
         ├─ 2+ errored (infrastructure problem)
         │   └─ Phase 1 did NOT converge. Retry all 6 BEFORE the round
         │      count advances (so the 3-round cap doesn't eat rounds
         │      where the pipeline itself was broken).
         │
         └─ Same agent errored 2 rounds in a row
             └─ Investigate: stale subagent config, plugin broken, disk
                full, rate-limited? Don't accept the round; fix the
                tool first.
```

**A "clean round" requires BOTH** all expected agents (per `list-phase1-agents.sh`) returning successfully
AND each returning 0 actionable findings. Either condition unmet = not
a clean round. The gate is strict; don't soften. v4.15 adds a second
layer: 2 consecutive clean rounds needed for convergence, not just 1.

Log each agent invocation via `.claude/hooks/review-log.sh phase1 <round> <agent> <findings> <status>` — v4.3.F's pre-push gate reads this to verify the local pipeline converged before allowing push.

**Phase 2 — CodeRabbit CLI, iterated until clean** (shares the prepaid CR rate bucket with CI-CR — iterate until 0 findings):

```bash
# Pre-check: is the CR budget clear?
.claude/hooks/cr-budget-check.sh  # exits 1 if 5/5 used in last hour — defer until slot frees

/coderabbit:review all
# OR
coderabbit review --plain --base main

# Log the invocation against the shared 5/hour bucket
.claude/hooks/cr-log-invocation.sh cli "" "$(git rev-parse HEAD)" <findings_count>
```

Rules (v4.15):

- Gated by `phase1-before-cr.sh` — CR CLI won't fire until Phase 1 convergent (≥5 rounds, last 2 all-clean, all 7 agents per round).
- **Check `cr-budget-check.sh` first** — both local CLI and remote CI count against the same 5/hour bucket. If at 5, defer; at 4, warn + proceed.
- **Iterate until 0 findings.** Each CR finding → fix → re-run the specific Phase 1 agent that SHOULD have caught it (calibration) → re-run CR CLI. Keep iterating until CR reports 0. One CR round is NOT enough if findings are non-zero.
- Rate-budget caveat: if iterating CR trips the 5/hr cap, wait for the bucket to reset (~60 min) rather than pushing incomplete work. Phase 3 CR-in-CI will fire on PR-open, which is the final safety net.

**Finding classification (v4.3.G)** — when Phase 2 CR or CR-in-CI returns findings, classify each:

- **Mechanical finding** — CR's suggestion block is a concrete diff patch: rename, typo fix, syntax correction, missing field, null-safety guard, etc. **Apply via `/coderabbit:autofix`** — CR's suggestion applied verbatim eliminates transcription errors. Autofix commit messages carry `autofix:` prefix so git log shows machine-applied changes. Always re-read the resulting diff before committing; CR's suggestion can be subtly wrong.
- **Judgment finding** — contract mismatch, architectural concern, behavior question, doc-drift reasoning. **Fix manually** + explain reasoning in the commit body. Autofix would apply a literal suggestion that might not be the right call.

After any CR round (CLI or CI), log it via `.claude/hooks/cr-log-invocation.sh` so budget tracking stays accurate:
```bash
# After Phase 2 CLI
.claude/hooks/cr-log-invocation.sh cli "" "$(git rev-parse HEAD)" <findings>
# After observing a CR-in-CI check complete on a PR
.claude/hooks/cr-log-invocation.sh ci <pr_number> <head_sha> <findings>
```

**Gate**: Phase 1 converged (a clean round) AND Phase 2 returned 0 actionable items (or everything Phase 2 found is fixed + calibration re-run done). Only then push.

**Post-push**: CR-in-CI is the required status check. With Phases 1+2 done right, it should find nothing. Any finding = Phase 1 coverage regression; fix + tighten the specific Phase 1 agent's scope in a follow-up commit.

```bash
# Verify .enc files are up to date for any configs touched
git status  # no plaintext secrets staged
```

### 1. Confirm target branch

**Target is always `main` in this repo.** No develop branch.

```
Creating PR from [current-branch] to main. Correct?
```

### 2. Search for task documentation

Look for task/spec files that describe what this PR should accomplish. Common locations by tool:

| Tool/Convention | Path |
|-----------------|------|
| Spec2Ship (s2s) | `.s2s/plans/*.md` (look for active plan matching branch name or commits) |
| AWS Kiro | `.kiro/specs/*/tasks.md` |
| Cursor | `.cursor/rules/*.md`, `.cursorrules` |
| Trae | `.trae/rules/*.md` |
| GitHub Issues | `gh issue list --assignee @me --state open` |
| Generic | `docs/specs/`, `specs/`, `tasks.md`, `TODO.md` |

Extract task IDs, titles, descriptions, and requirements references when found.

### 3. Analyze commits

For each commit on this branch, identify type, scope, task references, and breaking changes. Map commits to documented tasks when task files exist.

### 4. Verify task completion

If task documentation exists:

1. Identify main task from branch name (e.g., `feature/task-2-*` -> Task 2)
2. Find all sub-tasks (e.g., Task 2.1, 2.2, 2.3)
3. Check which sub-tasks are referenced in commits
4. Report missing sub-tasks

**If tasks incomplete**, STOP and show status:
```
Task 2 INCOMPLETE: 1/3 sub-tasks missing
- Task 2.1: done
- Task 2.2: done
- Task 2.3: MISSING
```

Ask user whether to complete missing tasks or proceed anyway.

### 5. Run tests

Run the project test suite. Tests **MUST** pass before creating PR.

### 6. Determine PR type and generate title

| Branch flow | Title prefix |
|-------------|-------------|
| feature/* -> main | `feat(scope):` |
| fix/* -> main | `fix(scope):` |
| hotfix/* -> main | `hotfix(scope):` |
| release/* -> main | `release:` |
| refactor/* -> main | `refactor(scope):` |
| chore/* -> main | `chore(scope):` |
| ci/* -> main | `ci(scope):` |
| docs/* -> main | `docs(scope):` |

**Title format**: `<type>(<scope>): <description>`
- Type: dominant commit type from analysis (feat > fix > refactor > ci > chore)
- Scope: most common scope from commits (kebab-case)
- Description: imperative, lowercase, no period, max 50 chars

**Breaking changes**: if any commit contains `BREAKING CHANGE:` or `!` after type, include a `## Breaking changes` section in the PR body.

### 7. Generate PR body

Use the appropriate template from `references/pr_templates.md` based on PR type and populate with gathered data.

### 8. Labels — applied post-create by `pr-labeler.sh`

**v4.7.C (#410):** `pr-labeler.sh` replaces the v4.3 `derive-area-label.sh`
and the v3.23.D `pr-labeler.yml` action. Reads the same `.github/labeler.yml`
SSOT; matches actions/labeler@v5 glob semantics (no star-crosses-slash
false positives); implements `sync-labels: true` (removes stale managed
labels when paths no longer match). Runs on every push via the flow in
step 10; no-ops under `ACTIONS_MODE=remote`.

Don't pass `--label` to `gh pr create` — pr-labeler.sh applies the right
set of area:* + documentation labels from the diff. One source, one
application path, no drift.

Verify after opening:
```bash
gh pr view "$PR" --json labels --jq '[.labels[].name]'
```

### 9. Determine milestone

The `run.sh` wrapper auto-resolves the milestone from the branch's `vX.Y` prefix (or the PR title) and attaches via `gh pr edit --milestone`. Implementation lives in `skc_resolve_milestone_from_branch()` (see the wrapper source).

**Rules (v4.18 #508 + v4.20 #515):**
- If a milestone whose title contains the PR's version prefix is open → attach.
- If only stale milestones are open (no version-prefix match) → SKIP. Don't attach stale.
- If the PR has no detectable version prefix AND multiple milestones are open → ask user.
- Match anchors on word boundaries with full regex-meta escape (titles like `v1.0 (beta)` are safe).
- API/parse failures are surfaced via `Warning: ...` and tracked separately from legitimate no-match (so the "skip" message tells you which case you're in).
- Never create a milestone automatically. User creates first; you attach on next create.

### 9b. Batching related sub-issues + local-iterate (CR budget saver)

CodeRabbit has **5 reviews/hour per repo**. Two patterns to stay under budget:

**Pattern A — Batch tightly-related sub-issues into ONE PR**

When an epic has 3+ sub-issues that share scope (same stack, same area, same kind of change), build them on ONE branch and open ONE PR with multiple `Closes #N` lines. Each sub-issue auto-closes on merge; parent still closes via `auto-close-parent.yml`.

| DO batch | DON'T batch |
|---|---|
| All blackbox config: deploy + scrape + alerts + dashboard | Sub-issues touching different stacks |
| Same commit-scope makes sense (`feat(monitoring): complete blackbox exporter`) | Need independent revertability |
| Later work doesn't depend on earlier sub-issue's MERGE (only on code present on branch) | Different reviewers / release cadences |

**Pattern B — Local iterate before push (bigger win)**

On a branch, commit per sub-issue locally, run the full v4.1 pipeline (see §0 — Phase 1 free-tools loop to convergence, then Phase 2 CR CLI once) between each sub-issue, iterate until the pre-push gate is met, THEN push once. CR-in-CI should find nothing; if it does, that's a Phase 1 coverage regression per CLAUDE.md rule 8. Combines with Pattern A:

```text
branch from main
┌─ sub-issue #A ──┐
│ edit → commit   │  (pre-commit fires locally)
│ Phase 1 loop    │  (6 tools parallel, ≤3 rounds to convergence)
│ Phase 2 CR CLI  │  (once, expect 0 findings)
└─────────────────┘
┌─ sub-issue #B ──┐  (same pipeline each)
└─────────────────┘
... more sub-issues ...

git push -u origin <branch>
gh pr create (Closes #A, #B, #C, #D)
→ CR-in-CI finds nothing (gate: required)
```

Use `ralph-loop:ralph-loop` to drive an iterate-until-criteria loop if the work has a clear exit condition (e.g., "iterate until Prometheus probe returns 2xx for all targets").

### 10. Create PR — pr-labeler first, then pr-lint-check

**v4.3.A (#368) / v4.7.B+C (#409, #410):** local gate runs the same 3
checks `pr-lint.yml` enforces (area label, `Closes #N`, template
sections). Uses `pr-lint-check.sh` + `pr-labeler.sh` which match the
action semantics exactly and respect `ACTIONS_MODE=remote` to avoid
dual-fire with CI.

Ordering: PR must exist before `pr-labeler.sh` reads its diff, and labels must be applied before `pr-lint-check.sh` validates them. The wrapper handles the full sequence:

1. Pre-create body validation (skip-label-check)
2. User-approval gate (title/body/milestone)
3. `gh pr create` (with conditional `--milestone`, args-array safe for spaces)
4. `pr-labeler.sh` derives `area:*` from the diff via `.github/labeler.yml`
5. Full `pr-lint-check.sh` on the now-labeled PR

Pre-v4.3.A relied on `pr-labeler.yml` server-side; the wrapper now derives the same label from the same SSOT + applies it explicitly. The workflow re-fires post-restore and is idempotent.

Use `--draft` if the PR is not ready for merge review yet (work in progress,
awaiting CI, or created only to trigger AI bot review on the branch).

### 10b. Post-create board sync (v4.5.D / v4.7.C) — MANDATORY during Actions cap

When `project-automation.yml` is disabled, the PR's Status doesn't auto-
transition to Review. Step 10 already ran `pr-labeler.sh` which applied
the correct area:* (including removing stale ones via sync-labels: true).
Just fire the board sync against the now-correct labels:

```bash
PR_NUMBER=$(gh pr view --json number -q .number)
.claude/local-backups/project-board-sync.sh --on-pr-open "$PR_NUMBER"
```

No re-derive / remove-loop needed — `pr-labeler.sh` in Step 10 handles
the label state, then `project-board-sync.sh` reads the final labels
and dual-writes to the board's Area/Type fields.

### 11. Wait for checks (blocking, GitHub-native)

After `gh pr create` returns, **block until all checks finish** so the user sees a single "PR created, checks green/red" outcome instead of an open-ended "checks running":

```bash
PR_URL=$(gh pr view --json url -q '.url')
PR_NUMBER=$(gh pr view --json number -q '.number')
echo "PR #$PR_NUMBER created: $PR_URL"
echo "Watching checks — will exit on first failure or when all pass..."
gh pr checks "$PR_NUMBER" --watch --fail-fast
```

- `--watch` polls GitHub and streams updates until every check reaches a terminal state
- `--fail-fast` exits non-zero the moment any required check fails, so the skill can surface the failure immediately
- If a check fails, fetch the logs (`gh run view <run-id> --log-failed`), fix, commit, push — then re-enter this step

This replaces ad-hoc polling with `gh pr checks` snapshots and keeps the session focused on one PR at a time.

## Project-specific rules (homelab)

**Required labels — pr-lint blocks merge without these:**
- One AREA label is REQUIRED: `monitoring`, `infrastructure`, `security`, or `performance`
- Type labels (`enhancement`, `bug`) are auto-applied by issue templates but add manually if creating from CLI

**Target branch:** Always `main` (no develop branch in this repo)

**Issue link:** REQUIRED. Every PR must have `Closes #N` in the body. pr-lint blocks merge without it.

**PR template — how to use it correctly:**
1. **Read `.github/pull_request_template.md` first** with the Read tool — see its structure (5-step health check, encryption, pre-merge sections).
2. **Follow the template's formatting EXACTLY** in your HEREDOC `--body` content — same headings, same checklist items, same order.
3. **DO NOT** use `--body-file .github/pull_request_template.md` — that pushes the raw template with empty checkboxes. The CLI does not auto-fill templates.
4. **DO NOT** combine `--template` with `--body` — `--template` is ignored when `--body`/`--body-file` is present.
5. Fill every checkbox with real state (`[x]` done / `[ ]` pending) based on what you actually did.

**CodeRabbit cadence (v4.1):** Phase 2 CR CLI runs ONCE locally (after Phase 1 convergence); CR-in-CI is the required blocking gate and should find nothing. Shared prepaid CR rate bucket is protected by the iteration discipline, not by limiting CR use. Show everything for approval ONCE, push ONCE.

## General rules

- **ALWAYS** show PR content for approval before creating
- **ALWAYS** use HEREDOC for body to preserve formatting
- **ALWAYS** check for open milestones and assign if one is active
- **ALWAYS** include `Closes #N` linking to the issue being worked on (one per line)
- **Labels** — do NOT pass `--label` to `gh pr create`. `pr-labeler.sh` (v4.7.C) applies area:* + documentation from the diff after PR creation, reading `.github/labeler.yml` SSOT. Single source; sync-labels semantic. See Step 10.
- **NEVER** create PR without user confirmation
- **NEVER** modify repository files (read-only analysis)
- **NEVER** create a milestone automatically

## Auto-continue

- **After `gh pr create` returns** → auto-run `gh pr checks $PR --watch --fail-fast` to block until checks settle. Handle CR comments via coderabbit:autofix (one batched push).
- **All checks green + CR addressed** → GATE: present to user for merge approval. Never self-merge.
- **Any check red** → auto-fetch failing run logs via `gh run view --log-failed`, diagnose, fix, new commit, push once.
- **CodeRabbit silent 10+ min** → GATE: flag to user, ask how to proceed (see github-pr-review skill "CodeRabbit unavailability").

## References

- `references/pr_templates.md` - PR body templates for all types (feature, release, bugfix, hotfix, refactoring, docs, CI/CD)
