---
name: github-epic-creation
description: Create a GitHub epic (parent + N sub-issues) with GraphQL sub-issue linking + auto-milestone. Invoke via the run.sh wrapper.
---

# github-epic-creation (v4.20 #519)

Creates an epic parent issue plus N sub-issues, links them via GraphQL `addSubIssue`, and attaches the active (or auto-matched) milestone.

## Usage

```bash
.claude/skills/github-epic-creation/run.sh \
  --title "v4.X EPIC: short scope" \
  --body-file /tmp/epic-body.md \
  --sub-title "title-1" --sub-body-file "/tmp/body-1.md" \
  --sub-title "title-2" --sub-body-file "/tmp/body-2.md" \
  [--milestone vX.Y] [--label enhancement]
```

Sub-issue title + body path are passed as paired flags (`--sub-title` /
`--sub-body-file`) because epic sub-titles commonly contain colons
(e.g., "v4.Y.A: scope"). The wrapper validates that flag counts match.

## What it does

1. Creates the parent epic issue, explicitly adding `epic` + `enhancement` labels (the wrapper adds them if not already in `--label`; `gh issue create --body-file` does NOT auto-apply template frontmatter labels — that only happens via `--template` or the web UI picker).
2. For each (title, body-file) pair: creates the sub-issue, then calls `addSubIssue` GraphQL mutation to link it to the parent.
3. Auto-attaches the milestone matching the branch's version prefix (via `skc_match_milestone`).
4. Verifies all subs resolve as children via GraphQL `subIssues.totalCount` sanity check.
5. Fails-atomic (best-effort): sub-body files are validated UPFRONT (before the parent issue is created) — if any body is missing, exits 2 before touching github.com. However, GitHub itself offers no multi-issue transactional semantics, so if the `addSubIssue` GraphQL mutation fails mid-loop (after the parent + some subs are already created), the wrapper exits 2 and names the parent so you can manually clean up the partial state. "Atomic" here means "the wrapper never creates a partial graph on its own", not "GitHub rolls everything back".

## Why a wrapper

Epic creation is a 1-parent + N-sub multi-step flow where partial failure can leave orphan issues. The wrapper reduces that risk via upfront sub-body-file validation + explicit hard-fail on link-verification errors — best-effort caller-facing atomicity, not GitHub-side transactional rollback.

## Auto-continue

- **Epic + subs created + linked** → report parent + sub numbers. If the operator named a first sub to work, assign `@me` + branch `feat/vX.Y/<sub>-…`; otherwise leave for pickup.
- **`addSubIssue` failed mid-loop (rc=2)** → the wrapper names the partial-state parent; verify which subs linked + clean up orphans before retrying.
- **Sub-body file missing (upfront rc=2)** → no github mutation happened; fix the body path + re-run.
