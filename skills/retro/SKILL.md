---
name: retro
description: Use when user says "/retro", "session retro", "what went wrong this session", "lessons learned", or at the end of a session with accumulated correction signals. Reads `.claude/session-log.jsonl` (captured by capture-signal.sh #231) plus git state, task history, and CodeRabbit dismissals from the current session. Runs semantic classification on the raw signals (filtering false-positives like "no problem") and proposes concrete edits to skills, hooks, or memory files. Never auto-mutates — every proposed edit requires explicit user approval before applying.
allowed-tools: Bash(*), Read, Edit, Write, Grep, Glob
---

# Retro — session-end self-improvement cycle

Pair with `capture-signal.sh` (#231 — raw signal capture) and `memory-guard.sh` (#236 — active injection). This skill closes the loop: raw capture → semantic analysis → proposed edits → user-approved application.

## When to invoke

- User types `/retro` or natural-language equivalent
- SessionStart hook flags "N correction signals captured last session — consider running /retro"
- Proactive: at the end of a long or contentious session (3+ corrections captured)

## Step 1: Gather

```bash
# Raw signal log
LOG=".claude/session-log.jsonl"
[ -f "$LOG" ] || { echo "No session-log — nothing to retro"; exit 0; }

# Session git state for correlation
RECENT_COMMITS=$(git log --oneline -10)
CURRENT_BRANCH=$(git branch --show-current)
REBASE_COUNT=$(git reflog | grep -c rebase || echo 0)
REVERT_COUNT=$(git log --oneline --all | grep -ci revert)
```

## Step 2: Semantic classification (filter false-positives)

The raw log over-captures per #231 design. Filter now using context awareness:

For each entry in the log, decide:
- **Real correction** — user was genuinely redirecting work
- **Conversational "no"** — "no problem", "no worries" — discard
- **Validated approach** — positive signal confirming an earlier non-obvious choice — save to memory
- **Process signal** — "slow down", "think harder" — save as meta-feedback

Look at the `excerpt` field + the preceding tool call (if available) to disambiguate.

Output a summary table:

| Signal | Phrase | Excerpt | Preceding action | Classification |
|---|---|---|---|---|
| correction | no | "no wait that's wrong" | edited wrong file | REAL — file was wrong |
| correction | no | "no problem, proceed" | test passed | CONVERSATIONAL — discard |
| positive | exactly | "yes exactly that's it" | chose unusual merge strategy | VALIDATED — save memory |

## Step 3: Correlate with session artifacts

For each REAL or VALIDATED signal:

- **Was there a rebase / revert / force-push?** → likely a mistake that required cleanup
- **Was a CodeRabbit finding dismissed?** → check if correct dismissal or hallucination-handling I should log
- **Did I hit the same memory-guard rule twice?** → rule works; confirm it fired
- **Did I MISS a memory-guard that should have fired?** → propose new rule in `memory-guard.rules.json`

## Step 4: Prefer-edit-over-create — overlap check (v3.20 #243)

**Before proposing a new `feedback_X.md`**, check overlap against existing memory. Memory bloat is a real risk and the cheapest guard is preventing redundant files at proposal-time.

For each candidate new memory:

1. Read `MEMORY.md` index — get every existing memory's description
2. Read first 500 chars of each existing memory's body
3. Estimate semantic overlap with the candidate rule (Claude-as-classifier):
   - **≥60% overlap** → propose EXTENDING the closest existing memory instead of creating a new file. Show which existing memory + which section to add content to.
   - **30–60% overlap** → surface BOTH options (new file / extend existing) and note which existing memory is close. User decides.
   - **<30% overlap** → propose new file as today
4. If proposing a new file, it MUST be distinct enough that a reader wouldn't confuse it with existing memories

This preserves consolidation at the moment of creation. Consolidation-after-the-fact (memory-consolidate skill) is more expensive than not creating the redundancy in the first place.

## Step 5: Propose concrete edits

Output as a Markdown checklist — each item is a proposed file edit. Never apply without user go-ahead.

```markdown
## Proposed edits from session <sid>

- [ ] **EXTEND memory:** `feedback_<existing>.md` — add section "<topic>" (overlap 70% with existing rule; amend rather than duplicate)
- [ ] **NEW memory:** `feedback_<topic>.md` — captures rule "<one-liner>" (overlap <30% with existing; genuinely new scope)
- [ ] **EDIT rule:** `memory-guard.rules.json` — add rule catching pattern X (would have fired on <command>)
- [ ] **EDIT skill:** `<skill>/SKILL.md` — add rule "<new-rule>" to Rules section
- [ ] **EDIT CLAUDE.md:** add Always rule "<text>" (informed by repeated correction)
- [ ] **DISCARD signal:** <ts> — conversational "no problem"

Present the draft edits inline (with proposed content) so user can approve each individually.
```

## Step 5: Apply on approval

After user ticks which proposals to apply:
- For each approved edit, write the change
- Show the diff
- User re-approves the diff if it differs from proposal
- On final approval, add edits to the current git index (do NOT auto-commit; let user drive the commit)

## Step 6: Draft persistence

If the user defers (e.g., "file these but I'll review tomorrow"):
- Save the proposal list to `.claude/retro-drafts/<session-id>-<ts>.md` (gitignored)
- SessionStart hook surfaces "N unfollowed retro drafts" on next boot
- Drafts expire after 30 days (cleanup in weekly drift validator #232)

## Rules

- **Never** auto-apply edits — retro is a proposal tool, every write needs user go-ahead
- **Never** modify the raw `session-log.jsonl` — it's a primary source; archive it post-compact via #237, don't mutate
- **Always** cite the specific signal (timestamp + phrase) that motivated each proposal — traceability for future retros
- **Always** distinguish REAL vs CONVERSATIONAL corrections — over-filtering hides real signal, under-filtering pollutes proposals
- **Always** save positive-signal findings to memory when they confirm a non-obvious approach (per CLAUDE.md memory rule — "record from failure AND success")
- **Never** propose edits that duplicate existing memory/skill rules — check for overlap first via `grep` + the explicit Step 4 overlap check
- **Never** propose a new `feedback_*.md` when overlap with an existing memory is ≥60% — extend the existing memory instead (v3.20 bloat guard)
- **Always** keep proposed memory additions tight — pre-commit enforces 100-line cap per feedback file + 150-line cap on MEMORY.md index

## Acceptance criteria

- Running `/retro` after a session with ≥1 real correction produces at least 1 proposed edit
- Zero corrections + zero positive signals → "no actionable retro material" (don't force proposals)
- User approval gate is mandatory for every proposed edit
- Unfollowed drafts surface at next SessionStart

## Auto-continue

- After proposals presented → GATE: wait for user to tick which to apply
- After approval → apply each approved edit, show diff
- After apply → remind user to commit (don't auto-commit — user drives git)
- If user says "save for later" → write draft file, surface on next SessionStart
