---
name: ack
description: Batch-acknowledge every pending hook-ack entry in one Read. Pairs with v4.30.D #800 PostToolUse Read auto-clear when target is the sentinel itself.
disallowed-tools: Edit Write MultiEdit NotebookEdit Bash
---

# ack — batch hook-ack acknowledgment

When `hook-output-pending.txt` lists N pending entries (test runs that exercise gate-fail paths, cascading PreToolUse failures), `/ack` reads them all in one tool call. The PostToolUse Read clear hook detects when the Read target is the sentinel itself and truncates the file — clearing every listed entry at once.

## Usage

`/ack` — no arguments.

## Workflow

1. Print the sentinel contents (each line: `<ts>\t<hook>\t<reason>\t<file_path>`)
2. Print a per-entry summary mapping each ack to its diagnostic file (when present)
3. Read the sentinel itself (`Read .claude/.session-state/hook-output-pending.txt`) — this triggers PostToolUse hook-ack-clear.sh's bulk-clear path

After running, the sentinel is empty + every diagnostic file referenced has been surfaced to the operator's context window (via the per-entry summary + the sentinel read).

## Safety

- The per-instance diagnostic files at `.claude/.session-state/hook-ack/<hook>/*.txt` are NOT deleted — they persist as the audit trail.
- Reading the sentinel surfaces every (hook, reason, file_path) triple to context. If a particular ack's diagnostic body needs deep inspection, the operator can still Read the per-file path explicitly afterward.
- Pairs with v4.30.A bats-context skip — under `BATS_TEST_NAME`, sentinel never accumulates test-side-effect entries; `/ack` only handles real-session backlog.

## When to use vs per-file Read

- **Many same-(hook, reason) entries from a single bats run** → `/ack` (one tool call clears them all)
- **One unfamiliar ack you need to dig into** → individual `Read <per-file diagnostic>` (preserves fine-grained surfacing)
- **Mid-pipeline blocker you need to understand fully** → per-file Read (don't batch-skip)

## Auto-continue

- **Sentinel cleared, was mid-pipeline** → return to the blocked action and retry it (the ack was the blocker; the underlying gate already passed or the finding is now acknowledged).
- **Sentinel cleared, entries were bats test side-effects** → no further action; resume normal work.
- **An entry needs deep inspection** → do NOT batch-clear; `Read` that entry's per-file diagnostic individually first, then fix its root cause before retrying.
