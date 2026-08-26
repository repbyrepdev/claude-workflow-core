---
name: openwiki-lane
description: Run and maintain a repository's OpenWiki generated docs. Use when the user wants to set up OpenWiki, generate or refresh the openwiki/ evidence index, wire the docs hub, choose between the free in-chat lane and the metered CI lane, or asks why an edit to a generated page reverted. Covers preflight safety, the steering channel, and per-repo enablement.
argument-hint: [status|preflight|doctor]
---

# openwiki-lane

OpenWiki (`langchain-ai/openwiki`) is a DeepAgents CLI that generates an
`openwiki/` evidence index from source. This skill owns the operational
contract for running it here — the parts that are NOT in any README and each
cost a failed run to learn.

**Named `openwiki-lane`, not `openwiki`, on purpose:** `openwiki integrations
install claude` writes a third-party skill to `~/.claude/skills/openwiki/`,
and `scripts/bootstrap-machine.sh` runs that installer — so a bootstrapped
machine always has a vendor skill called `openwiki`. Two same-named skills
would make `/openwiki` and model-driven selection ambiguous.

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
| Trigger | This skill, interactively | `openwiki-update.yml` dispatch (cron ships disabled) |

The split matters: initial generation is the expensive pass and the in-chat
lane makes it free, so **init in-chat, then let CI carry the deltas.** Claude
models through the Copilot provider crash the tool — the in-chat lane is the
supported way to run OpenWiki on Claude (see `references/operations.md`).

## What `run.sh preflight` actually refuses

Three things, all mechanical:

- **A dirty tree.** `openwiki --init` rewrites `AGENTS.md` and `CLAUDE.md`
  inside `<!-- OPENWIKI:START/END -->` blocks in the current git root, so an
  init against uncommitted work bundles unrelated files into your next
  commit.
- **An UNKNOWN tree.** `git status` failed — a corrupt index, a broken
  toolchain — so the tree state could not be determined. That refuses too, on
  its own message ("cannot determine tree state"), because a git error read
  as "clean" is the fail-open this probe exists to prevent. Expect rc 1 from
  a corrupt index, not a pass.
- **A missing CLI.** `scripts/bootstrap-machine.sh` installs the pinned CLI
  and runs `openwiki integrations install claude`.

Everything else in this file is guidance the wrapper does NOT enforce —
notably MCP wiring (reported by `status`, never gated) and the
never-vendor-the-installer's-files rule. `run.sh` only probes and refuses; it
does not wrap the generation itself, so both real entry points (the MCP tool
in-chat, `openwiki code --update` in CI) can bypass it. Run `preflight`
first; nothing forces you to.

The MCP server is read at session start, so a freshly wired install is usable
in the NEXT session, not the current one.

## Steering the generator

Corrections go in `openwiki/INSTRUCTIONS.md` — a standing brief re-read every
run. Hand-edits to generated pages are reverted by the update loop, so a fix
applied to a page is lost while the same fix phrased as a durable rule in
INSTRUCTIONS.md persists. Phrase entries as rules, not one-off patches.
`scripts/bootstrap-repo.sh` seeds a starter INSTRUCTIONS.md.

## Wiring a repo

`scripts/bootstrap-repo.sh <target-dir>` seeds the whole lane
**unconditionally** — both workflows, the pinned toolchain and lockfile, and
a starter `openwiki/INSTRUCTIONS.md`. There is no opt-in flag because there
is nothing to opt out of: `openwiki-update.yml` ships with no schedule
trigger, and `notify-wiki-hub.yml`'s job is gated on `vars.WIKI_HUB_REPO`, so
neither runs until the repo deliberately arms it.

Arming a repo is three separate decisions:

1. Uncomment the cron in `openwiki-update.yml` (and stagger the day across
   repos — one credit pool).
2. Set the secrets (`references/operations.md` names them and the token-type
   trap).
3. Optionally set `OPENWIKI_AUTO_MERGE=true` — deliberately separate from
   the cron, because these PRs can rewrite `AGENTS.md`/`CLAUDE.md`, the
   standing instructions later agent sessions read.

## Commands

```bash
skills/openwiki-lane/run.sh status      # CLI version, MCP wiring, repo init state
skills/openwiki-lane/run.sh preflight   # refuse-if-unsafe gate before an init/update
skills/openwiki-lane/run.sh doctor      # status + preflight + remediation hints
```

## Auto-continue

- **`status` shows CLI missing or MCP unwired** → run `scripts/bootstrap-machine.sh`, then restart the session so the MCP server loads
- **`preflight` refuses on a dirty tree** → commit or stash first; never `--init` over uncommitted work
- **First generation needed** → run the in-chat MCP lane (free), not the CI lane
- **Generated page is wrong** → add a durable rule to `openwiki/INSTRUCTIONS.md`; do NOT edit the page
- **Repo should self-update** → `scripts/bootstrap-repo.sh <target>`, then arm the three decisions above
- **Blocked** → read `references/operations.md`; the eight gotchas cover every failure seen so far
