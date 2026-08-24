#!/bin/bash
set -euo pipefail
# event: SessionStart
# SessionStart hook — surface meta-learning status to Claude on session boot:
# recent corrections, drift alerts, degraded hooks, underused skills.
#
# Fires once per session. Must not block; emits summary via additionalContext.
#
# Part of v3.19 meta-learning infrastructure (complements session-start skill
# which is user-invoked; this is passive boot-time context).

# Compact/resume may set cwd outside repo root. If cwd doesn't have a
# .claude/ child, navigate to the script's resolved repo root. Tests that
# pre-cd into an isolated tmpdir-with-.claude/ keep their isolation.
# Use ${BASH_SOURCE[0]} (not $0) so dirname resolves correctly when the
# script is sourced or invoked via a symlink.
if [ ! -d ".claude" ]; then
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; })
	cd "$REPO_ROOT" || exit 2
fi

# Telemetry: log hook run at exit (from _lib.sh)
_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

LOG_FILE=".claude/session-log.jsonl"
ARCHIVE_DIR=".claude/session-log-archive"
HOOK_RUNS=".claude/hook-runs.jsonl"

# Rotate session log if >24h old
if [ -f "$LOG_FILE" ]; then
	mtime=$(stat -f %m "$LOG_FILE" 2>/dev/null || stat -c %Y "$LOG_FILE" 2>/dev/null || date +%s)
	age=$((($(date +%s) - mtime) / 3600))
	if [ "$age" -gt 24 ]; then
		mkdir -p "$ARCHIVE_DIR"
		mv "$LOG_FILE" "$ARCHIVE_DIR/$(date -u +%Y-%m-%dT%H%M%S).jsonl"
	fi
fi

# Collect quick stats
bits=""

# 1. Corrections in last 24h — grep -c exits non-zero when no matches;
# always emit a clean integer, never concatenate "0" + "0" = "00".
if [ -f "$LOG_FILE" ]; then
	recent_corrections=$(jq -r '.signal_type // empty' "$LOG_FILE" 2>/dev/null |
		{ grep -c "^correction$" || true; })
	recent_corrections=${recent_corrections:-0}
	[ "$recent_corrections" -gt 0 ] && bits="$bits
• $recent_corrections correction signals captured last session — consider running /retro"
fi

# 2. Hook health — check last 100 runs, flag hooks with >10% failure rate
# (implements the documented threshold, not just "hooks with >=2 failures").
if [ -f "$HOOK_RUNS" ]; then
	recent=$(tail -100 "$HOOK_RUNS" 2>/dev/null)
	degraded=""
	if [ -n "$recent" ]; then
		for hook in $(echo "$recent" | jq -r '.hook' 2>/dev/null | sort -u); do
			total=$(echo "$recent" | jq -r --arg h "$hook" 'select(.hook == $h)' 2>/dev/null | grep -c '.' || true)
			fails=$(echo "$recent" | jq -r --arg h "$hook" 'select(.hook == $h and .exit != 0)' 2>/dev/null | grep -c '.' || true)
			[ "${total:-0}" -lt 5 ] && continue # <5 recent runs = noise, skip
			if [ "${fails:-0}" -gt 0 ] && [ $((fails * 10)) -gt "${total:-1}" ]; then
				degraded="$degraded $hook(${fails}/${total})"
			fi
		done
	fi
	if [ -n "$degraded" ]; then
		bits="$bits
• Degraded hooks (>10% failure, last 100 runs):$degraded"
	fi
fi

# 3. Unfollowed retro drafts. `|| true` on the pipeline: under set -euo pipefail
# `find` on a missing directory exits 1 (stderr silenced) → pipefail aborts the
# assignment. Defends against fresh-clone state where .claude/retro-drafts/
# doesn't exist yet.
draft_count=$(find .claude/retro-drafts -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ' || true)
[ "${draft_count:-0}" -gt 0 ] && bits="$bits
• $draft_count unfollowed /retro draft(s) in .claude/retro-drafts/"

# 4. Memory file count — surface consolidation prompt when over threshold
# (v3.20 #244). Helps prevent memory bloat without being coercive.
# Compute the Claude Code project memory dir from $HOME at runtime instead of
# hardcoding `-Users-adamsfamily`. Claude Code encodes project paths as
# `${path//\//-}` (slashes → dashes), so $HOME becomes `-Users-adamsfamily`
# for this user but the same expression works portably.
_HOME_ENCODED=$(printf '%s' "$HOME" | sed 's#^/##; s#/#-#g; s#^#-#' || echo "")
MEM_DIR="${MEMORY_DIR:-$HOME/.claude/projects/${_HOME_ENCODED}/memory}"
MEM_COUNT_THRESHOLD="${MEM_COUNT_THRESHOLD:-25}"
if [ -d "$MEM_DIR" ]; then
	# `|| true` mirrors the draft_count assignment fix above — find can fail mid-session
	# (perm flip, mount race) and pipefail would abort the hook.
	mem_count=$(find "$MEM_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null | wc -l | tr -d ' ' || true)
	if [ "${mem_count:-0}" -gt "$MEM_COUNT_THRESHOLD" ]; then
		bits="$bits
• $mem_count memory files (threshold $MEM_COUNT_THRESHOLD) — consider running memory-consolidate skill"
	fi
fi

# 5b. iCloud quota pressure — warn when Postgres dumps are at risk of
# silent failure. v3.22.1 #277: a full iCloud plan silently drops dumps
# and auto-prunes old ones = data-loss window.
#
# CR v3.22.1: df reports the local volume's free space, not the iCloud
# PLAN quota. On macOS, iCloud quota isn't exposed via a public API; we
# approximate two separate signals:
#   (a) local FS pressure at the BACKUP_DIR volume (df) — catches the
#       common "disk is full" case
#   (b) Mobile Documents directory SIZE growth relative to a soft cap —
#       catches "iCloud plan is full" via the proxy "local cache is
#       saturated because iCloud refuses to evict"
# Both are surfaced as warnings, clearly labelled.
CFG_FILE="config.env"
if [ -f "$CFG_FILE" ]; then
	# `|| true`: grep no-match (BACKUP_DIR not set in config.env) propagates rc=1
	# through pipefail and aborts the hook; default to empty so the guard below skips.
	BACKUP_DIR_VAL=$(grep -E '^BACKUP_DIR=' "$CFG_FILE" | head -1 | sed -E 's/^BACKUP_DIR="?([^"]*)"?$/\1/' || true)
	if [ -n "$BACKUP_DIR_VAL" ] && [ -d "$BACKUP_DIR_VAL" ]; then
		# (a) Volume-level fill — local FS where the iCloud cache lives.
		# `|| true`: df can fail on permission issues even with a valid -d guard.
		USE_PCT=$(df -P "$BACKUP_DIR_VAL" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}' || true)
		if [ -n "$USE_PCT" ] && [ "$USE_PCT" -ge 90 ] 2>/dev/null; then
			bits="$bits
• Local volume backing iCloud cache (BACKUP_DIR) is ${USE_PCT}% full — Postgres dumps may fail. Clear space before next nightly run. (Note: this is disk-level; for iCloud plan fill, check iCloud.com storage settings.)"
		fi
	fi
fi

# 5. Stale maintain.sh — alert if the nightly cron hasn't fired in >48h.
# v3.22 #271: cron entry was silently missing; symptom = no new files in
# maintain-logs/ for days. Surface this at session start so "nothing ran
# last night" becomes visible instead of drifting undetected.
MAINTAIN_LOG_DIR="maintain-logs"
MAINTAIN_MAX_AGE_HOURS="${MAINTAIN_MAX_AGE_HOURS:-48}"
if [ -d "$MAINTAIN_LOG_DIR" ]; then
	# Pick newest *.log by mtime without xargs (SC2038-safe); find prints
	# "<epoch> <path>" per line, sort numerically desc, take top.
	latest_entry=$(find "$MAINTAIN_LOG_DIR" -type f -name "*.log" \
		-exec stat -f "%m %N" {} + 2>/dev/null ||
		find "$MAINTAIN_LOG_DIR" -type f -name "*.log" \
			-exec stat -c "%Y %n" {} + 2>/dev/null || true)
	# CR fix: awk preserves path-with-spaces (cut -d' ' -f2- breaks at first space)
	latest_log=$(echo "$latest_entry" | sort -rn | head -1 | awk '{$1=""; sub(/^[[:space:]]+/, ""); print}')
	if [ -n "$latest_log" ]; then
		log_mtime=$(stat -f %m "$latest_log" 2>/dev/null || stat -c %Y "$latest_log" 2>/dev/null || echo 0)
		log_age_hours=$((($(date +%s) - log_mtime) / 3600))
		if [ "$log_age_hours" -gt "$MAINTAIN_MAX_AGE_HOURS" ]; then
			bits="$bits
• maintain.sh hasn't run in ${log_age_hours}h (threshold ${MAINTAIN_MAX_AGE_HOURS}h) — cron may be broken. Check \`crontab -l\` for the 3:30 AM entry."
		fi
	else
		bits="$bits
• maintain-logs/ exists but has no log files — nightly cron likely never fired. Run \`scripts/install-cron.sh\`."
	fi
fi

# 5c. CR budget state (v4.3.G #374). Surface count in last rolling hour so
# operator knows whether Phase 2 CR CLI is safe to invoke without hitting
# the shared 5/hour rate limit.
if [ -x .claude/hooks/cr-budget-check.sh ]; then
	# `|| echo ""` on the cr-budget-check call: under set -euo pipefail, a
	# rate-limit / jq-internal / log-race failure inside cr-budget-check.sh
	# would propagate and abort the entire SessionStart hook.
	cr_state=$(.claude/hooks/cr-budget-check.sh --json 2>/dev/null || echo "")
	if [ -n "$cr_state" ]; then
		# `|| true` on each jq read: cr_state is JSON FROM cr-budget-check.sh,
		# but a partial/corrupted output would make jq exit 2 and abort the hook.
		cr_used=$(echo "$cr_state" | jq -r '.used' || true)
		cr_status=$(echo "$cr_state" | jq -r '.status' || true)
		# Limit comes from .claude/cr-config.yml — read it from the same JSON
		# instead of hardcoding `/5` (avoids drift if the config changes).
		cr_limit=$(echo "$cr_state" | jq -r '.limit' || true)
		if [ "${cr_used:-0}" -gt 0 ] 2>/dev/null; then
			cr_next=$(echo "$cr_state" | jq -r '.next_slot_free // ""' || true)
			# Show denominator only when cr_limit was successfully read from
			# the SSOT — hardcoding `/5` would drift if .claude/cr-config.yml
			# rate_limit_per_hour changes.
			if [ -n "${cr_limit:-}" ]; then
				cr_line="• CR budget: ${cr_used}/${cr_limit} used in last hour (${cr_status})"
			else
				cr_line="• CR budget: ${cr_used} used in last hour (${cr_status})"
			fi
			[ -n "$cr_next" ] && cr_line="$cr_line · next slot frees at $cr_next"
			bits="$bits
$cr_line"
		fi
	fi
fi

# 6. Actions cap deferral (v4.3.H #375). If workflows are disabled_manually
# OR recent runs show 0ms billable failure, we're in the cap-deferral state
# from issue #366. Surface it so Claude knows not to rely on CI for gating
# AND lists stale local-backup workflows so operator can run them via
# `.claude/local-backups/run-workflow.sh <name>`.
# rc capture under set -e: bare `cmd; rc=$?` aborts under set -e if cmd exits
# non-zero; `if ! cmd; then rc=$?` always returns 0; only `cmd || rc=$?`
# captures the non-zero exit without aborting (per feedback_rc_capture_set_e).
# Section-scoped name `cap_rc` matches drift_rc/dash_rc convention elsewhere.
cap_rc=0
# Guard the relative-path invocation: when SessionStart fires in a cwd that
# isn't a consumer repo (e.g. $HOME, /tmp), this file doesn't exist and a
# bare invocation surfaces "command not found" stderr. The downstream
# `if [ "$cap_rc" = "1" ]` branch already treats cap_rc=0 as "no cap" so
# the silent-skip path produces the correct outcome (#42).
if [ -x .claude/hooks/detect-actions-cap.sh ]; then
	.claude/hooks/detect-actions-cap.sh --quiet || cap_rc=$?
fi
if [ "$cap_rc" = "1" ]; then
	cap_msg='• ⚠ GitHub Actions capped/deferred (#366). Local gating via `.claude/hooks/run-required-checks.sh`; run stale workflows via `.claude/local-backups/run-workflow.sh <name>`'
	# v4.4.B: auto-discover disabled workflows (NOT hardcoded 5). Query
	# gh workflow list, iterate, check staleness via two signals:
	#   - timestamp > cadence derived from `on.schedule` cron
	#   - current file hash != .last-run/<name>.sha (file drifted since last run)
	stale_list=""
	if [ -d .claude/local-backups/.last-run ]; then
		# Pull disabled schedule-triggered workflows only. PR-event workflows
		# don't have a "cadence" to be stale against; they fire on events.
		# v4.4 round-2 fix (CR): grep -rl "^name: ${wf_name}$" fails on
		# quoted/indented/trailing-whitespace variants of the `name:` line.
		# Switch to yq per-file comparison which normalizes YAML reading.
		disabled_sched=$(gh workflow list --all --limit 100 2>/dev/null |
			awk -F'\t' '$2 == "disabled_manually" { print $1 }' |
			while IFS= read -r wf_name; do
				# Find the workflow file with this name via yq, check for on.schedule
				for f in .github/workflows/*.yml .github/workflows/*.yaml; do
					[ -f "$f" ] || continue
					file_name=$(yq -r '.name // ""' "$f" 2>/dev/null)
					if [ "$file_name" = "$wf_name" ]; then
						if yq -e '.on.schedule' "$f" >/dev/null 2>&1; then
							basename "$f"
						fi
						break
					fi
				done
			done)

		for wf in $disabled_sched; do
			name="${wf%.yml}"
			name="${name%.yaml}"
			ts_file=".claude/local-backups/.last-run/${name}.ts"
			sha_file=".claude/local-backups/.last-run/${name}.sha"
			wf_path=".github/workflows/$wf"

			if [ ! -f "$ts_file" ]; then
				stale_list="$stale_list $wf(never-run)"
				continue
			fi

			# Signal 1 — file hash changed since last run
			if [ -f "$sha_file" ] && [ -f "$wf_path" ]; then
				last_sha=$(cat "$sha_file" 2>/dev/null)
				current_sha=$(git hash-object "$wf_path" 2>/dev/null)
				if [ -n "$last_sha" ] && [ "$last_sha" != "$current_sha" ]; then
					stale_list="$stale_list $wf(file-changed)"
					continue
				fi
			fi

			# Signal 2 — age vs cron-derived threshold
			ts=$(cat "$ts_file" 2>/dev/null)
			age_s=$(($(date +%s) - $(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || date -u -d "$ts" +%s 2>/dev/null || echo 0)))
			age_d=$((age_s / 86400))

			# v4.5.F: field-by-field cron parse. Cron format: min hour dom month dow.
			# Old bash-case arms conflated positions ("0 1 * * *" daily-at-1am
			# was falsely matching the "* 1 * *" monthly pattern). Split via
			# awk and test each field explicitly so matching is precise.
			#
			# v4.5 Phase 1 hardening: if yq returns non-empty cron but parsing
			# fails, default to 7d with a warning (session-start context, not
			# a hard failure — don't crash the whole hook for one bad cron).
			# `|| echo ""`: yq exits non-zero on schema drift / missing key
			# in some versions; under set -euo pipefail that aborts the loop.
			cron=$(yq -r '.on.schedule[0].cron' "$wf_path" 2>/dev/null || echo "")
			threshold=7
			if [ -n "$cron" ] && [ "$cron" != "null" ]; then
				dom=$(echo "$cron" | awk '{print $3}')
				dow=$(echo "$cron" | awk '{print $5}')
				if [ "$dom" != "*" ] && [ "$dom" != "?" ]; then
					threshold=30 # specific day-of-month = monthly
				elif [ "$dow" != "*" ] && [ "$dow" != "?" ]; then
					threshold=7 # specific day-of-week = weekly
				else
					threshold=1 # all wildcards = daily (or more frequent)
				fi
			fi
			# v4.5 Phase 1 hardening: if date parse failed (age_s=0 fallback
			# yields now-0 = ~56-year-old timestamp, falsely stale), skip
			# the staleness report for this entry instead of flagging it.
			# v4.5 round 3 fix (CR): use age_d > 3650 (10 years). The old
			# sentinel (age_s > 2B) wouldn't trigger until ~May 2033 at
			# current epoch. No legitimate workflow last-run is 10 years old.
			if [ "$age_d" -gt 3650 ] 2>/dev/null; then
				continue
			fi

			if [ "$age_d" -gt "$threshold" ] 2>/dev/null; then
				stale_list="$stale_list $wf(${age_d}d,threshold=${threshold}d)"
			fi
		done
	fi
	if [ -n "$stale_list" ]; then
		cap_msg="$cap_msg"$'\n'"  Stale workflows:$stale_list"
	fi
	bits="$bits
$cap_msg"
fi

# 7. Container drift vs compose.yaml (v4.11). Renovate auto-merges bump image
# pins in compose.yaml, but nothing on the host runs `docker compose up -d`
# until maintain.sh cron (3:30 AM local) — leaving running containers on
# OLD images while main has NEW pins. Memory `feedback_merge_is_not_deploy.md`
# documents the rule; this surfaces the gap on session start so drift is
# visible without me having to remember to check.
if [ -x .claude/hooks/check-deploy-drift.sh ]; then
	# Distinguish exit 0 (clean) / 1 (drift) / 2 (tooling missing) — the
	# original `|| true` version silently reported clean when the detector
	# couldn't run. Now: 0 emits nothing, 1 emits the quiet line, 2 emits
	# an explicit "check skipped" so the user knows the section ran.
	drift_out=$(.claude/hooks/check-deploy-drift.sh --quiet 2>&1) && drift_rc=0 || drift_rc=$?
	case "$drift_rc" in
	0) : ;; # clean, no output
	1) [ -n "$drift_out" ] && bits="$bits
$drift_out" ;;
	2)
		bits="$bits
• ⚠ drift check skipped — tooling missing (yq/docker/daemon). Install or start the missing component."
		;;
	*)
		# Any other non-zero: treat as a crash (SIGKILL=137, SIGSEGV=139,
		# unhandled set -e abort, etc.) — surface loudly with stderr so a
		# real bug in the detector doesn't masquerade as a benign "skip".
		bits="$bits
• 🔴 drift check CRASHED (rc=$drift_rc) — ${drift_out:-no output}"
		;;
	esac
fi

# 8. Pending local review for HEAD (v4.11 #456/#457). The pre-push gate at
# .claude/hooks/pre-push-pipeline-gate.sh (v4.3.F #372) refuses push if HEAD
# has no converged review-log entry. Surfacing at session start means I run
# Phase 1 + Phase 2 BEFORE hitting the wall, not after — AND now emits the
# exact skill invocations to fire (not just "run Phase 1") so I can auto-
# execute rather than re-derive the list each time. Only flags on branches
# that can actually be pushed (skip if HEAD==main).
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# 8b. Un-triaged open issues (v4.11 #457). During Actions cap, ai-triage.yml
# is disabled — the github-issue-creation skill is supposed to fire
# .claude/local-backups/ai-triage.sh + project-board-sync.sh after each
# creation, but it's easy to forget (did so 2026-04-20 on #451-#457).
# Flag any open issue missing a priority:* label so the gap is visible
# at session start instead of being discovered by the user looking at
# a bare board. Relies on gh REST (not GraphQL) to stay cheap.
# --limit 500 per feedback_gh_query_limits (default 30 silently truncates).
# Separate rc capture so a gh auth / rate-limit failure surfaces as
# "check skipped" instead of silently emitting "all clean" (which
# defeats the whole point of this section).
if untriaged=$(gh issue list --state open --limit 500 --json number,labels --jq '[.[] | select(any(.labels[]; .name | startswith("priority:")) | not)] | .[].number' 2>/dev/null); then
	if [ -n "$untriaged" ]; then
		untriaged_csv=$(echo "$untriaged" | paste -sd, -)
		bits="$bits
• ⚠ open issues without priority:* label: $untriaged_csv — fire ai-triage.sh on each (Actions cap means server-side triage is disabled, local replica must be invoked per github-issue-creation skill Step 9)"
	fi
else
	bits="$bits
• ⚠ untriaged-issue check skipped — gh issue list failed (rate limit / auth / network?)"
fi

if [ -n "$HEAD_SHA" ] && [ "$CUR_BRANCH" != "main" ] && [ "$CUR_BRANCH" != "HEAD" ]; then
	REVIEW_LOG=".claude/review-log/${HEAD_SHA}.jsonl"
	if [ ! -f "$REVIEW_LOG" ]; then
		SHORT_SHA=$(git rev-parse --short HEAD 2>/dev/null)
		# Derive the exact agent list from review-config.yml so the suggestion
		# stays accurate when agents are added/removed. Empty list = no-op.
		agent_list=""
		if [ -x .claude/hooks/list-phase1-agents.sh ]; then
			agent_list=$(.claude/hooks/list-phase1-agents.sh main 2>/dev/null | paste -sd, - 2>/dev/null || true)
		fi
		bits="$bits
• ⚠ HEAD ($SHORT_SHA) on branch \`${CUR_BRANCH}\` has no review-log — pre-push gate will block push.
  Run in order:
  1. Phase 0 (auto) — security-guidance hook already fires on Edit/Write
  2. Phase 1 LOCAL parallel — agents for this diff: ${agent_list:-unknown, run list-phase1-agents.sh}
     • pr-review-toolkit: launch each agent via Agent tool subagent_type=pr-review-toolkit:<name>
     • /security-review skill (Skill tool: security-review)
     • semgrep: \`semgrep scan --config=auto --error\` or mcp__plugin_semgrep_semgrep__semgrep_scan
     Iterate ≤3 rounds, log via \`.claude/hooks/review-log.sh phase1 <round> <agent> <findings> ok\`
  3. Phase 2 LOCAL — \`coderabbit review --agent -t committed --base main\` ONCE after Phase 1 clean
     Log via \`.claude/hooks/review-log.sh phase2 <findings> clean\`
  4. Phase 3 REMOTE — CR-in-CI runs on PR-open (required gate, shares bucket with Phase 2)"
	fi
fi

# 9. Orphan audit (v4.11.1). User 2026-04-20: "ensure local matches main
# no orphans anything issues prs branches locally or remote". Flag the
# easy-to-miss leftovers at session start so they can be cleaned while
# still fresh: stale local branches (not main, tracking a deleted remote),
# remote-tracking refs gone upstream (needs prune), tags local-only or
# remote-only (push/fetch mismatch), dirty working tree on main.
if [ -d .git ]; then
	orphan_bits=""
	# Dirty working tree on main — uncommitted leftovers
	if [ "$CUR_BRANCH" = "main" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
		orphan_bits="$orphan_bits · uncommitted changes on main"
	fi
	# Local branches other than main (could be WIP or orphan).
	# `|| true` on the pipe: when on main with no other local branches,
	# grep -v filters everything → exit 1 → pipefail aborts assignment →
	# every section after this one (Renovate dashboard, maintain.sh ERRORS,
	# PIPELINE_GATE_SKIP overuse, bats baseline staleness) silently skipped.
	stale_local=$(git branch --format '%(refname:short)' 2>/dev/null | grep -vE '^(main|HEAD)$' | paste -sd, - 2>/dev/null || true)
	[ -n "$stale_local" ] && orphan_bits="$orphan_bits · local branches: $stale_local"
	# Remote-tracking refs to branches that were deleted upstream (need --prune)
	# Uses for-each-ref to catch "[gone]" upstream status without shelling out 3x.
	gone=$(git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads 2>/dev/null | grep -c '\[gone\]' 2>/dev/null || true)
	[ "${gone:-0}" -gt 0 ] && orphan_bits="$orphan_bits · $gone local branch(es) tracking deleted remote — run \`git fetch --prune\`"
	# Tag mismatch local↔remote. `--refs` filters out the `^{}` peeled
	# refs so we don't double-count annotated tags. Guard on `origin`
	# existing — in a fresh-clone / detached repo the remote may be
	# absent and we should skip the comparison rather than false-fire.
	# `|| true`: `git tag` can exit 128 if .git is corrupt/incomplete (the outer
	# `if [ -d .git ]` doesn't verify the repo state, only directory presence).
	local_tags=$(git tag --list 'v*' 2>/dev/null | wc -l | tr -d ' ' || true)
	if git remote get-url origin >/dev/null 2>&1; then
		# Capture both stdout and exit — a failed `ls-remote` (offline,
		# auth lapse, rate-limited) must NOT false-positive as "tag drift"
		# by defaulting remote_tags to 0. Mirror the Section 7 rc-capture
		# pattern instead.
		if remote_out=$(git ls-remote --tags --refs origin 'v*' 2>/dev/null); then
			if [ -z "$remote_out" ]; then
				remote_tags=0
			else
				remote_tags=$(printf '%s\n' "$remote_out" | wc -l | tr -d ' ' || true)
			fi
			if [ "${local_tags:-0}" != "${remote_tags:-0}" ]; then
				orphan_bits="$orphan_bits · tag drift: local=$local_tags remote=$remote_tags (run \`git fetch --tags\` or push missing tags)"
			fi
		fi
	fi
	if [ -n "$orphan_bits" ]; then
		bits="$bits
• ⚠ orphan audit:${orphan_bits}"
	fi
fi

# 10. Renovate Dependency Dashboard pending-approval surfacing (v4.12 #463).
# Majors need manual approval (e.g. Postgres 16→18 sat unchecked overnight
# and was invisible until user asked). Parse the dashboard issue body for
# unchecked items in its '## Pending Approval' section.
if ! command -v gh >/dev/null 2>&1; then
	bits="$bits
• ⚠ gh CLI missing — cannot check Renovate dashboard"
else
	# Capture body OR error in a single call via 2>&1 — avoids the
	# predictable-temp-file / double-invocation patterns. On success,
	# dash_out is the issue body; on failure, it's the stderr message.
	dash_out=$(gh issue view 24 --json body -q '.body' 2>&1) && dash_rc=0 || dash_rc=$?
	if [ "$dash_rc" -ne 0 ]; then
		bits="$bits
• ⚠ Dashboard #24 unreachable ($(printf '%s' "$dash_out" | head -c 80)) — check gh auth / rate limit"
	elif ! printf '%s\n' "$dash_out" | grep -q '^## Pending Approval'; then
		# Format canary: if the "## Pending Approval" header ever disappears
		# upstream (Renovate renames it), awk silently returns 0 and majors
		# float by unnoticed. Flag the format drift loudly so the fix comes
		# to us instead of waiting for a user to notice missed approvals.
		bits="$bits
• ⚠ Renovate Dashboard #24 has no 'Pending Approval' section — format may have changed; check the awk parse"
	else
		pending=$(printf '%s\n' "$dash_out" | awk '
			/^## Pending Approval/ {in_section=1; next}
			/^## / && in_section {exit}
			in_section && /^ *- \[ \]/ {count++}
			END {print count+0}
		')
		if [ "${pending:-0}" -gt 0 ]; then
			bits="$bits
• ⚠ Renovate Dependency Dashboard (#24) has $pending pending-approval major(s) — dashboard-analysis/dashboard-approve skill to process"
		fi
	fi
fi

# 11. maintain.sh nightly ERROR count from last run (v4.12 #464). The
# launchd log prints an end-of-run summary like '[...] Maintenance
# complete with N ERRORS' — surface N at session boot so morning review
# catches it instead of having to read the log manually. Reuses the
# $latest_log already resolved by Section 5 (no duplicate pipeline).
if [ -n "${latest_log:-}" ] && [ -f "$latest_log" ]; then
	# Match the summary line's exact format emitted by maintain.sh. If
	# the format ever drifts (wording change, missing summary because
	# maintain.sh crashed mid-run), canary to a warning rather than
	# silently reporting zero errors.
	summary=$(grep -oE 'Maintenance complete with [0-9]+ ERRORS?' "$latest_log" 2>/dev/null | tail -1 || true)
	if [ -z "$summary" ]; then
		bits="$bits
• ⚠ $latest_log has no 'Maintenance complete' summary — run may have crashed mid-flight, or format drifted"
	else
		err_count=$(printf '%s' "$summary" | grep -oE '[0-9]+' || true)
		if [ -n "$err_count" ] && [ "$err_count" -gt 0 ] 2>/dev/null; then
			bits="$bits
• ⚠ maintain.sh last run had $err_count ERROR(s) — tail $latest_log"
		fi
	fi
fi

# 12. v4.23-O (#561): flag PIPELINE_GATE_SKIP overuse. Gate is an
# emergency bypass, not a routine — >3/day suggests the gate's
# thresholds are wrong OR Phase 1 discipline slipped systematically.
SKIP_LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/logs/pipeline-skip.jsonl"
if [ -f "$SKIP_LOG" ]; then
	today=$(date -u +%Y-%m-%d)
	# `|| true` (NOT `|| echo 0`): `grep -c` no-match outputs '0' AND exits 1.
	# With `|| echo 0`, the fallback fires too, producing today_count='0\n0'
	# which makes the [ ... -gt 3 ] arithmetic test below silently fail.
	today_count=$(grep -c "\"ts\":\"$today" "$SKIP_LOG" 2>/dev/null || true)
	if [ "${today_count:-0}" -gt 3 ]; then
		# #2545: the log now carries rows from TWO producers (pre-push
		# bypasses and phase2 round-cap overrides — distinguished by the
		# `gate` field; rows predating the field were all written by the
		# pre-push hook). Segment the warning so a day of deliberate cap
		# overrides is not misread as push-gate bypass abuse. Best-effort:
		# jq absent/failing degrades to the un-segmented total.
		gate_breakdown=$(jq -rs --arg today "$today" \
			'[.[] | select(.ts | startswith($today))] | group_by(.gate // "pre-push") | map("\(.[0].gate // "pre-push")=\(length)") | join(", ")' \
			"$SKIP_LOG" 2>/dev/null || true)
		bits="$bits
• ⚠ PIPELINE_GATE_SKIP used $today_count time(s) today${gate_breakdown:+ ($gate_breakdown)} — emergency bypass is running routine. Review whether gate thresholds need adjustment (see v4.23-A scaler) or Phase 1 discipline slipped."
	fi
fi

# 13. v4.23-V (#591): flag stale bats baseline. The weekly cron should
# touch bats-run.jsonl with `baseline: true` every Sunday 05:00 local.
# If the most-recent baseline entry is >14 days old (2x miss), the cron
# is probably broken or not installed — push-gate's 7-day fallback
# relies on fresh baselines.
BATS_LOG="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/logs/bats-run.jsonl"
if [ -f "$BATS_LOG" ] && command -v jq >/dev/null 2>&1; then
	# tac is GNU-only; macOS ships `tail -r`. Pick whichever exists.
	if command -v tac >/dev/null 2>&1; then
		_reverse() { tac "$@"; }
	else
		_reverse() { tail -r "$@"; }
	fi
	# One pass: _reverse + grep -m1 already short-circuits to the most
	# recent match. If there's no match, the pipeline emits empty and the
	# final jq turns that into "". Prior `grep -q && _reverse | ...`
	# double-scanned the file for the same signal.
	latest_baseline_ts=$(_reverse "$BATS_LOG" 2>/dev/null | grep -m1 '"baseline":true' | jq -r '.ts // ""' 2>/dev/null || echo "")
	if [ -z "$latest_baseline_ts" ]; then
		bits="$bits
• ⚠ No bats baseline run recorded yet — install via scripts/install-bats-baseline-scheduler.sh (weekly cron for v4.23-V)."
	else
		# Compare latest baseline ts to 14 days ago. Prior form silently
		# fell back to now_s on parse failure — which masked the
		# "timestamp malformed" case as "fresh baseline", never firing
		# the warning. Use empty sentinel instead + flag parse failures.
		now_s=$(date -u +%s)
		bl_s=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$latest_baseline_ts" +%s 2>/dev/null || date -d "$latest_baseline_ts" +%s 2>/dev/null || echo "")
		if [ -z "$bl_s" ]; then
			bits="$bits
• ⚠ Latest bats baseline ts is unparseable ($latest_baseline_ts) — log schema may have drifted. Check .claude/logs/bats-run.jsonl."
		else
			age_days=$(((now_s - bl_s) / 86400))
			if [ "$age_days" -gt 14 ]; then
				bits="$bits
• ⚠ Latest bats baseline is ${age_days}d old (>14 days, 2× cadence miss) — cron may be broken. Verify: scripts/install-bats-baseline-scheduler.sh --verify"
			fi
		fi
	fi
fi

# 14. v0.22.0 (#152) — flag consumers behind plugin version. Plugin-side
# only; consumer repos don't ship scripts/cascade-status.sh so the guard
# silently skips for them. Suppresses output when all consumers current
# (--quiet). Best-effort: any cascade-status failure (gh auth, network)
# falls through with a hint rather than aborting session-start.
CASCADE_STATUS_SH="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/cascade-status.sh"
if [ -x "$CASCADE_STATUS_SH" ]; then
	# --quiet: exit 0 if all current, exit 1 if any behind (with a
	# stderr summary line). 2 = precondition error → surface as warning.
	cascade_out=$("$CASCADE_STATUS_SH" --quiet 2>&1) && cascade_rc=0 || cascade_rc=$?
	case "$cascade_rc" in
	0) : ;; # all current
	1)
		[ -n "$cascade_out" ] && bits="$bits
• $cascade_out"
		;;
	*)
		bits="$bits
• ⚠ cascade-status check failed (rc=$cascade_rc): ${cascade_out:-no output}"
		;;
	esac
fi

# Only emit if we have something to say
if [ -n "$bits" ]; then
	jq -nc \
		--arg ctx "📊 Meta-learning status:$bits" \
		'{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
fi

exit 0
