#!/bin/bash
set -euo pipefail
# v0.9.0 (#45): cr-resolve-conflict — wrap CodeRabbit's resolve-merge-conflict
# feature with comment-trigger + poll + telemetry.
#
# Behavior:
#   1. Pre-check: PR's mergeStateStatus. If not DIRTY, exit 0 (idempotent).
#   2. Post `@coderabbitai resolve merge conflict` comment.
#   3. Poll head SHA: changes = CR pushed a resolution → exit 0.
#   4. Poll latest CR reply for decline markers → exit 2.
#   5. Timeout (default 600s) → exit 2.
#   6. JSONL log to .claude/logs/cr-resolve-conflict.jsonl per invocation.
#
# Opt-out: CR_RESOLVE_CONFLICT_DISABLED=1 → silent no-op.

PR=""
TIMEOUT_SEC="${CR_RESOLVE_TIMEOUT_SEC:-600}"
POLL_INTERVAL=15
DRY_RUN=0

usage() {
	cat <<'EOF'
Usage: cr-resolve-conflict/run.sh --pr <num> [--timeout <sec>] [--dry-run]

Wraps CodeRabbit's resolve-merge-conflict feature.

Exit codes:
  0 — CR resolved the conflict (or no conflict to resolve)
  2 — CR declined or timed out
  3 — missing prerequisites (gh not authed, pre-check API failure, etc.)
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

# Opt-out: silent no-op per SKILL.md contract. Runs BEFORE input validation
# so a disabled invocation never surfaces "--pr required" or "bad timeout"
# noise. Operators expect `CR_RESOLVE_CONFLICT_DISABLED=1` to mean "stay
# out of the way, no matter what else is wrong with the call."
if [ "${CR_RESOLVE_CONFLICT_DISABLED:-0}" = "1" ]; then
	exit 0
fi

[ -n "$PR" ] || {
	echo "error: --pr <num> is required" >&2
	usage
	exit 2
}

# Validate TIMEOUT_SEC after arg-parse so CLI --timeout can override a
# malformed CR_RESOLVE_TIMEOUT_SEC env. Final value (CLI > env > default)
# must be a positive integer — the poll loop uses [ -ge ] arithmetic which
# would blow up on non-numeric/negative values otherwise.
if ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_SEC" -le 0 ]; then
	echo "error: timeout must be a positive integer (got '$TIMEOUT_SEC'; from --timeout or CR_RESOLVE_TIMEOUT_SEC env)" >&2
	exit 2
fi

# Resolve repo root for JSONL log; fall back to /tmp if outside a repo.
if REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	LOG_DIR="$REPO_ROOT/.claude/logs"
	mkdir -p "$LOG_DIR"
	LOG_FILE="$LOG_DIR/cr-resolve-conflict.jsonl"
else
	LOG_FILE="/tmp/cr-resolve-conflict.jsonl"
fi

# Prereqs: gh authed + jq present (jq is used to parse gh JSON output below).
if ! command -v jq >/dev/null 2>&1; then
	echo "cr-resolve-conflict: jq not found in PATH — refusing (rc=3)" >&2
	exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
	echo "cr-resolve-conflict: gh not authed — refusing (rc=3)" >&2
	exit 3
fi

_log_event() {
	# Append a JSONL event to the log. Args: outcome, head_before, head_after,
	# duration_sec, optional decline_reason.
	local outcome=$1 head_before=$2 head_after=$3 duration=$4 reason=${5:-}
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	if [ -n "$reason" ]; then
		printf '{"ts":"%s","pr":%s,"head_before":"%s","head_after":"%s","outcome":"%s","duration_seconds":%d,"decline_reason":"%s"}\n' \
			"$ts" "$PR" "$head_before" "$head_after" "$outcome" "$duration" "$reason" >>"$LOG_FILE"
	else
		printf '{"ts":"%s","pr":%s,"head_before":"%s","head_after":"%s","outcome":"%s","duration_seconds":%d}\n' \
			"$ts" "$PR" "$head_before" "$head_after" "$outcome" "$duration" >>"$LOG_FILE"
	fi
}

# Pre-check PR state.
PR_STATE=$(gh pr view "$PR" --json mergeStateStatus,mergeable,headRefOid 2>/dev/null || {
	echo "cr-resolve-conflict: failed to fetch PR #$PR — refusing (rc=3)" >&2
	exit 3
})
MERGE_STATE=$(echo "$PR_STATE" | jq -r '.mergeStateStatus')
MERGEABLE=$(echo "$PR_STATE" | jq -r '.mergeable')
HEAD_BEFORE=$(echo "$PR_STATE" | jq -r '.headRefOid')

# Strict no-conflict gate: only proceed when BOTH fields say conflict.
# Using `||` here means we exit-clean if EITHER mergeStateStatus != DIRTY
# OR mergeable != CONFLICTING — so the CR resolver only fires when GitHub
# is confident the PR is in conflict, not on transient UNKNOWN states.
if [ "$MERGE_STATE" != "DIRTY" ] || [ "$MERGEABLE" != "CONFLICTING" ]; then
	echo "cr-resolve-conflict: PR #$PR not in conflict state (merge=$MERGE_STATE mergeable=$MERGEABLE) — nothing to do (rc=0)" >&2
	_log_event "no-conflict" "$HEAD_BEFORE" "$HEAD_BEFORE" 0 ""
	exit 0
fi

echo "cr-resolve-conflict: PR #$PR in conflict (merge=$MERGE_STATE) — invoking CR resolver" >&2

if [ "$DRY_RUN" = "1" ]; then
	echo "cr-resolve-conflict: --dry-run — would post '@coderabbitai resolve merge conflict' and poll up to ${TIMEOUT_SEC}s" >&2
	_log_event "dry-run" "$HEAD_BEFORE" "$HEAD_BEFORE" 0 ""
	exit 0
fi

# Post the trigger comment.
START_TS=$(date +%s)
if ! gh pr comment "$PR" --body "@coderabbitai resolve merge conflict" >/dev/null 2>&1; then
	echo "cr-resolve-conflict: failed to post comment — refusing (rc=3)" >&2
	_log_event "comment-failed" "$HEAD_BEFORE" "$HEAD_BEFORE" 0 ""
	exit 3
fi

echo "cr-resolve-conflict: posted '@coderabbitai resolve merge conflict' — polling for outcome (timeout ${TIMEOUT_SEC}s)" >&2

# Poll loop.
while true; do
	NOW=$(date +%s)
	ELAPSED=$((NOW - START_TS))
	if [ "$ELAPSED" -ge "$TIMEOUT_SEC" ]; then
		echo "cr-resolve-conflict: timeout after ${ELAPSED}s — treating as decline (rc=2)" >&2
		_log_event "timeout" "$HEAD_BEFORE" "$HEAD_BEFORE" "$ELAPSED" "timeout-${TIMEOUT_SEC}s"
		exit 2
	fi

	# Check head SHA — did CR push a resolution?
	# Verify the commit author: an operator force-push during the poll window
	# would otherwise be mistaken for CR's resolution. Per CR docs, if an
	# external commit lands while CR is resolving, CR aborts — we shouldn't
	# claim success in that case.
	HEAD_AFTER=$(gh pr view "$PR" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "$HEAD_BEFORE")
	if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ]; then
		LATEST_AUTHOR=$(gh api "repos/{owner}/{repo}/commits/$HEAD_AFTER" --jq '.author.login // ""' 2>/dev/null || echo "")
		if [ "$LATEST_AUTHOR" = "coderabbitai[bot]" ] || [ "$LATEST_AUTHOR" = "coderabbitai" ]; then
			echo "cr-resolve-conflict: CR pushed resolution ($HEAD_BEFORE -> $HEAD_AFTER) — success (rc=0)" >&2
			_log_event "resolved" "$HEAD_BEFORE" "$HEAD_AFTER" "$ELAPSED" ""
			exit 0
		fi
		echo "cr-resolve-conflict: head changed ($HEAD_BEFORE -> $HEAD_AFTER) but author='$LATEST_AUTHOR' (not CR) — continuing poll" >&2
		# Update baseline so we don't keep re-checking the same external commit.
		HEAD_BEFORE="$HEAD_AFTER"
	fi

	# Check latest CR comment for decline markers.
	# Match both `coderabbitai` and `coderabbitai[bot]` authors (CR uses
	# either depending on context). Marker list aligned with SKILL.md.
	LATEST_CR=$(gh pr view "$PR" --json comments --jq '[.comments[] | select(.author.login == "coderabbitai" or .author.login == "coderabbitai[bot]")] | last | .body // ""' 2>/dev/null || echo "")
	if echo "$LATEST_CR" | grep -qiE "(unable to resolve|decline|ambiguous|security-critical|requires manual|cannot automatically|manual)"; then
		# Extract a short reason for logging.
		REASON=$(echo "$LATEST_CR" | grep -oiE "(unable to resolve|decline|ambiguous|security-critical|requires manual|cannot automatically|manual)" | head -1 | tr '[:upper:]' '[:lower:]')
		echo "cr-resolve-conflict: CR declined (reason='$REASON') — falling back to manual (rc=2)" >&2
		_log_event "declined" "$HEAD_BEFORE" "$HEAD_BEFORE" "$ELAPSED" "$REASON"
		exit 2
	fi

	sleep "$POLL_INTERVAL"
done
