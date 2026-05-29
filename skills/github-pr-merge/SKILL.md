---
name: github-pr-merge
description: Merges GitHub Pull Requests after CodeRabbit-clean check + unresolved-review-threads check + explicit user confirmation. Use when the user wants to merge / close / finalize / approve + merge / ship a PR. Trusts CI for gate rules (v3.23.H made branch protection authoritative on 5 required status checks; v4.1 promoted CodeRabbit to the 6th required check — don't re-enumerate them in this skill).
---

# github-pr-merge

## Preferred entry point (v4.20 #519): `run.sh` wrapper

Invoke `.claude/skills/github-pr-merge/run.sh` for the full flow
(mergeable + FAILED-check + stranded-thread validation → merge → post-merge
pull → optional tag + auto-release.sh invocation). Sets `SKILL_WRAPPER=1`
so skill-bypass-guard honors the internal `gh pr merge` call.

```bash
.claude/skills/github-pr-merge/run.sh --pr <num> \
  [--squash|--merge|--rebase] [--delete-branch|--no-delete-branch] \
  [--tag vX.Y.Z]
```

The inline flow below is the **pre-v4.20 manual path**. Prefer the wrapper
for routine merges; fall back to inline steps only when debugging or when
the wrapper's options don't cover a specific case.

---

Verifier + user gate. Branch protection enforces the required status checks defined in `.github/required-checks-list.yml` (SSOT; v4.4.A — was previously restated inline here) — GitHub blocks merge itself if any fail. CR promoted to required because v4.1's local-review pipeline (see `github-pr-creation` skill Step 0) runs CR's engine locally before push; anything CR-in-CI finds after that is a regression in the local pipeline, not just advisory noise. Exact GitHub check name: `CodeRabbit` (verified via `gh pr checks <PR> --json name` — capitalized, no namespace prefix).

This skill runs a presence + state sanity check (Step 2) as belt-and-suspenders — GitHub's gate is authoritative, but a transient `SKIPPED` or a missing required workflow can pass GitHub's MERGEABLE state while the gate wasn't really evaluated. The skill still only handles what CI can't gate: unresolved review threads and your explicit go-ahead.

## Current PR

Run on demand to surface PR state before invoking the wrapper:

```bash
gh pr view --json number,title,state,mergeStateStatus,mergeable
```

(Previously a `!`-prefix context-injection directive, but nested-quote jq filters trip the Skill-tool loader's eval — see #739.)

## Flow

### 1. Summary fetch

```bash
PR=$(gh pr view --json number -q '.number')
gh pr view "$PR" --json number,title,state,mergeable,reviewDecision,statusCheckRollup,mergeStateStatus
```

Confirm `state=OPEN`, `mergeable=MERGEABLE`, `mergeStateStatus=CLEAN`. If `BLOCKED`/`UNSTABLE`/`BEHIND`, report what's blocking and halt.

### 2. Required-check verification

Branch protection enforces these, but sanity-check before committing to merge — a transient `SKIPPED` on a required job leaves the PR mergeable to GitHub but is worth surfacing. v4.1 CR #359: must verify both state AND presence — if a required check never fired (missing from payload), GitHub may still show MERGEABLE, but the gate wasn't actually evaluated.

```bash
# v4.4.A: read the required-check names from the SSOT file, not hardcoded.
# `.github/required-checks-list.yml` is the single declaration consumed by
# this skill, the branch-protection restore command in issue #366, and
# `.claude/hooks/run-required-checks.sh`.
REQUIRED_CHECKS=$(yq -r '.required[].check_name' .github/required-checks-list.yml | tr '\n' ' ')
PAYLOAD=$(gh pr checks "$PR" --json name,state)

# Presence check first — every required name must exist in the payload
for name in $REQUIRED_CHECKS; do
  if ! echo "$PAYLOAD" | jq -e --arg n "$name" '.[] | select(.name == $n)' >/dev/null; then
    echo "HALT: required check \"$name\" missing from payload — workflow didn't fire" >&2
    exit 1
  fi
done

# State check — now safe to group, since all required names are known present.
# v4.4.A: jq filter is built at run-time from the required-checks list so no
# name is hardcoded here either.
NAME_FILTER=$(yq -r '.required[].check_name' .github/required-checks-list.yml | \
  awk '{printf "\"%s\",", $0}' | sed 's/,$//')
echo "$PAYLOAD" | jq "
  map(select(.name | IN(${NAME_FILTER})))
  | group_by(.state) | map({state: .[0].state, count: length})"
```

Halt if any required check is `FAILURE`, `CANCELLED`, or `SKIPPED`. v4.1: `CodeRabbit` is now in this set — if CR fails, do not proceed. A failing CR check after a clean local review pipeline means the local pipeline missed a finding; fix the finding locally + note which specific Phase 1 agent should have caught it for next-iteration tightening.

### 3. CodeRabbit cleanliness

CR is a required blocking status check as of v4.1 (enforced via branch protection — see `.github/required-checks-list.yml`). Before surfacing the merge gate, independently verify no unresolved CR review threads — the required-status check covers CR's summary verdict but stranded review threads (outdated-not-resolved) can still exist. Run the helper:

```bash
.claude/hooks/_pr-cr-findings.sh "$PR"
```

Exit 0 = clean — ALL three buckets zero:
- **Unresolved current threads** (on HEAD) — must be addressed in code.
- **Stranded outdated threads** (`isResolved=false` + `isOutdated=true`) — v4.0 CR #354 lesson: CR's auto-resolve is imperfect. A fix may land but CR's heuristic misses the correlation, leaving the thread formally unresolved even as GitHub marks it outdated. "Outdated ≠ resolved" — skipping these hid a near-miss past an unaddressed finding. If any stranded thread appears, **explicitly resolve via GraphQL** after confirming the fix is live:

```bash
# The helper prints each stranded thread's thread_id. Resolve with:
gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: "PRRT_xxx"}) { thread { isResolved } } }'
```

- **Walkthrough Pre-merge failures** (hard `❌` count from CR's walkthrough summary comment; warnings are informational).
- **Outside-diff-range findings** (v4.1 CR #359 gap): CR can't anchor to lines not in the diff, so it embeds them in the review body under `## Outside diff range comments (N)`. The helper extracts and sums these. v4.2.A locked this in as a regression test: `.claude/hooks/tests/test_pr-cr-findings.sh` exercises the helper via `CR_TEST_MODE=1` with fixtures under `.claude/hooks/tests/fixtures/` — a review body with `Outside diff range comments (2)` must produce `TOTAL needing cleanup: 2` and exit 1. Run the tests after any helper edit.

Non-zero exit halts. The `CodeRabbit` status check in branch protection is the required blocking gate (v4.1) — GitHub won't merge until CR posts its review. But the status-check pass/fail signals "review complete", not "findings=0". This helper is what counts findings + blocks on a non-zero total; repo policy ("any CR finding = local pipeline regression — fix + tighten") depends on the helper running. Don't skip it. Do NOT paper over stranded threads — manually resolving them IS the cleanup, not a workaround.

### 4. Unresolved review threads (human reviewers)

```bash
gh api "repos/$(gh repo view --json nameWithOwner -q '.nameWithOwner')/pulls/$PR/reviews" \
  --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length'
```

> 0 halts — someone's explicit change-request hasn't been resolved.

### 5. User confirmation GATE

Present a one-line summary:

```
✓ all required checks green (per `.github/required-checks-list.yml`) · ✓ no unresolved threads · Ready to merge?
```

**Wait for the user to type `go` / `merge` / `ship it` / equivalent.** Silence is not consent; partial answers ("looks good") are not consent. Re-ask if ambiguous.

### 6. Merge

```bash
# v4.5.E: --delete-branch is NON-NEGOTIABLE. delete-branch-on-close.yml is
# disabled during the Actions cap (#366), so without this flag the remote
# branch lingers until someone remembers to `git push origin :branch-name`.
gh pr merge "$PR" --squash --delete-branch
```

### 7. Post-merge housekeeping

```bash
git checkout main
git pull --ff-only
git remote prune origin
```

v4.5.E + v4.6.B: during the GitHub Actions cap (#366), ALL repo workflows are `disabled_manually` at the repo level (verify with `gh workflow list --all`) — this is the repo-state toggle, not an `if: false` guard inside the YAML. So `auto-close-parent.yml` and the Status=Done sync inside `project-automation.yml` don't fire on merge, even though their YAML jobs still have active `if:` conditions. Built-in Projects workflow usually handles Status=Done on close, BUT v4.0 memory says it's observed to miss issues closed via `Closes #N`. Fire BOTH explicitly for every closed sub-issue (v4.6.B belt-and-suspenders):

```bash
# Each `Closes #N` in the PR body became a closed issue on merge.
# Iterate them; fire Status=Done explicitly + fire auto-close-parent.
for n in $(gh pr view "$PR" --json closingIssuesReferences -q '.closingIssuesReferences[].number'); do
  .claude/local-backups/project-board-sync.sh --on-close "$n"  # v4.6.B
  .claude/hooks/auto-close-parent.sh "$n"
done
# Also fire --on-close on the PR itself (built-in usually does, belt+suspenders)
.claude/local-backups/project-board-sync.sh --on-close "$PR"
```

This mirrors `auto-close-parent.yml`'s behavior — epic auto-closes when its last sub-issue closes, Status=Done applied on the board. Idempotent: if the parent was already closed or still has open sub-issues, the helper no-ops.

`pr-close-prune.sh` PostToolUse hook also runs `git fetch --prune` automatically — no need to duplicate.

### 8. Post-merge DEPLOY — merging is NOT deploying

**v4.0 lesson (2026-04-19):** I shipped v4.0 by merging + tagging + running the release workflow and declared it "done" while the running containers were still on pre-v4.0 compose pins (mem_limit=0, ports on `0.0.0.0`, byparr `:main`, alert rules missing). Code on main ≠ changes on the box. Running system stays at the PRE-merge compose state until explicit recreate. Do not skip this step ever.

Classify the PR's diff to decide what to recreate:

```bash
# Resolve the exact merge commit SHA from the PR — deterministic regardless of
# other merges racing into main after yours. CR #357: `HEAD~1` on a busy main
# can point at someone ELSE's merge, diff-ing the wrong baseline and missing
# (or over-stating) the stacks that need a recreate.
MERGE_SHA=$(gh pr view "$PR" --json mergeCommit --jq '.mergeCommit.oid')
# Which stacks did this specific merge actually touch? (alphabetical set — dep order applied below)
TOUCHED=$(git diff "${MERGE_SHA}^" "$MERGE_SHA" --name-only -- 'stacks/*/compose.yaml' | awk -F/ '{print $2}' | sort -u)
# Compose + config + script changes that need a deploy (informational)
git diff "${MERGE_SHA}^" "$MERGE_SHA" --name-only -- 'stacks/**' 'config/**' 'scripts/maintain.sh' 'scripts/restore.sh'
```

If `TOUCHED` is non-empty (compose changed), recreate in dependency order. Don't just `for s in $TOUCHED` — that's alphabetical and breaks cross-stack deps (e.g. SWAG must come up AFTER authelia is healthy, or it serves 502s). The canonical order is restore.sh Step 5's `STACKS=(authelia swag aiostreams stremthru prowlarr nzbhydra2 byparr dispatcharr loki prometheus prometheus-exporters grafana homepage uptime-kuma dozzle docker-event-monitor logporter)` — iterate THAT list and skip anything not in `TOUCHED`.

**v4.7.D (#411) — trivy post-merge CVE scan.** If any compose image changed (new pin OR digest bump), run the local Trivy replica to scan the newly-introduced image(s). Matches `trivy-post-merge.yml` semantics; opens a `priority:p1 auto:trivy-post-merge` issue on HIGH/CRITICAL. No-ops when `ACTIONS_MODE=remote` (workflow handles it).

```bash
# Diff against the pre-merge SHA; script picks up new image pins automatically.
.claude/hooks/trivy-post-merge.sh "${MERGE_SHA}^"
# Exit 0 = clean or no-new-images; exit 1 = issue filed for CVEs; exit 2 = scan
# tooling error (rare — check docker daemon / trivy image pull).
```

```bash
# Pre-deploy snapshot — capture state BEFORE the recreate so the post-diff is meaningful
docker ps --format '{{.Names}} {{.Image}} {{.Status}}' | sort > /tmp/pre-deploy-ps.txt
docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | sort > /tmp/pre-deploy-stats.txt

# Dependency-ordered recreate — authoritative order from restore.sh Step 5
DEPLOY_ORDER=(authelia swag aiostreams stremthru prowlarr nzbhydra2 byparr dispatcharr loki prometheus prometheus-exporters grafana homepage uptime-kuma dozzle docker-event-monitor logporter)
for s in "${DEPLOY_ORDER[@]}"; do
  # Skip stacks not touched by this merge
  grep -qx "$s" <<<"$TOUCHED" || continue
  docker compose --env-file config.env -f "stacks/$s/compose.yaml" up -d --force-recreate
done

# Wait for health to settle (60-90s typical)
# Verify the SPECIFIC changes that shipped actually took effect — not just "healthy"
# Examples, adjust per PR scope:
#   * v4.0.A resource limits → `docker inspect <c> --format '{{.HostConfig.Memory}}'` must be >0 for every container
#   * v4.0.C 127.0.0.1 bindings → `lsof -iTCP:9090 -sTCP:LISTEN` should show `localhost:` not `*:`
#   * v4.0.C byparr digest pin  → `docker inspect byparr --format '{{.Config.Image}}'` should contain `@sha256:`
#   * v4.0.E new scrape targets → `curl /api/v1/targets | jq '.data.activeTargets | length'` matches expected
#   * v4.0.E new alert rules   → `curl /api/v1/rules` includes expected alert names
#   * v4.0.G node_exporter textfile → `curl node_exporter:9100/metrics | grep homelab_maintain_` should appear after first nightly
```

**v4.11 #452/#453 — run the drift detector AFTER recreates as the canonical "deploy matches main" assertion.** Per-change checks above prove individual features landed; the detector proves no stack was missed. Anchor case: Renovate auto-merge of stremthru #421 left the container on the old pin for 8h until manual recreate — the detector would have surfaced that at session start.

```bash
.claude/hooks/check-deploy-drift.sh
# Exit 0 = every running container matches its compose.yaml image pin.
# Exit 1 = drift listed — recreate the named stack(s) before declaring deploy done.
# Exit 2 = tooling unavailable (docker daemon down, yq/docker missing). Deploy
#         verification did NOT run — DO NOT declare deploy done. Investigate the
#         missing tool/daemon, restore it, re-run the hook. If blocked, mark
#         the deploy as requiring manual verification before proceeding.
```

If config-only changes (e.g. `prometheus.yml.enc`, `alert_rules.yml.enc`, `alertmanager.yml.enc`, `authelia/configuration.yml.enc`, `loki/encrypted/alerts.yml.enc`), run the decrypt-THEN-reload dance maintain.sh does nightly. CR #357: **decrypt BEFORE reload** — `/-/reload` re-reads the plaintext on disk, so if you skip the decrypt step, Prometheus reloads the stale plaintext unchanged and the deploy is a no-op.

```bash
# Step 1 — decrypt the affected .enc files. For ad-hoc post-merge deploys,
# source maintain.sh's helper OR call age/sops directly on the specific
# files that changed (see scripts/maintain.sh `decrypt_all_configs()`).
#
# Platform note (CR #357): this runbook uses macOS Keychain via `security
# find-generic-password` — same as scripts/maintain.sh + restore.sh. The
# entire deploy target for this repo is a single Mac Mini, so cross-platform
# portability is not a goal here. On a hypothetical Linux relocation, swap
# the `security ...` line for `AGE_KEY=$(cat "$SOPS_AGE_KEY_FILE")` with
# the age-identity path set per the user's keyring tool (pass/gpg/etc.).
# Example for Prometheus plus Alertmanager (plain age YAML):
AGE_KEY=$(security find-generic-password -a "$USER" -s sops-age-key -w)
for cfg in config/prometheus/prometheus.yml config/prometheus/alert_rules.yml config/alertmanager/alertmanager.yml; do
  [ -f "${cfg}.enc" ] || continue
  echo "$AGE_KEY" | age -d -i - "${cfg}.enc" > "$cfg"
  chmod 600 "$cfg"
done

# Step 2 — signal the running services to re-read the refreshed plaintext.
# `-m 3` timeout so an unhealthy endpoint can't hang the runbook.
curl -fsS -m 3 -X POST http://127.0.0.1:9090/-/reload   # Prometheus
curl -fsS -m 3 -X POST http://127.0.0.1:9093/-/reload   # Alertmanager
# Authelia has no /-/reload — requires `docker compose up -d --force-recreate authelia`.
# Loki accepts SIGHUP — `docker kill --signal SIGHUP loki` if its config changed.
```

### 9. Post-deploy end-to-end verify — Fusion is the real test

Containers "healthy" per healthcheck ≠ the stack is doing its job. This repo's whole purpose is feeding Fusion (Stremio-fork). After any deploy that touches aiostreams / stremthru / prowlarr / byparr / swag / authelia:

1. **Ask the user to do a search in Fusion** (any title). Wait for them to confirm.
2. Tail the recent logs across the chain in a short window (last 3-5 min):

```bash
for c in swag authelia aiostreams stremthru prowlarr byparr; do
  echo "=== $c ==="
  docker logs "$c" --since 3m 2>&1 | tail -15
done
```

1. Verify the expected shape:
   - aiostreams: identified title via IMDb ID, N addons fetched, streams returned (non-zero)
   - stremthru: pulled torrents for `sid=tt...`, realdebrid hash-check duration reasonable (<2s per call)
   - prowlarr: `Searching indexer(s)` line for the search term
   - byparr: `200` / `301` on `/docs` or similar (serving CF-bypass requests from prowlarr's IP)
   - swag: nothing alarming (no 502/504)
1. Some addon timeouts are normal upstream noise (13% error rate on 37 aggregator addons is typical). Flag only systemic failures (all addons fail, zero streams returned, DB reconnects, OOMKills).

Gate "deploy done" on a successful end-to-end search. Do NOT declare the PR shipped until this passes.

### 10. Tag + release (only after Step 9 passes)

If the milestone is now fully closed, prompt the user about tagging. Tagging before Step 9 ships broken user-facing state with a version stamp.

**10a. Tag eligibility check.** All three of the following must be true (no standalone `jq` needed — `gh --jq` uses embedded gojq):
- All sub-issues of the milestone closed — check with:

  ```bash
  # Capture command substitution + check exit separately — otherwise a
  # gh auth/network failure yields empty stdout and the `[ -eq 0 ]`
  # check emits a cryptic "integer expression expected" instead of the
  # clear "could not verify milestone state" message below.
  if ! OPEN_COUNT=$(gh issue list --milestone "vX.Y" --state open --json number --jq 'length'); then
      echo "gh issue list failed — cannot verify milestone; fix auth/network and retry" >&2
      exit 2
  fi
  [ "$OPEN_COUNT" -eq 0 ] || { echo "milestone has $OPEN_COUNT open subs" >&2; exit 2; }
  ```

- Step 8 deploy-verify passed — invoke the check directly and require exit 0:

  ```bash
  .claude/hooks/check-deploy-drift.sh || { echo "deploy-verify failed — run health-check + fix drift before tagging" >&2; exit 2; }
  ```

  (v4.22 will add a `.last-run/check-deploy-drift.ts` marker so session-start can surface staleness; until then the live invocation above is the source of truth.)
- Step 9 Fusion e2e passed (user confirmation — still honor-system today; `.last-run/fusion-e2e.ts` marker tracked as v4.22 follow-up)

**10b. Tag + push** (requires user confirmation at each step):

```bash
TAG="vX.Y.Z"
git tag -a "$TAG" -m "$TAG: <one-line summary>

<body from merge-commit message or hand-written>" || { echo "git tag $TAG failed — check: (a) tag already exists (git tag -l $TAG), (b) signing key available, (c) HEAD at intended commit" >&2; exit 2; }
git push origin "$TAG" || { echo "git push failed — tag not on origin; Step 10c will refuse" >&2; exit 2; }
```

(10c's `auto-release.sh` independently re-verifies tag presence on origin via `git ls-remote --tags` and exits 2 with a clear message if the push didn't land — so a silent push failure can't progress to release creation.)

**10c. Release creation — v4.20 (#506):**

When `ACTIONS_MODE=remote`, `.github/workflows/release.yml` fires automatically on tag push; skip this step. When `ACTIONS_MODE=local` (current cap-deferral default as of 2026-04; re-check posture after 2026-05-01 restore window), the workflow is disabled — the local replica must be invoked explicitly:

```bash
# Invokes gh release create with the tag's annotated message as body.
# Auto-no-ops if release already exists (idempotent).
# Auto-skips if ACTIONS_MODE=remote (release.yml is authoritative).
.claude/local-backups/auto-release.sh "$TAG"
```

Optional args:
- `--notes-file <path>` — custom release body (overrides the annotated tag message)
- `--title <string>` — release title (default: the tag name)

The replica's behavior mirrors `release.yml`:
- Verifies tag exists locally + on remote before running
- Defaults body to tag message body (falls back to commit message if the extracted tag body is empty — e.g. lightweight tag or annotated tag with subject only)
- Writes `.last-run/auto-release.ts` on both release-created and release-already-exists paths (not on `ACTIONS_MODE=remote` skip or on failure) — session-start uses this for staleness surfacing.

## What this skill does NOT do

- Define the required status checks (branch protection enforces; Step 2 does a presence+state sanity check against those names but does not re-implement the gate)
- Re-verify per-hook pre-commit state (local hooks already ran at commit-time)
- Auto-merge without explicit user confirmation (never, even for trivial PRs)
- Force-push / amend published commits / rewrite history
- Re-run `pr-review-toolkit` locally (that's a separate skill; run it BEFORE merge decision)

## When to override the halts

- Transient check failure (runner 504, rate-limit, flaky test): `gh run rerun <id>` then retry the skill
- CR rate-limited but previous review was clean: if `latestReviews.commit.oid` is the current HEAD and walkthrough shows "No actionable comments", the skill can proceed — document the rate-limit state in the merge summary to the user
- `CHANGES_REQUESTED` reviews from a human who has since resolved off-channel: ask them to either mark the review dismissed or resolve inline before proceeding

## Auto-continue

- **Merged** → `git checkout main && git pull --ff-only && git remote prune origin`; fire epic auto-close + (during Actions cap) board-sync for each `Closes #N`; if compose/config changed, run the post-merge deploy + verify before declaring done.
- **Merge blocked (BLOCKED / UNSTABLE / BEHIND)** → report the specific blocker; do NOT retry verbatim. A required-check fail = local-pipeline regression: fix it + note which Phase 1 agent should have caught it.
- **Tag eligible (milestone closed + deploy verified)** → prompt the operator before tagging; never tag before post-deploy e2e passes.
