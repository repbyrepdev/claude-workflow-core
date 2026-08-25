# OpenWiki operations — the parts no README states

Source: the MainOfficeMini session that built the OpenWiki stack on
`yahoo_losers_webapp`, `plex_arr_media_stack`, and `repbyrep-wiki`
(handoff: claude-workflow-core#2629, 2026-08-25). Each item below cost a
failed run to learn. This file is the SSOT for them.

## Install

`openwiki@0.4.0` (published 2026-08-25) ships `integrations install claude` —
the in-chat MCP lane — as a first-class command:

```bash
npm i -g openwiki@<pinned>
openwiki integrations install claude
```

Earlier versions could not serve MCP, which forced a pnpm **source build** at
`~/.openwiki-main` plus a hand-repinned command in `~/.claude.json`. That hack
is obsolete; do not reproduce it. If you meet a machine still running it (the
office mini, as of this writing), the fix is the two commands above.

The installer writes `~/.claude/skills/openwiki-lane/` (vendor files with SHA-256
recorded in `.openwiki-install.json`) and the MCP server entry. Never commit
those files into a repo — they are third-party, hash-verified, and regenerated
on install; vendoring them creates silent drift.

## The eight gotchas

1. **The Copilot provider rejects PATs.** `ghp_*` tokens 401. It needs a
   `gho_*` OAuth token — `gh auth login` through the browser, not a PAT. A
   machine whose `gh` is PAT-authed must re-login to mint one. This applies to
   whatever is stored as `COPILOT_API_KEY`.
2. **The model must be enabled in the account's Copilot model policy.**
   `gpt-5.5` returns 400 until it is toggled on in GitHub settings. Enumerate
   what is actually available:
   `curl https://api.githubcopilot.com/models -H "Authorization: Bearer $(gh auth token)" -H "Copilot-Integration-Id: vscode-chat"`
3. **Claude models via the Copilot provider crash OpenWiki.** `claude-sonnet-4.6`
   dies inside `patchToolCallsMiddleware`. Use a GPT-family model for the CI
   lane. This does NOT mean OpenWiki cannot run on Claude — the in-chat MCP
   lane runs on the host agent's own session with no provider key at all,
   which is the supported (and free) way to drive it with Claude.
4. **Headless/CI requires `--print`.** `openwiki code --update --print`.
   Without it a no-TTY run exits after one agent turn ("I'll proceed now" →
   exit). Separately, the interactive first-run setup wizard fires on ANY
   command while `~/.openwiki/.env` is missing — that is expected, not a
   broken install.
5. **`openwiki --init` edits `AGENTS.md` and `CLAUDE.md`** inside
   `<!-- OPENWIKI:START/END -->` blocks, in whatever repo is the current git
   root. Never run it against a dirty tree you are about to `git add -A`: it
   bundles unrelated files into the commit. (An earlier draft of this file
   claimed those two files are byte-SSOT-locked here and that an init trips
   hash-drift/parity gates. That was WRONG — neither appears in
   `.claude/.source-hashes.json` or `PARITY_PATHS`, and this repo has no
   `CLAUDE.md` at all. The bundling risk alone justifies the refusal.)
6. **Never hand-edit generated pages.** The update loop tracks claims state
   and reverts them. The only sanctioned steering channel is
   `openwiki/INSTRUCTIONS.md`, a standing brief the generator reads every run.
   Corrections belong there, phrased as durable rules rather than one-off
   patches.
7. **`GITHUB_TOKEN`-opened PRs never trigger required checks**, so a robot docs
   PR opened with the default token can never satisfy branch protection and can
   never merge. Push/open with a user-OAuth token (stored as
   `OPENWIKI_PUSH_TOKEN`).
8. **Revert watermark-only diffs.** When `.last-update.json` is the only
   changed file, drop it — otherwise every run opens a noise PR. But DO commit
   it alongside real content, or `gitHead` goes stale and later runs re-diff
   the same history.

## Telemetry

The CI lane sets `OPENWIKI_TELEMETRY_DISABLED=1`; openwiki ships vendor
telemetry ON by default (posthog-node is a direct dependency). The in-chat
MCP lane gets no such suppression from us — and that is the lane which reads
the ENTIRE private codebase on a first generation, while CI only ever sees
deltas. If that matters for a private repo, set the same variable in
`~/.openwiki/.env` before the first in-chat run.

## Repo secrets (three, per repo)

| Secret | Used by | Trap |
|---|---|---|
| `COPILOT_API_KEY` | the CI generation step | must be `gho_*` (gotcha 1) |
| `OPENWIKI_PUSH_TOKEN` | the PR-opening step | user OAuth, not `GITHUB_TOKEN` (gotcha 7) |
| `HUB_DISPATCH_TOKEN` | `notify-wiki-hub.yml` | needs dispatch rights on the hub repo |

`repbyrepdev` is a User account, not an org — there are no org-level secrets,
so these are set per repo.

**Scope caveat.** A `gho_*` OAuth token is a whole-ACCOUNT credential, not a
Copilot-scoped one, and `COPILOT_API_KEY` is handed to a third-party LLM CLI
that reads repo content and runs tools. A compromised dependency there, or
repo content that steers the agent, would exfiltrate a credential whose blast
radius is every repo the account can reach. `OPENWIKI_PUSH_TOKEN` is likewise
a user token. Prefer a fine-grained or GitHub App token scoped to the single
repo wherever the provider accepts one.

**Repo settings.** `OPENWIKI_AUTO_MERGE=true` additionally requires the
repo's "Allow auto-merge" setting; without it the arm step errors and reddens
an otherwise-successful docs run.

## Interaction with this repo's merge gates

Since 2026-08-25 the `main-approving-review` ruleset requires one approving
review with **no bypass actors**. A robot docs PR therefore needs an approving
review record, not merely green checks — it cannot self-merge on green alone.
Do NOT assume the approving record arrives on its own. `.github/approval-policy.yml`
records the opposite: PR #2561 ended COMMENTED-only, #2565 produced no record
for the final head, and #2576 sat on a stale CHANGES_REQUESTED until nudged —
which is why the gate carries nudge machinery at all. That nudge lives in the
`github-pr-merge` skill, and `gh pr merge --auto` does NOT go through it, so
an unattended robot docs PR can sit unmerged indefinitely with no remediation
path. Treat auto-merge as "merges if the reviewers happen to act", not as
zero-touch, and check the lane periodically.

## Doctrine worth inheriting

- **One home per fact.** README = stable public front door; `docs/` = authored
  judgment; `openwiki/` = generated code facts. A fact stated twice drifts.
- **Deterministic gates, not LLM opinion.** `tools/check_wiki_facts.py` in the
  yahoo repo is a required check that verifies generated docs against source
  constants by *proximity matching* — the value must appear within 250 chars of
  the constant's name, because plain "appears somewhere" false-passes on
  digits. It also verifies gate job names against the workflow files, so
  renaming a check cannot silently un-gate the repo.
- **Diagrams: decompose, never truncate.** If a diagram has more nodes than
  fit, split it into multiple complete views and link the full interactive
  graph. Capping node count silently lies about the system. Mermaid flowcharts
  use the ELK renderer:
  `%%{init: {"flowchart": {"defaultRenderer": "elk"}}}%%`.
- **Never require a status check whose workflow cannot run.** A required
  context pointing at a disabled or uninstalled producer deadlocks every merge
  in the repo and is nearly invisible in the API. This has bitten two repos.

## Reference implementations

| Repo | What to read it for |
|---|---|
| `repbyrepdev/yahoo_losers_webapp` | `openwiki-update.yml` (cron + dispatch, pinned toolchain, watermark revert), `openwiki/INSTRUCTIONS.md` (brief format), `tools/check_wiki_facts.py`, `tools/wiki_crosslink.py` |
| `repbyrepdev/plex_arr_media_stack` | the same pattern in a consumer repo; its INSTRUCTIONS.md adds "SOPS secrets are never described by value" |
| `repbyrepdev/repbyrep-wiki` | private MkDocs hub behind Cloudflare Access; `tools/build_hub.py`; `.mermaid-toolchain/` — a self-hosted mermaid+ELK bundle, required because Material for MkDocs CDN-loads mermaid and cannot register ELK (flowcharts silently render as blank divs)
