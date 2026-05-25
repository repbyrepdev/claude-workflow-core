---
name: cr-resolve-conflict
description: Trigger CodeRabbit's resolve-merge-conflict feature on a PR and poll for the outcome. Use when ship-pr-cycle detects mergeStateStatus=DIRTY at push or merge-gate stage, OR when operator wants CR to attempt automatic conflict resolution before manual rebase.
---

# CR Resolve Conflict

Wraps CodeRabbit's [resolve-merge-conflict](https://docs.coderabbit.ai/finishing-touches/resolve-merge-conflict) feature.

## What it does

1. Pre-check: fetch PR state. If `mergeStateStatus != DIRTY` and `mergeable != CONFLICTING`, exit 0 (idempotent — nothing to resolve).
2. Capture `head_before` SHA + post `@coderabbitai resolve merge conflict` comment.
3. Poll loop (default 600s, configurable via `CR_RESOLVE_TIMEOUT_SEC`):
   - Watch for `head_after != head_before` (CR pushed a resolution commit) → success, exit 0
   - Watch for CR reply containing decline markers (`unable to resolve`, `decline`, `ambiguous`, `security-critical`, `requires manual`, `cannot automatically`) → fall back, exit 2
   - On timeout: exit 2 (treat as decline; operator does manual rebase)
4. Append JSONL entry to `.claude/logs/cr-resolve-conflict.jsonl`.

## Usage

```bash
.claude/skills/cr-resolve-conflict/run.sh --pr 70
.claude/skills/cr-resolve-conflict/run.sh --pr 70 --timeout 300
```

## When this fires

- **ship-pr-cycle push stage** — when `mergeStateStatus=DIRTY` detected, ship-pr-cycle invokes this skill before falling back to manual rebase (v0.9.0 integration; see #46).
- **Operator manual** — `@coderabbitai resolve merge conflict` is also commentable directly on the PR; this skill is the programmatic equivalent + telemetry.

## Why this exists

Per `feedback_check_existing_test_patterns.md` style — discover existing infra before reinventing. CodeRabbit's resolver:

- Simulates the merge in a sandbox
- Analyzes intent of each conflicting change via AI agent
- Validates resolution by checking conflict markers cleared + running build/lint
- Declines on ambiguous / security-critical (auth, crypto, access-control)

Before this skill, ship-pr-cycle at push stage would surface DIRTY state and require operator rebase. Many conflicts are mechanical (parallel pin bumps, formatting drift, etc.) — CR resolves these cleanly without operator round-trip.

## Safety

- Idempotent: re-run if outcome unknown; pre-check skips when no conflict
- Declines surfaced + logged + propagated as rc=2 (operator still in the loop for ambiguous cases)
- Never auto-merges; only resolves the conflict — the merge gate still requires CR-clean + operator approval

## Opt-out

`CR_RESOLVE_CONFLICT_DISABLED=1` → silent no-op (rc=0).

## References

- [CodeRabbit docs — Resolve merge conflicts](https://docs.coderabbit.ai/finishing-touches/resolve-merge-conflict)
- Related: `cr-plan` (parallel pattern — CR feature wrapped as plugin skill with poll + log)
- Issue: #44 epic, #45 this skill
