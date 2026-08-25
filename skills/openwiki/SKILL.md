---
name: openwiki
description: Generate and maintain a repository's OpenWiki evidence index. Use when the user wants to set up OpenWiki, generate wiki//openwiki/ docs, refresh generated documentation, wire the docs hub, or asks why generated pages reverted. Covers the free in-chat MCP lane (host session, no provider key) and the metered CI lane (scheduled robot PRs).
argument-hint: [status|preflight|doctor]
---

# openwiki

OpenWiki (`langchain-ai/openwiki`) is a DeepAgents CLI that generates an
`openwiki/` evidence index from source. This skill owns the operational
contract for running it here — the parts that are NOT in any README and each
cost a failed run to learn.

Read `references/operations.md` before the first run on a machine or repo.
That file is the SSOT for the gotchas and the steering rules; nothing here
duplicates it.

## Two lanes — pick deliberately, they have different costs

| | In-chat (MCP) | CI (scheduled) |
|---|---|---|
| Runs on | The host agent's own session | A GitHub runner |
| Costs | Nothing extra — the Claude subscription already in use | Copilot AI credits (or a metered provider key) |
| Provider key | **None** | `COPILOT_API_KEY` + `OPENWIKI_MODEL_ID` |
| Good for | **First generation** (reads the whole codebase — the expensive pass) | Weekly deltas (cheap: diffs HEAD against the last documented commit) |
| Trigger | This skill, interactively | `openwiki-update.yml` cron / dispatch |

The split matters: initial generation is the expensive pass and the in-chat
lane makes it free, so **init in-chat, then let CI carry the deltas.** Claude
models through the Copilot provider crash the tool — the in-chat lane is the
supported way to run OpenWiki on Claude (see `references/operations.md`).

## Preconditions (mechanical, not advisory)

`run.sh preflight` enforces these; do not hand-wave them.

- **Clean tree.** `openwiki --init` rewrites `AGENTS.md` and `CLAUDE.md`
  inside `<!-- OPENWIKI:START/END -->` blocks in the current git root. In this
  repo those files are byte-SSOT-locked (hash-drift + bootstrap-heredoc
  parity), so an init against a dirty tree can trip two gates and bundle
  unrelated files into a commit.
- **CLI present and MCP wired** — `scripts/bootstrap-machine.sh` installs the
  pinned CLI and runs `openwiki integrations install claude`. The MCP server
  is read at session start, so a fresh install is usable in the NEXT session.
- **Never vendor the installer's skill files.** `openwiki integrations install
  claude` writes `~/.claude/skills/openwiki/` with SHA-256 manifests. Those are
  third-party and regenerated; committing them creates silent drift against
  this repo's hash gates.

## Steering the generator

Corrections go in `openwiki/INSTRUCTIONS.md` — a standing brief re-read every
run. Hand-edits to generated pages are reverted by the update loop, so a fix
applied to a page is lost while the same fix phrased as a durable rule in
INSTRUCTIONS.md persists. Phrase entries as rules, not one-off patches.

## Wiring a repo (opt-in, per repo)

`scripts/bootstrap-repo.sh --with-openwiki` writes the workflow pair, the
pinned toolchain, and a seeded `openwiki/INSTRUCTIONS.md`. The cron ships
**disabled** — a bootstrapped repo never starts spending credits on its own;
enabling is a deliberate edit plus three repo secrets (see
`references/operations.md` for which, and the token-type trap).

## Commands

```bash
skills/openwiki/run.sh status      # CLI version, MCP wiring, repo init state
skills/openwiki/run.sh preflight   # refuse-if-unsafe checks before an init/update
skills/openwiki/run.sh doctor      # status + preflight + remediation hints
```

## Auto-continue

- **`status` shows CLI missing or MCP unwired** → run `scripts/bootstrap-machine.sh`, then restart the session so the MCP server loads
- **`preflight` refuses on a dirty tree** → commit or stash first; never `--init` over uncommitted work
- **First generation needed** → run the in-chat MCP lane (free), not the CI lane
- **Generated page is wrong** → add a durable rule to `openwiki/INSTRUCTIONS.md`; do NOT edit the page
- **Repo should self-update** → `bootstrap-repo.sh --with-openwiki`, set the three secrets, then enable the cron deliberately
- **Blocked** → read `references/operations.md`; the eight gotchas cover every failure seen so far
