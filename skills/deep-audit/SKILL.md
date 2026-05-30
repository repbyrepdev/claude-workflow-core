---
name: deep-audit
description: Use when user asks "what can we improve", "deep dive our workflow/stacks/automations", "audit our process", "how could we interact better", "are there gaps we missed", "debug this new deployment", or similar discovery/gap-finding language. Launches N parallel Explore agents scoped to different areas, triple-checks every finding against live state (no hallucinations), reports in running-summary format, applies real fixes to the current PR (no cascade), loops until a clean round returns no findings.
allowed-tools: Bash(*), Read, Edit, Write, Glob, Grep
---

# Deep Audit — parallel agents, triple-check, fix-in-place

When invoked (natural language or via explicit request), follow this pattern exactly.

## 1. Scope the audit

Ask the user (only if genuinely ambiguous):
- What's the target? (workflows / stacks / specific service / a just-merged PR / new container deploy)
- How many rounds? (default: 1 round of 10 agents; escalate if user asked for "keep going until clean")

Do NOT ask if the scope is already clear from context.

## 2. Launch N parallel Explore agents

Pick N scopes (default N=10) covering orthogonal areas so agents don't duplicate work:

Default set of 10 scopes for the homelab:
1. `scripts/maintain.sh` internals
2. `scripts/restore.sh` internals
3. `.claude/skills/` + `.claude/hooks/` coverage
4. `.github/workflows/` + Renovate config
5. Grafana dashboards metric accuracy + units
6. Prometheus rule_files + Loki alerts + **Alertmanager → Pushover receiver chain** (pushover webhook URL correctness, docker-event-monitor config, maintain.sh pushover() call sites — full end-to-end notification integrity, not just rule evaluation)
7. Authelia + SWAG security config
8. Cron timing + env (crontab, PATH inheritance, Keychain accessibility)
9. Secret hygiene + `.gitignore` coverage
10. CLAUDE.md + memory file coherence

Re-scope for non-homelab audits (e.g., "audit this new stack" → per-container healthcheck, compose invariants, secret placement, Renovate compat, homepage label, Prometheus scrape).

Every agent prompt MUST include:
- **Exact file paths** to audit
- Instruction: **"Report ONLY real issues. Triple-check each finding against actual file content. No invented concerns."**
- Instruction: **Rank HIGH/MEDIUM/LOW, file:line ref, triple-check note**
- Word limit (300-500 words typical)

Launch all in parallel (single assistant message with multiple Agent tool calls).

## 3. Triage findings — verify each before acting

Agents hallucinate. Before acting on any finding, **triple-check against live state**:
- "Plaintext secret committed" → `git check-ignore FILE` + `git ls-files FILE`
- "Metric doesn't exist" → query Prometheus `/api/v1/query` directly
- "Hardcoded count is wrong" → actually run the count (`ls | wc -l`)
- "Rule not enforced" → read the hook/workflow yourself

Produce a **running summary table** in the reply:
```
| # | Sev | Finding | Status |
|---|---|---|---|
| R2-5.1 | HIGH | 2 plaintext files not gitignored | verified → fixing |
| R2-2.3 | HIGH | "Alertmanager plaintext keys" | hallucination — file is gitignored, agent read decrypted content |
| R2-1.1 | MED | metric name X doesn't exist | verified → deferred to separate PR (scope) |
```

Categories:
- `verified → fixing` — real, fits current PR scope
- `hallucination` — agent error, dismiss with reason
- `verified → deferred` — real but out-of-scope (open follow-up issue, don't fix now)
- `needs more info` — can't verify without running container / checking UI

## 4. Apply real fixes to CURRENT PR (no cascade)

Cardinal rule: **fix findings in the branch that's already open**. Do NOT open a new PR for each finding. Do NOT open a new issue unless the user explicitly approves deferring.

Make one focused commit per logical scope (e.g., "gitignore fix + hook permissions + healthcheck additions" can all be one commit titled "PR-A: R2 verified fixes — N categories").

**Commit via the git-commit skill wrapper** — `.claude/skills/git-commit/run.sh` (it sets `SKILL_WRAPPER=1` so the `git commit` passes skill-bypass-guard, and enforces Conventional Commits + the Co-Authored-By trailer). A raw `git commit` is refused by the guard with a remediation pointing here.

Respect CR budget: commit locally after each round of fixes; do NOT `git push` until the user approves remote + merge. User's "push" in conversation means local commit.

## 5. Run full verification (the work actually works)

After fixes, verify:
- `shellcheck scripts/*.sh` clean
- `actionlint .github/workflows/*.yml` clean
- `bash scripts/maintain.sh` end-to-end on current branch completes without new errors
- If compose files changed: `docker compose -f stacks/<changed>/compose.yaml config` parses
- If container healthchecks changed: recreate the container + wait for `healthy`

## 6. Re-audit (next round)

Launch another N parallel Explore agents with scopes that are **different** from the last round (rotate coverage) OR same scopes if the last round found issues in them.

Stop condition: one full round comes back with **zero real findings** (all agents either return empty or only items confirmed as hallucinations/deferred).

If findings: loop (GOTO step 3).

If clean: proceed to step 7.

## 7. Report + gate

Summary format:
```
Audit complete after N rounds.
- Total findings surfaced: X
- Real fixes applied: Y
- Hallucinations dismissed: Z
- Deferred to future work: W (issue #NNN)
- Clean rounds to exit: 1 (mandatory)
```

Present to user with GATE for:
- Remote push (respects CR budget — one push, one CR review)
- Merge + tag (per standard workflow 4-gate model)

## Running-summary format — MANDATORY for user-facing updates

Every status message during a multi-step audit/fix must include a table with:
| # | Sev | Finding | Status |

Do NOT collapse to prose while work is ongoing. User needs to see what's been found, what's verified, what's being fixed, what's pending.

## Auto-continue

- Audit scope clear + no blockers → launch agents immediately
- Findings all verified as hallucination → report + exit (no fixes to apply)
- Findings include real fixes → apply to current PR + re-audit
- User says "keep going" / "another round" → loop
- User says "enough" / "stop" → stop and report state

## User gates (only these — everything else auto)

- **Design decision** — agent finds a gap where the right fix is a judgment call
- **Defer-to-future** — real finding that user must say "yes open a follow-up issue, out of scope"
- **Remote push** — CR budget guard: one push per PR, confirmed by user
- **Merge** — standard pre-merge gate

## User interrupt phrases

"wait", "stop", "enough", "pause", "let me check", "different scope", "hallucinating"
