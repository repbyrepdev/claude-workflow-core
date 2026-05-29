---
name: brainstorm
description: Use when the user says "brainstorm", "let's discuss", "let's think about", "what do you think about X", or prefixes a request with "brainstorm:". The user is NOT asking me to execute — they want open-ended discussion, comparative analysis, or architectural exploration. Output a structured brainstorm with Problem / Options / Tradeoffs / Recommendation. Never write code, never run destructive commands. Background tasks (monitors, watchers) keep running. Optionally record the outcome as a `brainstorm`-labeled GitHub issue for traceability.
allowed-tools: Bash(gh issue view:*), Bash(gh issue list:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(gh pr checks:*), Bash(gh repo view:*), Bash(gh label list:*), Bash(gh release list:*), Bash(git log:*), Bash(git diff:*), Bash(git status:*), Bash(git show:*), Bash(grep:*), Bash(ls:*), Bash(cat:*), Bash(head:*), Bash(tail:*), Bash(wc:*), Read, Grep, Glob, WebFetch, WebSearch
---

# Brainstorm — discussion mode, not execution

Pair with `.claude/hooks/brainstorm-detect.sh` (UserPromptSubmit — detects the keyword, injects a reminder to stay in brainstorm mode). Pair with `.github/ISSUE_TEMPLATE/brainstorm.yml` (for persisting the decision as a trackable issue).

## When to invoke

- User says: "brainstorm", "let's discuss", "let's think about", "what do you think about X", "I want to brainstorm Y"
- User prefixes prompt with `brainstorm:` or `/brainstorm`
- User asks an exploratory question with multiple reasonable answers ("should we A or B?", "how should we approach Z?")

## Rules

- **Do not start executing.** Background tasks already running (Monitor, background Bash) keep going — do NOT pause them.
- **Do not open new branches, commit, push, or open PRs** based on a brainstorm.
- **Do not write implementation code.** Short bash snippets for verification (read-only: `gh issue view`, `git log`, `grep`, `cat`) are fine to gather context.
- **Do offer concrete options** with tradeoffs — vague "it depends" is not useful.
- **End with a recommendation and a "ready when you say go" line** — user is the decider, you're the consultant.

## Structure (what the brainstorm output looks like)

```markdown
## Problem
<1-3 sentence framing — why this matters, what's unresolved>

## Options

### Option A — <label>
- What: ...
- Cost: ...
- Risk: ...

### Option B — <label>
- What: ...
- Cost: ...
- Risk: ...

### Option C — <label>
- What: ...
- Cost: ...
- Risk: ...

## Tradeoffs / open questions
- <unresolved question 1>
- <unresolved question 2>

## Recommendation
<which option + why, in 2-3 sentences>

## Next step
Ready to execute when you say go. Optionally: want me to record this as a brainstorm issue for traceability?
```

## Recording a brainstorm as an issue (optional, offer at end)

If the brainstorm reached a concrete decision or the user says "yes record it" / "track this" / "file it":

```bash
# Use the brainstorm issue template.
# Note: CLI `gh issue create --body ...` bypasses template frontmatter,
# so the `brainstorm` label must be applied explicitly here. ai-triage
# handles area:* afterward, so the --label <area> fallback is only
# needed if ai-triage is down.
gh issue create \
  --title "brainstorm: <one-line topic>" \
  --label brainstorm \
  --milestone <active-milestone-or-none> \
  --body "$(cat <<'EOF'
**Area:** <area>

**Topic:**
<what we discussed>

**Context:**
<triggers, constraints, prior attempts>

**Ideas so far:**
- Option A: ...
- Option B: ...
- Option C: ...

**Tradeoffs / open questions:**
- ...

**Decision or next steps:**
<summary of the conclusion — OR "pending" if unresolved>

**Follow-up:**
- [ ] Convert to task/bug/feature once ready to implement
- [ ] OR close as "won't do" with rationale
EOF
)"
```

When the brainstorm later becomes actionable, convert with the `plan-me`
label so CodeRabbit auto-plans an epic+sub-issue breakdown for the chain
described in epic #175 (brainstorm → cr-plan → epic+subs → ship-pr-cycle):

```bash
# Open a new task/feature issue that references the brainstorm.
# The `plan-me` label triggers CR to post a sub-issue breakdown plan in
# the new issue thread. The cr-plan skill then parses that plan into an
# epic + subs (see github-epic-creation skill). ship-pr-cycle picks up
# the highest-priority sub automatically.
gh issue create --title "<action>" \
  --label plan-me \
  --body "Implements decision from brainstorm #<N>. Closes #<N> (discussion resolved)."
# ai-triage applies priority:* + area:* server-side based on the body;
# plan-me is set explicitly at create-time so CR sees it immediately.
# Then close the original brainstorm issue.
gh issue close <N> --comment "Resolved — implementation tracked in #<new>."
```

If the brainstorm's decision is straightforward and doesn't need CR
planning (e.g. a one-line fix), omit `--label plan-me` — the operator
or Claude can implement directly.

## Don'ts

- **Don't** paste the user's question back at them as "what I heard you say" — get to analysis.
- **Don't** present more than 3-4 options. If you have more, group them.
- **Don't** hedge with "both are fine" — pick one and defend it.
- **Don't** add work to your queue without a user-approval gate. Brainstorm output is advisory.
- **Don't** interpret a brainstorm as silent approval to start the work. Explicit "go" required.

## Labels to apply on brainstorm issues

- Always: `brainstorm`
- Plus one area: `monitoring` / `infrastructure` / `security` / `performance` (per repo convention)

## Integration with pr-lint

Brainstorm issues never become PRs directly — they convert to task/feature/bug issues first. `pr-lint.yml`'s template-section step therefore doesn't need a brainstorm exemption.

## Auto-continue

After presenting the brainstorm output:
- **If user responds with "go" / "do it" / "start" / confirmation of a specific option** → exit brainstorm mode, proceed with execution (new task, new branch, etc.)
- **If user responds with more questions or pushback** → iterate on the brainstorm; do NOT start executing
- **If user says "record it" / "file it" / "track this"** → create the brainstorm issue (above), then stop
- **If user asks to brainstorm something else** → stay in brainstorm mode with the new topic

Silence from the user is NOT approval. Never start executing without explicit go.
