#!/bin/bash
set -euo pipefail
# v0.30.A (#187): SKILL_WRAPPER=1 so skill-bypass-guard honors the gh api
# calls below (line ~114). Every other skill wrapper sets this; this one
# was missed at v0.9.0 — would have blocked the first real conflict-resolve
# fire on a guard-active branch.
export SKILL_WRAPPER=1
# v0.9.0 (#45): cr-resolve-conflict — wrap CodeRabbit's resolve-merge-conflict
# feature with comment-trigger + poll + telemetry.
#
# Behavior:
#   1. Pre-check: PR's mergeStateStatus. If not DIRTY, exit 0 (idempotent).
#   2. Post `@coderabbitai resolve merge conflict` comment.
#   3. Poll head SHA: changes BY CR = resolution → exit 0.
#   4. Poll CR replies posted AFTER trigger for decline markers → exit 2.
#   5. Timeout (default 600s) → exit 2.
#   6. JSONL log to .claude/logs/cr-resolve-conflict.jsonl per invocation
#      (jq-built JSON so free-form text is properly escaped).
#
# Opt-out: CR_RESOLVE_CONFLICT_DISABLED=1 → emit one-line stderr warning
# so callers (ship-pr-cycle) can't mistake "disabled" for "resolved" silently.

PR=""
TIMEOUT_SEC="${CR_RESOLVE_TIMEOUT_SEC:-600}"
POLL_INTERVAL=15
POLL_ERR_MAX=5
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: cr-resolve-conflict/run.sh --pr <num> [--timeout <sec>] [--dry-run]

Wraps CodeRabbit's resolve-merge-conflict feature.

Exit codes:
  0 — CR resolved the conflict, no conflict to resolve, or opt-out
  2 — CR declined or timed out
  3 — missing prerequisites, pre-check API failure, or N consecutive poll failures
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--pr)
		[ "$#" -ge 2 ] || {
			echo "error: --pr requires value" >&2
			exit 2
		}
		PR="$2"
		shift 2
		;;
	--timeout)
		[ "$#" -ge 2 ] || {
			echo "error: --timeout requires value" >&2
			exit 2
		}
		TIMEOUT_SEC="$2"
		shift 2
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown arg: $1" >&2
		usage
		exit 2
		;;
	esac
done

# Opt-out FIRST so disabled callers don't trip --pr/--timeout validation.
# Emit a clear stderr warning + telemetry so callers can't mistake disabled
# for resolved (Phase 1 silent-failure-hunter finding 9).
if [ "${CR_RESOLVE_CONFLICT_DISABLED:-0}" = "1" ]; then
	echo "cr-resolve-conflict: CR_RESOLVE_CONFLICT_DISABLED=1 — skill is a no-op; caller should NOT assume the conflict was resolved" >&2
	# Best-effort telemetry: only writes if PR was supplied + log dir resolves.
	if [ -n "${PR}" ]; then
		_log_dir="${HOME}/cr-resolve-conflict-disabled-no-log"
		# Use repo-relative log if cwd is a repo, else /tmp (loudly).
		if _repo=$(git rev-parse --show-toplevel 2>/dev/null); then
			_log_dir="${_repo}/.claude/logs"
			mkdir -p "$_log_dir" 2>/dev/null || _log_dir=""
		fi
		if [ -n "$_log_dir" ] && [ -d "$_log_dir" ]; then
			jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pr "$PR" \
				'{ts:$ts, pr:($pr|tonumber? // $pr), outcome:"disabled", decline_reason:"opt-out-env"}' \
				>>"$_log_dir/cr-resolve-conflict.jsonl" 2>/dev/null || true
		fi
	fi
	exit 0
fi

[ -n "$PR" ] || {
	echo "error: --pr <num> is required" >&2
	usage
	exit 2
}

# Validate TIMEOUT_SEC after arg-parse so CLI --timeout can override a
# malformed CR_RESOLVE_TIMEOUT_SEC env. Final value must be a positive
# integer — the poll loop uses [ -ge ] arithmetic which would blow up
# on non-numeric/negative values otherwise.
if ! [[ $TIMEOUT_SEC =~ ^[0-9]+$ ]] || [ "$TIMEOUT_SEC" -le 0 ]; then
	echo "error: timeout must be a positive integer (got '$TIMEOUT_SEC'; from --timeout or CR_RESOLVE_TIMEOUT_SEC env)" >&2
	exit 2
fi

# Prereqs: gh authed + jq present (jq is used to parse gh JSON + emit
# escaped JSONL telemetry below).
if ! command -v jq >/dev/null 2>&1; then
	echo "cr-resolve-conflict: jq not found in PATH — refusing (rc=3)" >&2
	exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
	echo "cr-resolve-conflict: gh not authed — refusing (rc=3)" >&2
	exit 3
fi

# Resolve repo root for JSONL log; warn LOUDLY if falling back to /tmp so
# operators don't search .claude/logs in vain (Phase 1 silent-failure
# finding 7).
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	LOG_DIR="$REPO_ROOT/.claude/logs"
	if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
		echo "cr-resolve-conflict: cannot create $LOG_DIR — refusing (rc=3)" >&2
		exit 3
	fi
	LOG_FILE="$LOG_DIR/cr-resolve-conflict.jsonl"
else
	echo "cr-resolve-conflict: not in a git repo — telemetry will write to /tmp/cr-resolve-conflict.jsonl (volatile)" >&2
	LOG_FILE="/tmp/cr-resolve-conflict.jsonl"
fi

# _log_event builds JSON via jq so free-form text (decline_reason, head SHAs)
# is properly escaped — bare printf '%s' would emit invalid JSON if reason
# contained a quote or newline (Phase 1 silent-failure finding 8).
# Args: outcome, head_before, head_after, duration_sec, optional reason.
# Append failure is surfaced to stderr but doesn't abort under set -e.
_log_event() {
	local outcome=$1 head_before=$2 head_after=$3 duration=$4 reason=${5:-}
	local payload
	payload=$(jq -cn \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg pr "$PR" \
		--arg hb "$head_before" \
		--arg ha "$head_after" \
		--arg outcome "$outcome" \
		--argjson dur "$duration" \
		--arg reason "$reason" \
		'{ts:$ts, pr:($pr|tonumber? // $pr), head_before:$hb, head_after:$ha, outcome:$outcome, duration_seconds:$dur}
		 + (if $reason != "" then {decline_reason:$reason} else {} end)')
	if ! printf '%s\n' "$payload" >>"$LOG_FILE" 2>/dev/null; then
		echo "cr-resolve-conflict: failed to append telemetry to $LOG_FILE" >&2
	fi
}

# Pre-check PR state. Capture stderr separately so failure messages reach
# both operator + telemetry (Phase 1 silent-failure finding 5).
if ! PR_STATE=$(gh pr view "$PR" --json mergeStateStatus,mergeable,headRefOid 2>&1); then
	echo "cr-resolve-conflict: failed to fetch PR #$PR: $PR_STATE — refusing (rc=3)" >&2
	_log_event "prereq-failed" "" "" 0 "pr-view-failed"
	exit 3
fi
MERGE_STATE=$(echo "$PR_STATE" | jq -r '.mergeStateStatus // ""')
MERGEABLE=$(echo "$PR_STATE" | jq -r '.mergeable // ""')
HEAD_BEFORE=$(echo "$PR_STATE" | jq -r '.headRefOid // ""')

# Validate parsed fields — if gh returns unexpected JSON shape, jq emits
# null/empty and the no-conflict branch below would silently no-op on a
# real conflict (Phase 1 silent-failure finding 6).
if [ -z "$MERGE_STATE" ] || [ "$MERGE_STATE" = "null" ] ||
	[ -z "$MERGEABLE" ] || [ "$MERGEABLE" = "null" ] ||
	[ -z "$HEAD_BEFORE" ] || [ "$HEAD_BEFORE" = "null" ]; then
	echo "cr-resolve-conflict: PR state JSON malformed (merge='$MERGE_STATE' mergeable='$MERGEABLE' head='$HEAD_BEFORE') — refusing (rc=3)" >&2
	_log_event "prereq-failed" "" "" 0 "json-parse-failed"
	exit 3
fi

# Capture original baseline separately for telemetry, so a non-CR commit
# landing mid-poll doesn't rewrite the head_before logged at exit (Phase 1
# code-reviewer finding: log contract).
HEAD_ORIG="$HEAD_BEFORE"

# Strict no-conflict gate: only proceed when BOTH fields say conflict.
if [ "$MERGE_STATE" != "DIRTY" ] || [ "$MERGEABLE" != "CONFLICTING" ]; then
	echo "cr-resolve-conflict: PR #$PR not in conflict state (merge=$MERGE_STATE mergeable=$MERGEABLE) — nothing to do (rc=0)" >&2
	_log_event "no-conflict" "$HEAD_ORIG" "$HEAD_ORIG" 0 ""
	exit 0
fi

echo "cr-resolve-conflict: PR #$PR in conflict (merge=$MERGE_STATE) — invoking CR resolver" >&2

if [ "$DRY_RUN" = "1" ]; then
	echo "cr-resolve-conflict: --dry-run — would post '@coderabbitai resolve merge conflict' and poll up to ${TIMEOUT_SEC}s" >&2
	_log_event "dry-run" "$HEAD_ORIG" "$HEAD_ORIG" 0 ""
	exit 0
fi

# Post the trigger comment. Capture stderr for actionable diagnostics
# (Phase 1 silent-failure finding 4).
START_TS=$(date +%s)
if ! _comment_err=$(gh pr comment "$PR" --body "@coderabbitai resolve merge conflict" 2>&1 >/dev/null); then
	echo "cr-resolve-conflict: failed to post comment on PR #$PR: $_comment_err — refusing (rc=3)" >&2
	# Truncate reason to avoid JSON-injection from gh stderr.
	_reason=$(printf '%s' "$_comment_err" | tr -d '\r' | head -c 200)
	_log_event "comment-failed" "$HEAD_ORIG" "$HEAD_ORIG" 0 "$_reason"
	exit 3
fi

echo "cr-resolve-conflict: posted '@coderabbitai resolve merge conflict' — polling for outcome (timeout ${TIMEOUT_SEC}s)" >&2

# Poll loop. Tracks consecutive API failures separately from "no change"
# so transient gh outages don't masquerade as CR-slowness (Phase 1
# silent-failure findings 1-3).
POLL_ERR_COUNT=0
while true; do
	NOW=$(date +%s)
	ELAPSED=$((NOW - START_TS))
	if [ "$ELAPSED" -ge "$TIMEOUT_SEC" ]; then
		echo "cr-resolve-conflict: timeout after ${ELAPSED}s — treating as decline (rc=2)" >&2
		_log_event "timeout" "$HEAD_ORIG" "$HEAD_BEFORE" "$ELAPSED" "timeout-${TIMEOUT_SEC}s"
		exit 2
	fi

	# Check head SHA — did CR push a resolution? Treat API failure
	# distinctly from "no change yet" to avoid hiding outages.
	if ! HEAD_AFTER=$(gh pr view "$PR" --json headRefOid --jq '.headRefOid' 2>&1); then
		POLL_ERR_COUNT=$((POLL_ERR_COUNT + 1))
		echo "cr-resolve-conflict: gh pr view failed (${POLL_ERR_COUNT}/${POLL_ERR_MAX}): $HEAD_AFTER" >&2
		_log_event "poll-error" "$HEAD_ORIG" "$HEAD_BEFORE" "$ELAPSED" "gh-pr-view-failed"
		if [ "$POLL_ERR_COUNT" -ge "$POLL_ERR_MAX" ]; then
			echo "cr-resolve-conflict: gh failing repeatedly — aborting (rc=3)" >&2
			exit 3
		fi
		sleep "$POLL_INTERVAL"
		continue
	fi

	if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ]; then
		# Verify the commit author — operator force-push mid-poll would
		# otherwise be mistaken for CR's resolution.
		if ! LATEST_AUTHOR=$(gh api "repos/{owner}/{repo}/commits/$HEAD_AFTER" --jq '.author.login // ""' 2>&1); then
			POLL_ERR_COUNT=$((POLL_ERR_COUNT + 1))
			echo "cr-resolve-conflict: commit-author lookup failed (${POLL_ERR_COUNT}/${POLL_ERR_MAX}): $LATEST_AUTHOR — will retry" >&2
			_log_event "poll-error" "$HEAD_ORIG" "$HEAD_AFTER" "$ELAPSED" "author-lookup-failed"
			if [ "$POLL_ERR_COUNT" -ge "$POLL_ERR_MAX" ]; then
				echo "cr-resolve-conflict: gh failing repeatedly — aborting (rc=3)" >&2
				exit 3
			fi
			sleep "$POLL_INTERVAL"
			continue
		fi
		if [ "$LATEST_AUTHOR" = "coderabbitai[bot]" ] || [ "$LATEST_AUTHOR" = "coderabbitai" ]; then
			echo "cr-resolve-conflict: CR pushed resolution ($HEAD_ORIG -> $HEAD_AFTER) — success (rc=0)" >&2
			_log_event "resolved" "$HEAD_ORIG" "$HEAD_AFTER" "$ELAPSED" ""
			exit 0
		fi
		echo "cr-resolve-conflict: head changed ($HEAD_BEFORE -> $HEAD_AFTER) but author='$LATEST_AUTHOR' (not CR) — continuing poll" >&2
		# Update polling baseline so we don't re-check the same external
		# commit. HEAD_ORIG stays for telemetry.
		HEAD_BEFORE="$HEAD_AFTER"
		POLL_ERR_COUNT=0
	fi

	# Check latest CR comment for decline markers. Filter by timestamp
	# (only comments posted AFTER our trigger) so an old chatty CR comment
	# mentioning "manual" doesn't false-decline (Phase 1 silent-failure
	# finding 10 + code-simplifier finding 2 + comment-analyzer finding 1).
	# Match both `coderabbitai` and `coderabbitai[bot]` authors.
	# Marker phrases anchored — no bare-word `manual` substring traps.
	# shellcheck disable=SC2016  # jq expression, $since is a jq var not a shell var
	if ! LATEST_CR=$(gh pr view "$PR" --json comments --jq --argjson since "$START_TS" \
		'[.comments[]
		  | select((.author.login == "coderabbitai" or .author.login == "coderabbitai[bot]")
		           and ((.createdAt | fromdateiso8601) >= $since))]
		 | last | .body // ""' 2>&1); then
		POLL_ERR_COUNT=$((POLL_ERR_COUNT + 1))
		echo "cr-resolve-conflict: comment-fetch failed (${POLL_ERR_COUNT}/${POLL_ERR_MAX}): $LATEST_CR — will retry" >&2
		_log_event "poll-error" "$HEAD_ORIG" "$HEAD_BEFORE" "$ELAPSED" "comment-fetch-failed"
		if [ "$POLL_ERR_COUNT" -ge "$POLL_ERR_MAX" ]; then
			echo "cr-resolve-conflict: gh failing repeatedly — aborting (rc=3)" >&2
			exit 3
		fi
		sleep "$POLL_INTERVAL"
		continue
	fi
	# Successful comment fetch — reset error counter.
	POLL_ERR_COUNT=0

	# Phrase-anchored decline markers (Phase 1 code-reviewer + code-simplifier
	# + comment-analyzer + silent-failure all flagged the bare `manual`).
	if echo "$LATEST_CR" | grep -qiE "(unable to resolve|cannot automatically (resolve|merge)|declined to resolve|ambiguous conflict|security-critical|requires manual (rebase|resolution|intervention|review))"; then
		REASON=$(echo "$LATEST_CR" | grep -oiE "(unable to resolve|cannot automatically (resolve|merge)|declined to resolve|ambiguous conflict|security-critical|requires manual (rebase|resolution|intervention|review))" | head -1 | tr '[:upper:]' '[:lower:]')
		echo "cr-resolve-conflict: CR declined (reason='$REASON') — falling back to manual (rc=2)" >&2
		_log_event "declined" "$HEAD_ORIG" "$HEAD_BEFORE" "$ELAPSED" "$REASON"
		exit 2
	fi

	sleep "$POLL_INTERVAL"
done
