#!/bin/bash
# auto-register: false
# v4.3.G (#374): count CR invocations in the last rolling hour from
# .claude/review-log/cr-budget.jsonl. Warns at 4/5 used; exits non-zero
# at 5/5 so Phase 2 CR CLI invocations defer until the oldest entry ages out.
#
# Usage:
#   .claude/hooks/cr-budget-check.sh [--quiet] [--json]
#
# Exit codes:
#   0 — budget healthy (< 5 in last hour, or log absent = 0 used)
#   1 — budget exhausted (>= 5 in last hour) OR log corrupt (all rows malformed, status=corrupt)
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })
LOG="$REPO_ROOT/.claude/review-log/cr-budget.jsonl"

QUIET=0
JSON=0
for a in "$@"; do
	case "$a" in
	--quiet) QUIET=1 ;;
	--json) JSON=1 ;;
	--help | -h)
		cat <<'EOF'
cr-budget-check.sh — count CR invocations in the last rolling hour.

Usage:
  .claude/hooks/cr-budget-check.sh [--quiet] [--json] [--help]

Flags:
  --quiet  suppress text output (still emits JSON if --json)
  --json   emit machine-readable JSON
  --help   print this and exit 0 regardless of budget state

Exit codes:
  0 — budget healthy (< limit per .claude/cr-config.yml)
  1 — budget exhausted (>= limit) OR log corrupt
  2 — config error (cr-config.yml missing or unparseable)
EOF
		exit 0
		;;
	esac
done

# v4.4.A: limit from `.claude/cr-config.yml` SSOT — must load BEFORE the
# no-log fast path so the "0/N used" message reflects the real config
# instead of hardcoding 5. Fail closed on config-read errors so a broken
# config doesn't silently report "budget clean".
CR_CONFIG="$REPO_ROOT/.claude/cr-config.yml"
if [ ! -f "$CR_CONFIG" ]; then
	echo "ERROR: $CR_CONFIG missing — cannot determine CR rate limit" >&2
	exit 2
fi
# Explicit yq presence check — `yq -r ... 2>/dev/null` would otherwise let a
# missing yq silently produce empty LIMIT/WARN_THRESHOLD, which the numeric
# tests below would surface as a confusing "not a number" error rather than
# the actionable "yq missing" diagnostic.
if ! command -v yq >/dev/null 2>&1; then
	echo "ERROR: yq missing — cannot parse cr-config.yml. brew install yq" >&2
	exit 2
fi
LIMIT=$(yq -r '.rate_limit_per_hour' "$CR_CONFIG" 2>/dev/null)
WARN_THRESHOLD=$(yq -r '.warn_threshold' "$CR_CONFIG" 2>/dev/null)
if ! [ "$LIMIT" -eq "$LIMIT" ] 2>/dev/null; then
	echo "ERROR: cr-config.yml rate_limit_per_hour is not a number: $LIMIT" >&2
	exit 2
fi
if ! [ "$WARN_THRESHOLD" -eq "$WARN_THRESHOLD" ] 2>/dev/null; then
	echo "ERROR: cr-config.yml warn_threshold is not a number: $WARN_THRESHOLD" >&2
	exit 2
fi

if [ ! -f "$LOG" ]; then
	# No log yet = no CR invocations tracked = budget clean
	[ "$JSON" = "1" ] && jq -nc --argjson lim "$LIMIT" '{used:0, limit:$lim, next_slot_free:null, status:"clean"}'
	[ "$QUIET" = "0" ] && [ "$JSON" = "0" ] && echo "CR budget: 0/${LIMIT} used (no log)"
	exit 0
fi

# Compute one-hour-ago cutoff in seconds since epoch
NOW=$(date -u +%s)
CUTOFF=$((NOW - 3600))

# Count entries with ts within the last 60 minutes, cross-platform date parse
# Count valid timestamps in the last-hour window. v4.3 CR round 1 fix:
# earlier form used `jq -r | while | wc -l` with the loop in a subshell;
# malformed-timestamp rows falling back to `echo 0` undercounted silently.
# Use process substitution + accumulator var in the PARENT shell.
USED=0
MALFORMED=0
while read -r ts; do
	[ -z "$ts" ] && continue
	if ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) ||
		ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null); then
		[ "$ts_epoch" -gt "$CUTOFF" ] && USED=$((USED + 1))
	else
		# Surface corruption rather than silently excluding — caller can
		# decide whether to repair or ignore.
		MALFORMED=$((MALFORMED + 1))
		echo "cr-budget-check: malformed ts '$ts' in $LOG" >&2
	fi
done < <(jq -r '.ts' "$LOG" 2>/dev/null)

# Oldest entry in the last-hour window — when it ages out, a slot frees
NEXT_FREE=""
if [ "$USED" -ge "$LIMIT" ]; then
	OLDEST=""
	while read -r ts; do
		[ -z "$ts" ] && continue
		if ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) ||
			ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null); then
			if [ "$ts_epoch" -gt "$CUTOFF" ] && [ -z "$OLDEST" ]; then
				OLDEST="$ts"
			fi
		fi
	done < <(jq -r '.ts' "$LOG" 2>/dev/null)
	if [ -n "$OLDEST" ]; then
		if OLDEST_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$OLDEST" +%s 2>/dev/null) ||
			OLDEST_EPOCH=$(date -u -d "$OLDEST" +%s 2>/dev/null); then
			FREE_EPOCH=$((OLDEST_EPOCH + 3600))
			NEXT_FREE=$(date -u -j -f "%s" "$FREE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
				date -u -d "@$FREE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
		fi
	fi
fi

STATUS="clean"
[ "$USED" -ge "$WARN_THRESHOLD" ] && STATUS="warn"
[ "$USED" -ge "$LIMIT" ] && STATUS="exhausted"
# v4.3 CR round 2: if every entry was malformed and USED=0, don't report
# "clean" — propagate the corruption so the caller can investigate rather
# than falsely thinking budget is free.
if [ "$MALFORMED" -gt 0 ] && [ "$USED" -eq 0 ]; then
	STATUS="corrupt"
fi

if [ "$JSON" = "1" ]; then
	jq -nc \
		--argjson used "$USED" \
		--argjson limit "$LIMIT" \
		--argjson malformed "$MALFORMED" \
		--arg next "$NEXT_FREE" \
		--arg status "$STATUS" \
		'{used: $used, limit: $limit, malformed: $malformed, next_slot_free: (if $next == "" then null else $next end), status: $status}'
else
	[ "$QUIET" = "0" ] && {
		MSG="CR budget: $USED/$LIMIT used in last hour ($STATUS)"
		[ "$MALFORMED" -gt 0 ] && MSG="$MSG · $MALFORMED malformed row(s)"
		[ -n "$NEXT_FREE" ] && MSG="$MSG · next slot frees at $NEXT_FREE"
		echo "$MSG"
	}
fi

[ "$USED" -ge "$LIMIT" ] && exit 1
[ "$STATUS" = "corrupt" ] && exit 1
exit 0
