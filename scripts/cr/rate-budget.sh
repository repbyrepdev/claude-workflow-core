#!/bin/bash
set -euo pipefail
# v4.21 (#520): report the prepaid CodeRabbit rate budget status.
# v4.28-W2 (post-merge 2026-05-04): bumped --limit default 5 → 10 to match
# CR Pro Plus seat (CR's walkthrough now reports "10 reviews remaining,
# refill in 6 minutes" — see PR #683 walkthrough comment for the
# authoritative source). Refill cadence is per-token (60min/10 = 6min)
# rather than rolling-60-minute-window, but the rolling-window count is
# still a safe approximation: under steady use both models converge on
# the same "max 10 reviews per hour" cap. Override with --limit if the
# seat tier changes.
# Reads `.claude/review-log/cr-budget.jsonl` (if present) and computes
# how many invocations occurred in the rolling 60-minute window.
#
# Usage:
#   .claude/scripts/cr/rate-budget.sh           # table
#   .claude/scripts/cr/rate-budget.sh --json    # machine-readable
#   .claude/scripts/cr/rate-budget.sh --check   # exit 1 if budget near-full
#
# Budget source: the existing `cr-log-invocation.sh` hook logs each CR
# invocation (CLI + CI-triggered) to `.claude/review-log/cr-budget.jsonl`.
# If the log doesn't exist yet, we report "no data yet" (not a failure —
# the log is created lazily).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
# shellcheck source=../_common.sh
source "$REPO_ROOT/.claude/scripts/_common.sh"

FORMAT="table"
CHECK=0
MARK_EXHAUSTED=0
# v4.28-W2 (post-merge 2026-05-04): default 10 (CR Pro Plus). Override
# with --limit on free / Pro tiers. CR's own walkthrough is the
# authoritative source if the seat tier changes.
LIMIT=10
while [ $# -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT="json"
		shift
		;;
	--check)
		CHECK=1
		shift
		;;
	mark-exhausted)
		# #778: write an "exhausted" marker entry so subsequent --check
		# invocations see the actual server-side state, not the local-
		# approximation. Caller (local-review.sh) invokes this when CR
		# CLI returns "out of usage credits" — the local rolling-window
		# count was wrong but the user already burned the attempt.
		MARK_EXHAUSTED=1
		shift
		;;
	--limit)
		LIMIT="${2:?}"
		# CR-CI r13 fix: regex must reject 0. Phase 3 added
		# `PER_TOKEN_CAP=$((60 / LIMIT))` which div-by-zeroes on
		# --limit 0; the prior `^[0-9]+$` permitted it. Tighten to
		# positive integer so the inline comment ("validated >0")
		# matches the code.
		[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || scm_fail "--limit must be a positive integer; got '$LIMIT'"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*) scm_fail "unknown arg: $1" ;;
	esac
done

LOG="$REPO_ROOT/.claude/review-log/cr-budget.jsonl"

# #778: mark-exhausted writes a sentinel entry so future --check calls
# see the server-side exhausted state (was: local tracker reported "OK"
# while CR CLI returned "out of usage credits"). The entry uses a
# distinct `kind=exhausted` field and ages out with the rolling 60-min
# window (see CUTOFF below).
if [ "$MARK_EXHAUSTED" = "1" ]; then
	mkdir -p "$(dirname "$LOG")" 2>/dev/null || scm_fail "cannot create $(dirname "$LOG")"
	now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	now_epoch=$(date +%s)
	# silent-failure-hunter Phase 1 r1 MEDIUM: validate now_epoch is
	# numeric before --argjson — a non-numeric value would write
	# ts_epoch: null and the marker would be silently ignored forever.
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || scm_fail "date +%s returned non-numeric: '$now_epoch'"
	# silent-failure-hunter Phase 1 r1 CRITICAL: atomic append via
	# tempfile + cat append. Concurrent CR-error detections (parallel
	# agents both hitting out-of-credits) could otherwise interleave
	# jq's stdout bytes across multi write() calls, corrupting the
	# JSONL. tempfile guarantees jq finished writing before the cat
	# append starts; single PIPE_BUF-sized line under O_APPEND is
	# atomic per POSIX.
	tmp_marker=$(mktemp -t cr-rb-exhaust.XXXXXX) || scm_fail "mktemp failed for marker write"
	jq -nc --arg ts "$now_iso" --argjson e "$now_epoch" \
		'{ts: $ts, ts_epoch: $e, kind: "exhausted", source: "cr-cli-error"}' \
		>"$tmp_marker" || {
		rm -f "$tmp_marker"
		scm_fail "jq write to $tmp_marker failed"
	}
	cat "$tmp_marker" >>"$LOG" || {
		rm -f "$tmp_marker"
		scm_fail "cannot append exhausted marker to $LOG"
	}
	rm -f "$tmp_marker"
	echo "rate-budget: exhausted marker written ($now_iso)" >&2
	exit 0
fi

if [ ! -f "$LOG" ]; then
	case "$FORMAT" in
	json) echo '{"count": 0, "limit": '"$LIMIT"', "remaining": '"$LIMIT"', "status": "no-data"}' ;;
	table) echo "CR budget: no log at $LOG (no invocations recorded yet)" ;;
	esac
	exit 0
fi

# Rolling 60-minute window via portable epoch arithmetic.
NOW=$(date +%s)
CUTOFF=$((NOW - 3600))

# #778: short-circuit when an "exhausted" marker is in the rolling
# window. CR CLI returned "out of usage credits" within the last hour —
# count is unreliable (CR's accounting may differ from ours). Surface
# this as authoritative status=exhausted so callers don't burn another
# attempt before the window rotates.
# silent-failure-hunter Phase 1 r1 CRITICAL: fail-closed on jq error
# (not fail-open "echo 0"). A malformed log was the silent-failure
# the prior 2>/dev/null masked — exactly the "tracker drift" bug this
# PR exists to fix. Capture rc + emit scm_warn instead.
EXH_JQ_ERR=$(mktemp 2>/dev/null) || EXH_JQ_ERR=/dev/null
EXH_JQ_RC=0
EXHAUSTED_IN_WINDOW=$(jq -s --argjson cutoff "$CUTOFF" '
	[.[] | select((.kind? // "") == "exhausted") | (.ts_epoch? // 0)
	 | select(. >= $cutoff)] | length
' "$LOG" 2>"$EXH_JQ_ERR") || EXH_JQ_RC=$?
if [ "$EXH_JQ_RC" -ne 0 ]; then
	scm_warn "rate-budget: exhausted-marker check failed (rc=$EXH_JQ_RC): $(head -c 200 "$EXH_JQ_ERR" 2>/dev/null)"
	# Fail-closed for --check (don't let drift cause invisible CR
	# exhaustion past the gate); --json surfaces status=error so
	# callers see the broken state explicitly.
	if [ "$CHECK" = "1" ]; then
		[ "$EXH_JQ_ERR" != /dev/null ] && rm -f "$EXH_JQ_ERR"
		exit 1
	fi
	EXHAUSTED_IN_WINDOW=0
fi
[ "$EXH_JQ_ERR" != /dev/null ] && rm -f "$EXH_JQ_ERR"
if [ "${EXHAUSTED_IN_WINDOW:-0}" -gt 0 ]; then
	case "$FORMAT" in
	json)
		jq -nc --arg limit "$LIMIT" \
			'{count: ($limit|tonumber), limit: ($limit|tonumber), remaining: 0, status: "exhausted", source: "server-side-marker"}'
		;;
	table)
		echo "CodeRabbit rate budget:"
		echo "  status:    EXHAUSTED (server-side marker within 60-min window)"
		echo "  source:    CR CLI returned out-of-credits — wait for window to rotate"
		;;
	esac
	[ "$CHECK" = "1" ] && exit 1
	exit 0
fi

# Each log line is JSON with a `ts` field (ISO-8601 UTC) or `ts_epoch`.
# Count entries whose ts is >= cutoff. Malformed records coerce to 0
# via the `// 0` fallbacks, then get filtered by the `>= cutoff` gate —
# jq never bombs on a bad record and the cutoff drops them.
JQ_OK=1
COUNT=$(jq -s --argjson cutoff "$CUTOFF" '
  [.[] | select((.kind? // "") != "exhausted")
       | (.ts_epoch? // (.ts? | fromdateiso8601? // 0))
       | select(. >= $cutoff)]
  | length
' "$LOG" 2>&1) || {
	scm_warn "jq parse of cr-budget.jsonl failed — log may be malformed"
	COUNT=0
	JQ_OK=0
}
# Malformed log ≠ clean budget: if jq failed we can't assert "ok" no matter
# how few entries were counted. Surface via status="error" in JSON + exit 1
# under --check (so callers that gate on --check don't silently proceed
# after a logger corruption).
if [ "$JQ_OK" = "0" ]; then
	case "$FORMAT" in
	json)
		jq -nc '{count: 0, limit: '"$LIMIT"', remaining: 0, status: "error", error: "jq_parse_failed"}'
		;;
	table)
		# Mirror the happy-path table format: primary message to stdout
		# (operators skimming stdout after a pipe shouldn't miss that
		# the budget is unknown) + detail to stderr for log consumers.
		echo "CR budget: UNKNOWN — cr-budget.jsonl parse failed"
		echo "CR budget: UNKNOWN — jq parse failed (see scm_warn above)" >&2
		;;
	esac
	[ "$CHECK" = "1" ] && exit 1
	exit 0
fi

REMAINING=$((LIMIT - COUNT))
[ "$REMAINING" -lt 0 ] && REMAINING=0

# v4.28-W4 (#711): minutes until next token refill.
# Per-token cadence is 60min / LIMIT (Pro Plus 60/10=6, Pro 60/5=12, etc).
# CR-CI fix: derive cap from $LIMIT not hardcoded 6 — the script accepts
# --limit as the seat-tier override, so the JSON contract must honor it
# in refill_in_min too.
#   window_aging = 60 - oldest_in_window_age_min   # when the oldest entry
#                                                   # ages out and frees a slot
#   per_token_cap = 60 / LIMIT                      # tier-derived cadence
#   refill = MIN(window_aging, per_token_cap)
# The cap is constant FOR a given LIMIT, NOT measured from "minutes since
# most recent use". CR's own walkthrough reports "refill in 6 minutes"
# under Pro Plus (LIMIT=10) — math matches.
REFILL_IN_MIN=""
if [ "$COUNT" -gt 0 ]; then
	# r1 SFH #3 (HIGH) fix: distinguish "null = no records >= cutoff"
	# (legitimate) from "jq failed" (silent failure). Capture jq rc +
	# stderr; on jq failure emit WARN so operator sees refill ETA
	# isn't broken silently — defeats #711's whole visibility goal.
	REFILL_JQ_ERR=$(mktemp 2>/dev/null) || REFILL_JQ_ERR=/dev/null
	REFILL_JQ_RC=0
	OLDEST_AGE_MIN=$(jq -s --argjson cutoff "$CUTOFF" --argjson now "$NOW" '
		[.[] | (.ts_epoch? // (.ts? | fromdateiso8601? // 0))
		 | select(. >= $cutoff)]
		| min as $oldest
		| if $oldest == null then null
		  else (($now - $oldest) / 60 | floor)
		  end
	' "$LOG" 2>"$REFILL_JQ_ERR") || REFILL_JQ_RC=$?
	if [ "$REFILL_JQ_RC" -ne 0 ]; then
		scm_warn "rate-budget: refill_in_min jq failed (rc=$REFILL_JQ_RC) — refill ETA disabled: $(head -c 200 "$REFILL_JQ_ERR")"
		OLDEST_AGE_MIN="null"
	fi
	rm -f "$REFILL_JQ_ERR"
	if [ -n "$OLDEST_AGE_MIN" ] && [ "$OLDEST_AGE_MIN" != "null" ]; then
		# Window aging: 60 - oldest_age. Cap: 60/LIMIT (per-token cadence
		# at this tier). Take MIN — whichever frees a slot sooner.
		# LIMIT is already validated >0 (numeric regex at arg-parse).
		WINDOW_REFILL=$((60 - OLDEST_AGE_MIN))
		[ "$WINDOW_REFILL" -lt 0 ] && WINDOW_REFILL=0
		PER_TOKEN_CAP=$((60 / LIMIT))
		if [ "$WINDOW_REFILL" -lt "$PER_TOKEN_CAP" ]; then
			REFILL_IN_MIN="$WINDOW_REFILL"
		else
			REFILL_IN_MIN="$PER_TOKEN_CAP"
		fi
	fi
fi

case "$FORMAT" in
json)
	jq -nc --arg count "$COUNT" --arg limit "$LIMIT" --arg rem "$REMAINING" --arg refill "$REFILL_IN_MIN" \
		'{count: ($count|tonumber), limit: ($limit|tonumber), remaining: ($rem|tonumber),
		  refill_in_min: (if $refill == "" then null else ($refill|tonumber) end),
		  status: (if ($count|tonumber) >= ($limit|tonumber) then "exhausted" elif ($rem|tonumber) <= 1 then "warning" else "ok" end)}'
	;;
table)
	echo "CodeRabbit rate budget (rolling 60 min):"
	echo "  used:      $COUNT / $LIMIT"
	echo "  remaining: $REMAINING"
	if [ "$COUNT" -ge "$LIMIT" ]; then
		echo "  status:    EXHAUSTED (next run allowed after the earliest entry ages out)"
	elif [ "$REMAINING" -le 1 ]; then
		echo "  status:    WARNING — only $REMAINING invocation(s) left this hour"
	else
		echo "  status:    OK"
	fi
	;;
esac

if [ "$CHECK" = "1" ] && [ "$REMAINING" -le 1 ]; then
	exit 1
fi
