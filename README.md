# claude-workflow-core

Damien Adams' Claude Code plugin — **portable workflow skills + session-resilience hooks** shared across multiple repos (media-server, pricing-team-toolkit, etc.).

**Marketplace + plugin in one repo** (per Claude Code's standard pattern, see `.claude-plugin/`).

## What's in the plugin

The current canonical version is the `version` field in `.claude-plugin/plugin.json` (SSOT — see GitHub Releases / CHANGELOG for per-version notes). The inventory below tracks the SHAPE of the plugin (skills + hooks), not version-specific deltas, so the document doesn't rot every release.

### Skills (19 total)

**Ship-PR workflow** — extracted from homelab and FCP toolkit where they were duplicated:

| Skill | Purpose |
| --- | --- |
| `git-commit` | Conventional Commits + project schema, Copilot-assisted draft |
| `github-issue-creation` | Read template + label + milestone + ai-triage + board-sync per repo |
| `github-epic-creation` | Parent epic + N sub-issues with `addSubIssue` GraphQL linkage |
| `github-pr-creation` | Branch + PR open + body-from-template + Copilot draft |
| `github-pr-review` | Multi-agent local review (Phase 0/1/2) wrapper |
| `github-pr-merge` | Verifier + user gate + post-merge housekeeping |
| `session-start` | Memory check + board state + open PRs + Renovate dashboard + git state |
| `ship-pr-cycle` | Drive the staged local review pipeline (Phase 0.5 → 1 → 2 → push → CR-in-CI → merge) as a state machine — the canonical entry point (#130) |
| `cr-resolve-conflict` | Resolve PR merge conflicts against the base branch |

**Meta + workflow primitives (v0.2.0 baseline)**:

| Skill | Purpose |
| --- | --- |
| `ack` | Batch-acknowledge pending hook-ack entries |
| `brainstorm` | Structured Problem/Options/Tradeoffs/Recommendation discussion mode |
| `creating-skills` | Meta-skill: how to write SKILL.md (Anthropic-style) |
| `deep-audit` | N parallel agents + triple-check, fix-in-place |
| `memory-consolidate` | Dedupe + merge memory files |
| `retro` | Session retrospective from `.claude/session-log.jsonl` |
| `prove-yourself-audit` | Mechanical enforcement of the prove-yourself rule |
| `cr-plan` | CodeRabbit Issue Planner parser → epic + sub-issues |
| `openwiki-lane` | OpenWiki generated-docs lane — free in-chat MCP generation vs metered CI deltas, preflight refusals, the INSTRUCTIONS.md steering channel |
| `bootstrap-repo` | Seed a new or existing repo with the canonical SSOT (hooks, configs, templates) from the plugin |

### Session-resilience hooks (3)

| Hook | Event | Purpose |
| --- | --- | --- |
| `pre-compact-flush.sh` | `PreCompact` | Snapshot session log + state before `/compact` summarization |
| `persist-session-state.sh` | `PostToolUse` | Write current PR/branch/cmd to `.claude/.session-state/` |
| `restore-session-state.sh` | `SessionStart` | Surface `additionalContext` from .session-state on resume |

All hooks use `git rev-parse --show-toplevel || pwd` so they work in any cwd.

## ship-pr-cycle is the canonical entry point (#130)

`scripts/ship-pr-cycle.sh` is the **single end-to-end orchestrator** for the inner ship cycle. Every other skill in this plugin (`github-issue-creation`, `github-pr-creation`, `github-pr-merge`, `git-commit`, `coderabbit:autofix`, etc.) is an **internal building block** that ship-pr-cycle invokes at the appropriate stage.

Per `scripts/ship-pr-cycle.sh` (the `# Stages (state.stage):` header block), the current canonical state machine is:

- **branch-ready** — ≥1 commit ahead of `BASE_BRANCH`; meta-bootstrap feature-branch verify (#122) gates pre-work
- **phase0.5** — Copilot prefilter
- **phase1** — Claude Phase 1 review rounds (cap from scaler tier)
- **phase2** — CR-CLI review loop (cap from scaler tier)
- **push** — pre-push pipeline gate + local pr-lint mirror (#119/#127); `github-pr-creation` enforces label gates (#118/#120/#121)
- **cr-in-ci-wait** — wait for server-side CodeRabbit on the open PR
- **auto-triage** — classify CR threads via `scripts/cr/auto-triage.sh` (#733); routes by unresolved-thread count
- **cr-autofix** — apply actionable CR findings via `coderabbit:autofix`, then loop back to phase1 for delta re-review
- **cr-thread-reply** — reply-with-evidence to verified-fixed / false-positive / rejected threads (#2548); UNADDRESSED and STRANDED threads block, `replied-awaiting-CR` passes through. Stranded (unresolved + outdated) is not repliable — resolve it via `scripts/cr/resolve-stranded.sh`
- **cr-conflict-check** — route a DIRTY PR through CodeRabbit's resolver before the gate (#190); CLEAN PRs pass straight through
- **merge-gate** — operator approves here — unless `MERGE_GATE_AUTO=1` and the PR is provably green (#2549), which arms native auto-merge instead
- **merged** — terminal

**Note on upstream chains:** `brainstorm` → `cr-plan` → `github-epic-creation` is a **parallel workflow that runs BEFORE ship-pr-cycle** (per `scripts/ship-pr-cycle.sh:9-14`: "cr-plan is a PARALLEL workflow... No auto-fire from ship-pr-cycle into cr-plan — they are disjoint by design"). As of v0.17.0 (#125), `ship-pr-cycle.sh epic <trigger|parse> <num>` provides a thin single-entrypoint dispatch over `cr-plan trigger` + `cr-plan parse` — no new state machine stages, no auto-fire. The brainstorm step itself stays operator-interactive (operator files a `brainstorm.yml` issue, picks A/B/C), then the dispatch sequences the post-brainstorm chain.

The mirror-map at `.github/ship-pr-cycle-mirror-map.yml` is the SSOT for "which server-side workflow has a local mirror at which stage" (#129). The mirror coverage telemetry helper landed in v0.16.0 (#131) — invoke via `scripts/ship-pr-cycle.sh mirror-report`.

## Local-mirror-of-pr-lint chain (#118)

Server-side workflow gates (`.github/workflows/pr-lint.yml`, `pr-labeler.yml`) have local mirrors that fire BEFORE the change reaches GitHub. The goal: when a PR lands in GitHub, the only remaining issues are CR findings — never label/body/branch-name regressions that should have been caught locally.

| Stage | Local mirror | Server-side workflow it mirrors |
| --- | --- | --- |
| Branch creation | `meta-bootstrap.sh --target feature-branch` | (none; manual) |
| Issue creation | `github-issue-creation/run.sh` (#120 `priority:*` + `area:*` required at create) | (none in this repo; server-side classification is consumer-specific) |
| PR creation | `github-pr-creation/run.sh` + `pr-lint-check.sh` (#119 body validation) | `pr-lint.yml` (Closes/headings/area:*) |
| PR creation | `github-pr-creation/run.sh` (#121 auto-create missing milestone) | (none; manual UI step) |
| PR creation | `github-pr-creation/run.sh` (#122 calls feature-branch verify) | (none; manual) |
| Pre-push | `hooks/pre-push-pipeline-gate.sh` (Phase 0.5/1/2 evidence) | (none; advisory) |
| Turn end | `hooks/next-task-stop-nudge.sh` (#2555 next open task) | (none; session-local) |
| Every tool call | `hooks/task-queue-track.sh` (#2555 stale `in_progress` item) | (none; session-local) |
| Post-commit | `hooks/task-issue-reconcile.sh` (#2555 commit vs task list) | (none; session-local) |

### Task-queue nudges (#2551)

Three hooks keep the task list honest, each routed through `hook-ack` so the
next tool call is denied until the diagnostic is Read — the same mechanism the
lint and pipeline gates use, rather than advisory output that scrolls past:

- **next open task** — a turn ended with work still open. Names the next
  actionable item, resuming an `in_progress` one before starting a `pending`.
- **stale item** — something has been `in_progress` for `TASK_STALE_AFTER_CALLS`
  tool calls (default 40) with no status update. Fires once per item and
  re-arms only after the next update.
- **commit vs task list** — a commit referencing `#NNN` landed and the open-item
  set is unchanged since the previous commit.

They never fire on a conversational turn, an empty queue, or a `blocked` item.
Detection fails open (a parse error is silent); enforcement is the shared gate
and fails closed.

**Override paths** (all `=1` to bypass; the first three are audit-logged to
`.claude/logs/dogfood-gate-skip.jsonl`):
- `ISSUE_LABELS_REQUIRED_SKIP=1`
- `PR_BRANCH_VERIFY_SKIP=1`
- `PR_MILESTONE_AUTO_CREATE_SKIP=1`
- `TASK_NUDGE_SKIP=1` — disables all three task-queue nudges above. **Not**
  written to that jsonl: each hook emits an audit line to **stderr** while it
  is set, so a toggle left on weeks ago still says why the nudges went quiet.

## Installation

```bash
# 1. Add the marketplace (one-time per machine)
/plugin marketplace add repbyrepdev/claude-workflow-core

# 2. Install the plugin
/plugin install claude-workflow-core@claude-workflow-core
```

After install, skills are available under the `claude-workflow-core:` namespace.

## Per-repo customization

Skills carry homelab-flavored notes in some areas (e.g. `github-pr-merge` Step 8-10 about Docker recreate / Fusion e2e tests). These are illustrative — adapt or skip per your repo:

- **homelab** (`repbyrepdev/plex_arr_media_stack`) — full chain including docker recreate, e2e, tag+release
- **FCP toolkit** (`FCP-Euro-Pricing-Team/pricing-team-toolkit`) — skip Steps 8-10 (no docker; promotion to upstream is manual via Catalog UI)

If divergence becomes problematic, future v0.x can split content into `recipes/<repo>.md` overlays.

## Coming in v0.4 - v0.7

| Version | Content |
| --- | --- |
| v0.4 | 15 generic pre-commit-hooks + `.pre-commit-hooks.yaml` for gold-standard pre-commit `repo:` consumption |
| v0.5 | 18 `_lib/` helpers |
| v0.6 | ~40 generic `.claude/hooks/` (Phase 0.5/1, lint-gate, memory-guard, etc.) |
| v0.7 | Portable scripts (try-free.sh, board helpers); canonical version both consumers pin to |

See FCP toolkit issue [#22](https://github.com/FCP-Euro-Pricing-Team/pricing-team-toolkit/issues/22) for the full unification roadmap.

## Versioning + rollback

Plugin versions are tagged: `v0.1.0`, `v0.2.0`, `v0.3.0`. See `ROLLBACK.md` for recovery if a release breaks a consumer.

## Release runbook (closes #77)

Cutting a new plugin release. Five mechanical gates from epic #86
enforce the version-bump discipline + drift surface — follow this
runbook and the gates do the rest:

### 1. Bump `.claude-plugin/plugin.json`

```bash
tmp=$(mktemp) && jq '.version = "X.Y.Z"' .claude-plugin/plugin.json > "$tmp" && mv "$tmp" .claude-plugin/plugin.json
```

The mechanical gates that fire on commit:

- **`commit-subject-version-gate`** (#74) — `commit-msg`-stage gate.
  If your commit subject uses `feat(vX.Y.Z): …` scope syntax, the
  X.Y.Z **must not exceed** `plugin.json.version`. Bump first, then
  commit. Bypass: `COMMIT_SUBJECT_VERSION_SKIP=1` (audit-trail
  stderr only).

- **`plugin-version-bump-gate`** (#87) — pre-commit gate. Any
  staged change under `hooks/` requires a matching `plugin.json`
  version bump. Bypass: `PLUGIN_VERSION_BUMP_SKIP=1`.

### 2. Commit

Use the conventional-commits subject form. Squash-merge to main.

```bash
git commit -m "feat(vX.Y.Z): <one-line summary>"
```

The pre-commit hooks validate the subject + plugin.json + bats
coverage as one atomic step.

### 3. Cache packaging — auto on merge

Once the bump merges to main:

- **`post-merge-release-fire` hook** (#88) — git post-merge hook.
  Detects `plugin.json.version` change vs first-parent baseline.
  Auto-fires `scripts/release.sh` detached (setsid+nohup on Linux,
  nohup on macOS), logs to `.claude/logs/release-auto-fire.jsonl`
  with status (`fired` / `fired-first-introduction` /
  `no-version-change` / `missing-release-sh`).
  When `ACTIONS_MODE=remote` (configured in `.claude/mode.conf` —
  defaults to `local` if absent, set explicitly to opt out of the
  local hook), the hook no-ops; a `.github/workflows/release.yml`
  is **not yet implemented** (tracked as a follow-up under epic
  #86). Remote-mode operators today must use the manual fallback
  (step 6 below) until that workflow ships.

The post-merge hook wiring is **NOT** auto-installed today. Add the
snippet from the header of `hooks/post-merge-release-fire.sh` to
`.git/hooks/post-merge` manually (one-time per checkout). Auto-wire
via `install-machine.sh` is tracked as a follow-up.

### 4. Verify cache populated

```bash
# Tail the audit log first — looks for a "fired" status on the merge SHA.
tail -1 .claude/logs/release-auto-fire.jsonl | jq .

# Then verify the cache dir appeared.
ls ~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/X.Y.Z/
```

Runtime depends on `scripts/release.sh` (tag creation + cache copy
+ optional GitHub release upload) — typically seconds to a minute,
but no SLA. If the cache dir is missing after a few minutes:

- Confirm a `fired` (or `fired-first-introduction`) JSONL entry
  exists for the merge SHA
- Check `.claude/logs/release-auto-fire-X.Y.Z.log` for the
  detached `scripts/release.sh` output

### 5. Session-start drift detector (#89)

After the cache update, your next Claude Code session triggers
`session-start-stale-pin.sh` if `~/.claude/settings.json` still
references the old version. Run the suggested
`scripts/migrate-settings.sh` to update settings to the new cache
dir.

### 6. Manual fallback

If the post-merge hook didn't fire (operator on a fresh clone
without `install-machine.sh` run yet):

```bash
scripts/release.sh
```

`scripts/release.sh` is idempotent — re-runs skip tag/cache/release
when each is already in place. See `scripts/release.sh --help`.

### Content-drift check (#90)

After ship, run on a consumer repo:

```bash
scripts/hash-drift.sh --verify
```

Compares `.claude/hooks/*.sh` + `.claude/_lib/*.sh` against the
plugin's `.source-hashes.json`. Drift → exit 1 with per-file
report + remediation pointer to refresh-from-source OR add to
`.claude/local-overrides.yml`.

## Verification

The plugin self-verifies through three layers:

| Layer | Mechanism | What it checks |
| --- | --- | --- |
| **Bootstrap parity** | `.github/workflows/plugin-self-bootstrap-verify.yml` | The plugin can bootstrap itself — generated artifacts match the committed ones |
| **Content drift** | `scripts/hash-drift.sh --verify` | Consumer `.claude/hooks/*.sh` + `.claude/_lib/*.sh` match the plugin's `.source-hashes.json` |
| **Claim drift** | `pre-commit-hooks/check-ssot-drift.sh` (active via `.claude/ssot-checks.yml`) | Numeric / list claims in prose match their SSOT file |

The `.bats` suite is the primary behavioral verification — run `scripts/test-touched.sh` for the iteration loop, `scripts/test.sh` for the full pass. (No hardcoded file count: it would drift every time a test is added.)

There are 4 required status checks, declared with their names in `.github/required-checks-list.yml` (SSOT) and count-validated by the `required-checks-count` drift check above.

## Consumers

| Repo | Status |
| --- | --- |
| `repbyrepdev/plex_arr_media_stack` | Migration to plugin v0.7.0 tracked in [#22-PR6](https://github.com/FCP-Euro-Pricing-Team/pricing-team-toolkit/issues/28) |
| `FCP-Euro-Pricing-Team/pricing-team-toolkit` | Migration tracked in [#22-PR7](https://github.com/FCP-Euro-Pricing-Team/pricing-team-toolkit/issues/29) |
