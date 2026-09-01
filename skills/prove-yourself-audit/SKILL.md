---
name: prove-yourself-audit
description: Mechanical enforcement of the PROVE YOURSELF rule (memory:feedback_dont_dismiss_cr_as_hallucination.md). Use at 4 trigger points during a review cycle so CR/agent/lint findings cannot be rejected without dogfood evidence. Auto-invoke when triaging findings, applying fixes, rejecting findings, or before commit.
---

# Prove Yourself audit

## Why this skill exists

PR #639 wasted ~30 min of CR budget + shipped a broken Stop hook past 5 review rounds because I rejected real CRITICAL findings 5x as "hallucination" without dogfood-testing. PR #639 r17–r23 repeated the same pattern 10 more times for `gpt-5-codex` (config silently accepted by Codex CLI, but the binary's own validator rejected it). Both rejections "verified" via internal-variable inspection or memory-citation, neither backed by an external authority I could submit as a counter-claim.

The user's 2026-04-26 rule: **"call this the prove yourself rule and this rule SHOULD ALWAYS BE ON"**. This skill makes the rule mechanical — rejections without evidence are blocked at commit time, not just discouraged in memory.

## 4 trigger points (conceptual, not CLI flags)

The 4 trigger points map to **subcommands** below — `--at <trigger>` is *not* an actual flag (the run.sh CLI uses positional subcommands like `record-rejection` / `record-fix` / `audit` / `check-commit` / `reset`). Use this table to know **when** to invoke which subcommand:

| Trigger point | When to invoke | Subcommand to call |
|---|---|---|
| At findings | After CR/agent/lint returns findings, before triaging | (Read findings + plan dogfood. No subcommand call yet.) |
| At fixes | After applying a fix, dogfood-test it | `record-fix` with `--retest-cmd` and `--retest-rc` |
| At rejection | Before labeling a finding "hallucination/false-positive/rejected" | `record-rejection` with all 6 required evidence fields |
| At commit | Pre-commit gate (automatic via prove-yourself-gate.sh hook) | `check-commit` (gate calls this) |

## Subcommands

```bash
.claude/skills/prove-yourself-audit/run.sh <subcommand> [args]
```

### `record-rejection`
Records a rejection of a finding. Refuses unless ALL **6 required evidence fields** are non-empty: `--finding-text`, `--dogfood-cmd`, `--dogfood-output`, `--dogfood-rc`, `--external-authority`, `--reason`. (The "3 conceptual evidence types" map: dogfood-cmd + dogfood-output + dogfood-rc cover gates 1-2 of the rule; external-authority covers gate 3; reason summarizes why the rejection holds. All six fields are required by the validator.)

```bash
.claude/skills/prove-yourself-audit/run.sh record-rejection \
  --finding-id <hash-or-tag> \
  --finding-text "<one-line summary of CR's claim>" \
  --dogfood-cmd "<exact command run, including flags>" \
  --dogfood-output "<verbatim output captured>" \
  --dogfood-rc <integer> \
  --external-authority "<URL / man-page line / API response that contradicts CR>" \
  --reason "<one-line: why this rejection holds>"
```

Writes `.claude/.session-state/prove-yourself/<finding-id>.json`. Exits 2 if any required field is empty, OR if either `--external-authority` or `--reason` matches an anti-pattern (e.g., "memory says", "I tested similar", "verified rejected"). Both fields are scanned because evidence-via-self-reference can leak into either slot.

### `record-fix`
Records that a finding was applied + re-tested. Distinct file shape from `record-rejection` so audit can distinguish.

```bash
.claude/skills/prove-yourself-audit/run.sh record-fix \
  --finding-id <hash-or-tag> \
  --finding-text "<one-line>" \
  --fix-summary "<what changed>" \
  --retest-cmd "<command that exercises the fix>" \
  --retest-rc <integer>
```

**The retest evidence is RUN, not trusted (#2562).** `record-fix` re-executes
`--retest-cmd` at record time (timeout `PROVE_RETEST_TIMEOUT`, default 120s)
and refuses the record unless the actual exit code equals `--retest-rc`
(EVIDENCE MISMATCH otherwise). Consequences:

- The retest command must be **idempotent/read-only** — it runs again right
  here. A test or check invocation qualifies; a mutating command does not.
- A claimed **nonzero** rc is legitimate evidence ("the gate refuses with
  rc 1" proves enforcement) — the contract is *match*, not *zero*.
- The record is stamped `retest_verified: true` + `retest_actual_rc` +
  `retest_output_tail`; `audit`/`check-commit` refuse fix records without
  the stamp, so hand-forged or pre-#2562 records cannot pass the gate.

**The SYMPTOM DIFFERENTIAL (#2643).** A passing retest proves the command
runs, not that it would have FAILED before the fix — a hook that was already
green satisfies it. So `record-fix` also takes three flags that describe a
*difference*:

```bash
  --symptom-cmd "<command whose exit code the fix changes>" \
  --symptom-baseline-rc <rc WITHOUT the fix> \
  --symptom-fixed-rc <rc WITH the fix>      # must differ from baseline
```

They are **REQUIRED** when `--source=issue`, and when any `--cited-files`
entry is cycle-critical (`hooks/`, `_lib/`, `pre-commit-hooks/`,
`scripts/cr/local-review.sh`). Optional elsewhere — but still re-executed
and verified if you supply them, so "optional" never means "free text".

Both halves are run for real: the fixed half in the working tree, the
baseline in a **detached worktree at `--baseline-ref`** (default `HEAD`,
because the cycle order is fix → record-fix → commit, so at record time HEAD
*is* the pre-fix tree). The branch's changed *and untracked* `.bats` files
are copied into that worktree, so a brand-new test can detect the old bug.
Timeout: `PROVE_BASELINE_TIMEOUT`, falling back to `PROVE_RETEST_TIMEOUT`,
then 120s.

Refusals you may hit, each with its remedy:

- **already committed** — nothing cited differs from HEAD, so the baseline
  would re-run the fixed code. Pass `--baseline-ref <sha-before-the-fix>`.
  Naming `HEAD` explicitly does not dodge this; the check follows the commit
  the ref resolves to, not how you spelled it.
- **absence-shaped baseline (127)** — a fix that ADDS a file makes the
  baseline exit "command not found", which looks like proof and is not. If
  127 genuinely *is* the reported symptom, say so with
  `--allow-absence-baseline` (recorded in the JSON, so it is auditable).
- **deadline kill** — an rc of 124 at or past the timeout is *our* SIGTERM,
  never evidence. Raise `PROVE_BASELINE_TIMEOUT` if the check needs longer.

**What it does and does not prove.** It proves the exit code *depends on the
diff*. It cannot prove the command is relevant to the fix, and an adversarial
review confirmed three ways to satisfy it without proving anything:

- **Observe the diff** — add a comment to a cited file and `grep -q` for it.
  The rcs differ; the fix is a no-op.
- **Live-cwd asymmetry** — the fixed half runs in your working tree, the
  baseline in a pristine checkout, so `test -f <any untracked file>` differs
  for free. Inherent: running the fixed half somewhere clean would throw away
  the uncommitted fix being tested.
- **Measure then revert** — nothing binds the record to the tree it was
  measured on.

The trigger is also self-selected: `--cited-files` is optional, so an author
who cites nothing is never asked for a differential at all.

Treat it as a floor that makes the honest path the easy one, not a fence. The
number `audit` prints is a signal for a human to read, not a proof — and it
is not enforced at commit time.
- **Cycle-critical citations demand the real entry point**: when
  `--cited-files` names `hooks/*.sh`, `_lib/*.sh`, `pre-commit-hooks/*.sh`,
  or `scripts/cr/local-review.sh` (`.claude/`-mirror spellings normalized),
  that path must appear in **command position** inside `--retest-cmd` — a
  bats fixture alone, or a command that merely *mentions* the path, is not
  production-shaped evidence (#2544's three escaped defects all had green
  bats). Additionally, nothing that can SWALLOW the entry point's exit
  status may follow it: `;`, `|`, `&`, or a newline after the cited path
  refuses the record (`hooks/x.sh || true` would report 0 regardless —
  the laundering the backup reviewer caught on #2626). The full contract
  after its second catch (`true || hooks/x.sh` SKIPS the entry point via
  short-circuit while reporting `true`'s rc): a cycle-critical retest is
  a **single pipeline** — no `;`, `&`, `&&`, `||`, or newlines anywhere.
  Feed-pipes (`printf x | bash hooks/y.sh`) remain legal because every
  pipeline stage executes unconditionally; a pipe *after* the path still
  refuses (rc = pipe tail). One record per entry point.

### `audit`
Read-only audit of all records under `.claude/.session-state/prove-yourself/`. Reports count of rejections / fixes / records with missing fields. Exits non-zero if any record is malformed.

### `check-commit`
Wired as a pre-commit hook (see below). Runs `audit`, blocks commit if any rejection lacks evidence.

### `reset`
Wipes all `*.json` records under `.claude/.session-state/prove-yourself/`. Use after a successful PR ships to clear session state. Manual — there is no automatic post-merge cleanup hook today; the eventual ship-pr-cycle orchestrator (tracked under v4.28 epic #635) will handle this automatically once filed and merged.

## Pre-commit integration

The `check-commit` subcommand is invoked by `.claude/pre-commit-hooks/prove-yourself-gate.sh`. Bypass via `PROVE_YOURSELF_GATE_SKIP=1` (audit-logged like other gate skips).

The gate refuses commits where any `*.json` under `.claude/.session-state/prove-yourself/` has empty required fields (per the `audit` subcommand's per-kind validation). Repeat-rejection detection (≥3 times same finding-id) is **not yet implemented** — tracked as a follow-up enhancement under v4.28 epic #635.

## Inline workflow (when not in a review cycle)

If I'm doing ad-hoc work and CR/lint flags something, the explicit invocation is:

1. Read CR's exact reproduction script (verbatim, no simplification).
2. Run the production code path with realistic input (NOT a minimal example).
3. Capture user-visible behavior (hook output, harness message, dashboard text).
4. **If 1–3 contradict CR**: invoke `record-rejection` with **all 6 required fields**: `--finding-text`, `--dogfood-cmd`, `--dogfood-output`, `--dogfood-rc`, `--external-authority`, `--reason`.
5. **If 1–3 confirm CR**: apply the fix, re-run, invoke `record-fix` with `--finding-text`, `--fix-summary`, `--retest-cmd`, `--retest-rc`.

The rule of thumb: rejection requires evidence I could submit as a counter-claim. "I tested something similar once" is NOT proof. "Here's the registry API output / man page section / `--help` text contradicting CR's claim" IS proof.

## Anti-pattern catalog (refuses to record these as rejections)

The skill's `record-rejection` validator refuses these patterns (case-insensitive substring match in BOTH `--external-authority` AND `--reason`):

- `memory says`, `I remember`, `I tested similar`
- `od shows` (NUL-stripping anti-pattern from PR #639)
- `length matched` (length-truncates-at-NUL anti-pattern — citing string length as proof of preservation)
- `verified rejected` (citing prior rejection as evidence — the self-reinforcing loop)
- `i think it works` (vibes-as-evidence)

The bare `${#var}` literal was previously in this list but was dropped (Phase 1 r1 code-reviewer #645) — it false-positived on legitimate bash-docs citations. The semantic anti-pattern (concluding from length) is captured by `length matched`.

If the validator catches one of these, the skill prints the lesson + the original incident ref, refuses to record, and exits 2.

## State files

`.claude/.session-state/prove-yourself/<finding-id>.json` schema:

```json
{
  "finding_id": "stop-hook-nul-stripping",
  "kind": "rejection|fix",
  "finding_text": "stop hook reports 0 uncommitted files in dirty tree",
  "ts": "2026-04-27T15:00:00Z",
  "decision_data": {
    "dogfood_cmd": "echo 'foo' > t.txt; bash hooks/stop-uncommitted.sh",
    "dogfood_output": "Modified files: 1\n  - t.txt",
    "dogfood_rc": 0,
    "external_authority": "https://gnu.org/bash/manual/...",
    "reason": "bash 5.1+ preserves NULs through cmd-sub when target is array"
  }
}
```

State persists between sessions until manually cleared via `run.sh reset`. There is **no automatic post-merge cleanup hook** today — when a PR ships, run `reset` to wipe stale records (or the next cycle's review will audit them). The ship-pr-cycle orchestrator (follow-up under #635) will eventually handle this automatically.

## Auto-continue

- After triaging findings: dogfood-confirm each finding, then either apply (record-fix) or reject (record-rejection with evidence). Default = confirm-then-decide, NOT bulk-apply or bulk-reject.
- After `record-rejection`: if the record was accepted (evidence sufficient), continue; if refused (anti-pattern caught), default-apply the fix and re-test (per the rule).
- `check-commit`: fires automatically via pre-commit hook; no Claude action needed.
