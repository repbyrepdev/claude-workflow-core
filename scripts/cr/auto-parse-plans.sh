#!/bin/bash
set -euo pipefail
# v0.7.1 (#23): cr-plan auto-parse — close the last manual step in the
# plan-me → CR plan → epic+subs chain.
#
# WHY this exists: the chain today is:
#   1. ai-triage labels issue `plan-me` (auto)
#   2. CR Issue Planner posts plan comment (auto via .coderabbit.yaml)
#   3. cr-plan/run.sh parse <N> → epic+subs created (MANUAL — last gap)
#
# This script automates step 3: polls for plan-me-labeled issues that
# have a CR plan comment AND no `plan-parsed` label, invokes
# `cr-plan/run.sh parse <N>` (APPROVE=1), and applies `plan-parsed` label
# on success.
#
# Safety:
# - Idempotent via `plan-parsed` label (won't re-parse)
# - Respects `no-plan` label (operator opt-out, never parses)
# - Reads `bypass_label` (auto:cr-plan-disabled) for repo-level disable
# - Logs each invocation to .claude/logs/cr-auto-parse.jsonl
#
# Invocation:
#   .claude/scripts/cr/auto-parse-plans.sh                # one poll cycle
#   .claude/scripts/cr/auto-parse-plans.sh --dry-run      # show what would parse
#   .claude/scripts/cr/auto-parse-plans.sh --issue <N>    # parse one specific issue

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

DRY_RUN=0
TARGET_ISSUE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--issue)
		[ "$#" -ge 2 ] || {
			echo "auto-parse-plans: --issue requires value" >&2
			exit 2
		}
		TARGET_ISSUE="$2"
		shift 2
		;;
	--help | -h)
		head -20 "$0" | sed -n 's/^# \?//p'
		exit 0
		;;
	*)
		echo "auto-parse-plans: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# Respect cap-aware mode — if Actions are ON, the cr-auto-parse.yml
# workflow handles this (script is local-backup fallback).
ACTIONS_MODE=$(scm_read_actions_mode 2>/dev/null || echo "local")
if [ "$ACTIONS_MODE" = "remote" ]; then
	echo "auto-parse-plans: ACTIONS_MODE=remote — cr-auto-parse.yml workflow handles this; skipping local invocation" >&2
	exit 0
fi

# Resolve cr-plan skill (consumer or plugin cache).
# When invoked from plugin cache, SCRIPT_DIR = <cache>/scripts/cr/,
# so the skill is at SCRIPT_DIR/../../skills/cr-plan/run.sh.
CR_PLAN_SKILL=""
for candidate in \
	"$REPO_ROOT/.claude/skills/cr-plan/run.sh" \
	"$SCRIPT_DIR/../../skills/cr-plan/run.sh"; do
	if [ -x "$candidate" ]; then
		CR_PLAN_SKILL="$candidate"
		break
	fi
done
if [ -z "$CR_PLAN_SKILL" ]; then
	echo "auto-parse-plans: ERROR: cr-plan/run.sh not found (consumer or plugin cache)" >&2
	exit 2
fi

LOG_DIR="$REPO_ROOT/.claude/logs"
LOG_FILE="$LOG_DIR/cr-auto-parse.jsonl"
mkdir -p "$LOG_DIR"

_log() {
	# Args: <event> <issue> <status> <detail>
	local event=$1 issue=$2 status=$3 detail=$4
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"ts":"%s","event":"%s","issue":%s,"status":"%s","detail":%s}\n' \
		"$ts" "$event" "${issue:-null}" "$status" \
		"$(printf '%s' "$detail" | jq -Rs .)" >>"$LOG_FILE"
}

# Plan-stuck timeout: if a plan-me-labeled issue has had the label > this
# many seconds with no CR plan comment yet, post `@coderabbitai plan` to
# nudge the server-side Issue Planner (it occasionally misses the label
# event under load). 600s = 10 min default.
STUCK_TIMEOUT_SEC="${CR_PLAN_STUCK_TIMEOUT_SEC:-600}"

_check_and_parse_issue() {
	local issue=$1
	# Fetch issue labels + comments + events (for label-applied timestamps).
	local data
	if ! data=$(gh issue view "$issue" --json labels,number,title,comments,createdAt 2>/dev/null); then
		_log "fetch-failed" "$issue" "error" "gh issue view failed"
		echo "auto-parse-plans: WARN: gh issue view $issue failed — skipping" >&2
		return 0
	fi

	# Skip if no-plan label present (operator opt-out).
	if printf '%s' "$data" | jq -e '.labels[] | select(.name == "no-plan")' >/dev/null 2>&1; then
		_log "skip-no-plan" "$issue" "skip" "no-plan label present"
		return 0
	fi

	# Skip if plan-parsed label present (idempotency).
	if printf '%s' "$data" | jq -e '.labels[] | select(.name == "plan-parsed")' >/dev/null 2>&1; then
		_log "skip-already-parsed" "$issue" "skip" "plan-parsed label present"
		return 0
	fi

	# Skip if this issue is ITSELF an epic. Epics are cr-plan OUTPUTS, never
	# parse INPUTS — parsing an epic re-decomposes it into a NESTED epic
	# ("EPIC: EPIC: ..."), the runaway that created 800+ duplicate epics on
	# 2026-06-02. An epic must never re-enter the parse pipeline, even if it
	# re-acquired plan-me (e.g. via auto-triage of the just-created issue).
	if printf '%s' "$data" | jq -e '.labels[] | select(.name == "epic")' >/dev/null 2>&1; then
		_log "skip-epic" "$issue" "skip" "epic label present — epics are parse outputs, not inputs"
		return 0
	fi

	# Require plan-me label (otherwise no plan to parse).
	if ! printf '%s' "$data" | jq -e '.labels[] | select(.name == "plan-me")' >/dev/null 2>&1; then
		_log "skip-no-plan-me" "$issue" "skip" "plan-me label absent"
		return 0
	fi

	# Require a CR comment containing "Implementation Steps" or "Phases".
	# (cr-plan/run.sh `parse` accepts either heading per #788.)
	local has_plan
	has_plan=$(printf '%s' "$data" | jq -r '
		[.comments[]
		 | select(.author.login == "coderabbitai" or .author.login == "coderabbit[bot]" or .author.login == "coderabbitai[bot]")
		 | select(.body | test("(## Implementation Steps|## Phases)"))
		] | length')
	if [ "$has_plan" = "0" ] || [ -z "$has_plan" ]; then
		# No plan yet. Check how long the issue has been sitting in plan-me
		# state. If > STUCK_TIMEOUT_SEC, nudge CR by posting `@coderabbitai plan`.
		# Track first-seen-with-plan-me locally so we don't spam re-nudges.
		local nudge_state_dir="$REPO_ROOT/.claude/.session-state/cr-plan-poll"
		mkdir -p "$nudge_state_dir" 2>/dev/null || true
		local first_seen_file="$nudge_state_dir/${issue}.first-seen"
		local nudged_file="$nudge_state_dir/${issue}.nudged"
		local now first_seen elapsed
		now=$(date +%s)
		if [ ! -f "$first_seen_file" ]; then
			printf '%s\n' "$now" >"$first_seen_file"
			_log "first-seen" "$issue" "info" "tracking plan-me wait"
			return 0
		fi
		first_seen=$(head -1 "$first_seen_file" 2>/dev/null || echo "$now")
		elapsed=$((now - first_seen))
		if [ "$elapsed" -ge "$STUCK_TIMEOUT_SEC" ] && [ ! -f "$nudged_file" ]; then
			if [ "$DRY_RUN" = "1" ]; then
				echo "auto-parse-plans: WOULD nudge issue #$issue (${elapsed}s with no plan)" >&2
				_log "would-nudge" "$issue" "dry-run" "elapsed=${elapsed}s"
				return 0
			fi
			echo "auto-parse-plans: nudging issue #$issue — ${elapsed}s with no CR plan, posting @coderabbitai plan" >&2
			# Posting `@coderabbitai plan` re-triggers Issue Planner per
			# https://docs.coderabbit.ai/integrations/issue-creation
			# (same command cr-plan/run.sh `trigger` posts).
			if gh issue comment "$issue" --body "@coderabbitai plan" 2>&1 | tail -1 >&2; then
				touch "$nudged_file"
				_log "nudged" "$issue" "ok" "elapsed=${elapsed}s; posted @coderabbitai plan"
			else
				_log "nudge-failed" "$issue" "error" "gh issue comment failed"
				echo "auto-parse-plans: WARN: nudge comment post failed for #$issue" >&2
			fi
		else
			_log "skip-no-cr-plan" "$issue" "skip" "no CR plan yet (elapsed=${elapsed}s, threshold=${STUCK_TIMEOUT_SEC}s, nudged=$([ -f "$nudged_file" ] && echo yes || echo no))"
		fi
		return 0
	fi

	# Eligible for parse.
	if [ "$DRY_RUN" = "1" ]; then
		echo "auto-parse-plans: WOULD parse issue #$issue (plan-me + CR plan present, not yet parsed)" >&2
		_log "would-parse" "$issue" "dry-run" "plan-me + CR plan present"
		return 0
	fi

	echo "auto-parse-plans: parsing issue #$issue" >&2
	local parse_out parse_rc=0
	parse_out=$(APPROVE=1 "$CR_PLAN_SKILL" parse "$issue" 2>&1) || parse_rc=$?
	if [ "$parse_rc" -ne 0 ]; then
		_log "parse-failed" "$issue" "error" "rc=$parse_rc: $(printf '%s' "$parse_out" | tail -c 200)"
		echo "auto-parse-plans: ERROR: cr-plan parse $issue failed (rc=$parse_rc) — operator action required" >&2
		echo "$parse_out" | tail -10 >&2
		return 1
	fi
	_log "parsed" "$issue" "ok" "epic+subs created"
	echo "auto-parse-plans: ✓ parsed issue #$issue" >&2

	# Mark plan-parsed AND drop plan-me so the source issue leaves the poll set.
	# CR #478 r4 (REVERSAL of an earlier wrong rejection): a single combined
	# `--add-label plan-parsed --remove-label plan-me` fails WHOLESALE when the
	# plan-parsed label is undefined (gh: "'plan-parsed' not found") -> plan-me is
	# NOT removed -> the source re-enters the poll every cycle = runaway (observed
	# 205 issues, #223). Fix: ensure the label exists, then remove plan-me as its
	# OWN op so the poll-bounding can't be blocked by the marker-add failing.
	# plan-parsed's metadata SSOT is .github/labels.yml; read color/description
	# FROM it (CR-CLI follow-on) so this create doesn't hardcode a second copy.
	# Fall back to the known values if yq or labels.yml is unavailable — the
	# create is still just a DEFENSIVE existence-ensure (the relabel below fails
	# wholesale if the label is undefined); label-sync reconciles metadata from
	# the SSOT regardless.
	local _labels_yml="$REPO_ROOT/.github/labels.yml"
	local pp_color="ededed" pp_desc="cr-plan parsed this into an epic+subs"
	if command -v yq >/dev/null 2>&1 && [ -f "$_labels_yml" ]; then
		pp_color=$(yq -r '(.[] | select(.name == "plan-parsed") | .color) // "ededed"' "$_labels_yml" 2>/dev/null | tr -d '"') || pp_color="ededed"
		pp_desc=$(yq -r '(.[] | select(.name == "plan-parsed") | .description) // "cr-plan parsed this into an epic+subs"' "$_labels_yml" 2>/dev/null) || pp_desc="cr-plan parsed this into an epic+subs"
		[ -n "$pp_color" ] || pp_color="ededed"
		[ -n "$pp_desc" ] || pp_desc="cr-plan parsed this into an epic+subs"
	fi
	#
	# Capture create output+rc (CR-CLI) instead of swallowing ALL failures via
	# `2>/dev/null || true`. BUT do NOT fail-closed on non-zero: `gh label create`
	# exits non-zero on the BENIGN "already exists" case — the COMMON path, since
	# the label usually already exists — so aborting there would break the poller
	# every run. Treat already-exists as a no-op (the label is present, which is
	# all this ensure needs); for any OTHER create failure, WARN + log but still
	# continue (the downstream --add-label plan-parsed capture warns if the marker
	# truly can't be set; aborting the whole batch poll for one issue's transient
	# label-create blip is worse than proceeding). The `if !` form captures rc
	# under `set -e` (a bare `lc_out=$(...)` would abort the script on non-zero).
	local lc_out=""
	if ! lc_out=$(gh label create plan-parsed --color "$pp_color" --description "$pp_desc" 2>&1); then
		if printf '%s' "$lc_out" | grep -qi 'already exists'; then
			: # benign — label already present; nothing to do
		else
			_log "label-create-failed" "$issue" "warn" "plan-parsed create failed (non-benign): $(printf '%s' "$lc_out" | tail -c 200)"
			echo "auto-parse-plans: WARN: plan-parsed label create failed for #$issue (continuing): $(printf '%s' "$lc_out" | tail -1)" >&2
		fi
	fi
	# Add the plan-parsed idempotency marker FIRST (CR-CLI r8): the skip-guard
	# above ("skip if plan-parsed present") gates re-parse on ANY issue carrying
	# plan-parsed, so setting it BEFORE removing plan-me means a FAILED remove
	# can't cause a runaway — a lingering plan-me is harmless once plan-parsed is
	# present. Its OWN op (not combined) so the marker-add can't be blocked.
	#
	# Capture gh's combined output+rc DIRECTLY (CR-CLI #223 follow-on): the
	# previous `gh ... 2>&1 | tail -1 >&2` form put gh in a pipeline, so failure
	# detection relied on `set -o pipefail` to surface gh's non-zero rc (without
	# it the `if` only sees tail's rc, which is ~always 0 → a failed relabel
	# would be silently swallowed). Capturing into $out and testing gh's own rc
	# makes the WARN/log fire regardless of the pipefail option's state.
	local add_out remove_out
	if ! add_out=$(gh issue edit "$issue" --add-label plan-parsed 2>&1); then
		printf '%s\n' "$add_out" | tail -1 >&2
		_log "label-add-failed" "$issue" "warn" "plan-parsed add failed (parse succeeded) — idempotency marker missing"
		echo "auto-parse-plans: WARN: plan-parsed add failed for #$issue — add manually to prevent re-parse" >&2
	fi
	# THEN drop plan-me so the source leaves the poll set. If THIS fails, the
	# plan-parsed marker added above still prevents re-parse (skip-guard) — so no
	# runaway, just a harmless lingering plan-me.
	if ! remove_out=$(gh issue edit "$issue" --remove-label plan-me 2>&1); then
		printf '%s\n' "$remove_out" | tail -1 >&2
		_log "label-remove-failed" "$issue" "warn" "plan-me removal failed (parse succeeded) — harmless, plan-parsed already gates re-parse"
		echo "auto-parse-plans: WARN: plan-me removal failed for #$issue — remove manually (harmless; plan-parsed gates re-parse)" >&2
	fi
}

if [ -n "$TARGET_ISSUE" ]; then
	_check_and_parse_issue "$TARGET_ISSUE"
	exit 0
fi

# Poll all open plan-me-labeled issues.
issues=$(gh issue list --label plan-me --state open --limit 500 --json number --jq '.[].number' 2>/dev/null || echo "")
if [ -z "$issues" ]; then
	_log "poll-empty" "" "info" "no plan-me-labeled open issues"
	exit 0
fi

count=0
fail=0
for issue in $issues; do
	count=$((count + 1))
	if ! _check_and_parse_issue "$issue"; then
		fail=$((fail + 1))
	fi
done
_log "poll-done" "" "info" "polled=$count failed=$fail"
exit 0
