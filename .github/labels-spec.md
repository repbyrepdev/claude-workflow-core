# Labels SSOT promotion rule

**v0.19.0 (#142)** — single document explaining how labels propagate between
the plugin (`claude-workflow-core`) and its consumer repos.

## Two-tier model

The plugin and each consumer repo declare their labels in `.github/labels.yml`.
There are two tiers of labels:

1. **Generic tier (in the plugin's `labels.yml`)** — labels every consumer
   needs because they're tied to behavior the plugin itself ships (priorities,
   types, statuses, plan-me/no-plan, Renovate semver, cross-domain area
   labels). The plugin is the single source of truth for this set.

2. **Domain-extension tier (in each consumer's `local-overrides.yml`)** —
   labels specific to the consumer's domain. Examples: media-server has
   `area:streaming` / `area:monitoring` / `auto:dr-test`; pricing-team-toolkit
   has `area:coalesce` / `area:hex` / `upstream:coalesce`. These never move to
   the plugin because they'd be noise to other consumers.

The consumer's effective `labels.yml` is `plugin's labels.yml + consumer's
local-overrides.yml`. The merge **will be handled** by `label-sync.yml` once
Sub 6 #144 ships; until then, sync is manual via `scripts/bootstrap-repo.sh
--apply-labels` (or `gh label create` per-label).

## Promotion criteria — what belongs in the plugin

A label is generic (plugin tier) if:

- **Tied to skill/workflow behavior shipped by the plugin.** Examples:
  `plan-me` (cr-plan skill), `no-plan` (operator opt-out), `priority:*`
  (ai-triage), `patch`/`minor`/`major` (Renovate dashboard rules),
  `auto:renovate` (Renovate workflow), `auto:trivy-*` (Trivy scan workflows).

- **Cross-cutting and meaningful to every consumer.** `bug`, `enhancement`,
  `epic`, `documentation`, `question` (issue-type taxonomy);
  `status:in-review`, `status:blocked` (workflow state); `area:infrastructure`
  + `area:docs` (everyone has infra + docs).

- **Mechanical enforcement applies.** If the plugin's hooks or workflows
  reference the label by name (e.g. `ai-triage` applying `priority:p2`,
  `cr-plan trigger` looking for `plan-me`), it MUST be declared in the
  plugin's `labels.yml` so it exists on every consumer's GitHub side.

## What stays in consumer local-overrides

- **Domain-specific area labels.** `area:streaming` is meaningful only to
  media-server; `area:coalesce` only to pricing-team-toolkit. Promoting them
  to the plugin would clutter every consumer's label list with irrelevant
  options.

- **Domain-specific automation labels.** `auto:dr-test` (media-server's DR
  rehearsal failures), `auto:restore-sanity` (media-server's backup test),
  `auto:rollback` (media-server's maintain.sh revert) — these reference
  workflows that exist only in the consumer.

- **Cross-domain semantic labels with consumer-specific meaning.**
  `area:security` exists in media-server (Authelia / SOPS / hardening) but
  would mean something different in pricing-team-toolkit (data access /
  PII). Better to declare in each overrides with consumer-tuned descriptions
  than promote a vague generic.

## Cross-repo audit (as of 2026-05-28; counts drift over time)

| Repo | labels.yml count | local-overrides | Notes |
|---|---|---|---|
| `claude-workflow-core` (plugin) | 25 (this file) | n/a — plugin IS the SSOT | `area:plugin-manifest` is plugin-domain; once consumer overrides land (Sub 9), plugin may grow its own overrides file |
| `media-server` | 32 (pre-Sub-6) | 0 — to be created in Sub 9 #147 | Will reduce to `plugin's set + ~12 domain labels` once Sub 9 ships |
| `pricing-team-toolkit` | 30 (pre-Sub-6) | 0 — to be created in Sub 9 #147 | Will reduce to `plugin's set + ~10 domain labels` once Sub 9 ships |

## What ships in #142 (this sub)

- Promote the union-of-generic labels into the plugin's `labels.yml` (25
  labels total, up from 17).
- Document the promotion rule (this file).
- Add bats test asserting plugin's `labels.yml` parses + has the required
  set (mechanical drift catch).
- Bump plugin version 0.18.2 → 0.19.0.

**Deferred to follow-up subs in the v0.19 epic:**

- Sub 6 (#144): `label-sync.yml` workflow that merges plugin's `labels.yml`
  + consumer's `local-overrides.yml` and syncs to GitHub.
- Sub 9 (#147): `local-overrides.yml` schema + media-server / FCP migration
  of domain labels out of their `labels.yml` and into overrides.
- Cross-repo reconciliation of media-server + FCP `labels.yml` against the
  plugin SSOT (happens automatically once Sub 6 ships).

## Adding a new label

1. Decide: does it meet the generic-tier criteria above?
   - **YES** → add to plugin's `.github/labels.yml`. Consumer repos pick it
     up on next `label-sync.yml` run (Sub 6).
   - **NO** → add to the consumer's `.github/local-overrides.yml` (Sub 9).

2. Use the 8-color Primer palette declared at the top of `labels.yml`.

3. Run `scripts/test.sh .claude/tests/github/labels-yml.bats` before
   committing to catch malformed shape (Sub 8 #146 will promote this to
   a dedicated pre-commit hook).

4. Update this file's audit table if the consumer counts shift materially.
