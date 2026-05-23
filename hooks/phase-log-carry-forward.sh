#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W5 (#788 follow-up) — content-aware review-log carry-forward.
#
# When the diff PREV_SHA..HEAD_SHA contains no agent-relevant files
# (per agent-relevant-files.sh), the most-recent clean Phase 1 round
# at PREV_SHA is still valid at HEAD_SHA. Without this helper, the
# pre-push gate's tuple-walk sees no Phase 1 entries for HEAD_SHA and
# restarts the clean-streak counter, forcing redundant re-reviews.
#
# Usage:
#   .claude/hooks/phase-log-carry-forward.sh <prev_sha> <head_sha>
#
# Behavior:
# - Reads .claude/review-log/<prev_sha>.jsonl
# - Finds the most-recent round where ALL expected agents reported
#   findings=0 AND status in {ok, not-installed, not-applicable}
# - Appends those entries to .claude/review-log/<head_sha>.jsonl with
#   .sha updated to head_sha (round preserved — pre-push gate dedupes
#   on (sha, round) tuple, so same-round on different SHAs is distinct)
#
# Exit codes:
#   0 — carry-forward succeeded (entries appended)
#   1 — nothing to carry forward (no clean round in prev's log, or
#       prev's log missing)
#   2 — tooling broken (jq missing, head_sha invalid, write failed)
#
# WHY: PR #782 cycled 11 phase 0.5 + 25 phase 1 rounds across 20
# commits. Many commits were review-driven (audit-log appends, memory
# updates, comment-only .sh fixes) — every commit reset the streak
# counter, forcing re-runs. Carry-forward + agent-relevant-files lets
# the streak persist across irrelevant commits without re-litigating
# already-reviewed code.

PREV_SHA="${1:-}"
HEAD_SHA="${2:-}"

if [ -z "$PREV_SHA" ] || [ -z "$HEAD_SHA" ]; then
	echo "Usage: $0 <prev_sha> <head_sha>" >&2
	exit 2
fi
# CR PR #790 r16 phase2 MAJOR: validate SHA inputs are hex-only to
# prevent path-traversal injection (PREV_SHA / HEAD_SHA flow into
# PREV_LOG / HEAD_LOG file paths below). Reject anything with slashes,
# dots, or non-hex chars before constructing the path strings. The
# bats test fixtures use names like "prevsha" / "headsha" (alpha-only,
# no separators) which match this regex.
for sha in "$PREV_SHA" "$HEAD_SHA"; do
	[[ "$sha" =~ ^[0-9a-fA-F]+$ ]] || {
		echo "ERROR: invalid commit sha '$sha' — must be hex chars only" >&2
		exit 2
	}
done
if [ "$PREV_SHA" = "$HEAD_SHA" ]; then
	echo "ERROR: prev_sha equals head_sha — no carry-forward needed" >&2
	exit 2
fi

command -v jq >/dev/null || {
	echo "ERROR: jq not installed" >&2
	exit 2
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; })
LOG_DIR="$REPO_ROOT/.claude/review-log"
PREV_LOG="$LOG_DIR/${PREV_SHA}.jsonl"
HEAD_LOG="$LOG_DIR/${HEAD_SHA}.jsonl"

if [ ! -f "$PREV_LOG" ]; then
	echo "phase-log-carry-forward: no log at $PREV_LOG — nothing to carry" >&2
	exit 1
fi

LIST_SCRIPT="$(dirname "$0")/list-phase1-agents.sh"
if [ ! -x "$LIST_SCRIPT" ]; then
	echo "ERROR: $LIST_SCRIPT missing" >&2
	exit 2
fi
# CR PR #790: capture stderr + rc so a yq-missing / corrupt-config /
# bad-ref failure surfaces the real cause instead of the generic
# "returned no agents" misattribution.
list_err=$(mktemp) || {
	echo "ERROR: mktemp failed for list_err stderr capture — TMPDIR broken" >&2
	exit 2
}
# #789 item #2: derive baseref from review-config.yml (SSOT) instead of
# hardcoding `main`. PRs that target a non-main base would otherwise
# get the wrong expected-agent set.
# CR PR #806 r2 MAJOR: fail-closed on yq parse error (was silent fallback
# to `main`). A malformed review-config.yml should surface the parse
# error + exit 2, not silently degrade to the wrong baseref.
BASE_REF="main"
REVIEW_CONFIG="$REPO_ROOT/.claude/review-config.yml"
if [ -f "$REVIEW_CONFIG" ]; then
	# CR PR #806 r4 MAJOR: fail-closed on missing yq when config exists.
	# Previously the compound `[ -f config ] && command -v yq` silently
	# fell back to BASE_REF="main" if yq was missing — wrong baseref on
	# non-main branches.
	command -v yq >/dev/null 2>&1 || {
		echo "phase-log-carry-forward: yq not installed; cannot read $REVIEW_CONFIG" >&2
		exit 2
	}
	# CR PR #806 r3 MAJOR: fail-closed on mktemp failure too (TMPDIR
	# broken should surface, not silently degrade to /dev/null).
	yq_err=$(mktemp) || {
		echo "ERROR: mktemp failed for yq_err capture — TMPDIR broken" >&2
		exit 2
	}
	if ! cfg_base=$(yq -r '.base_ref // "main"' "$REVIEW_CONFIG" 2>"$yq_err"); then
		stderr_snippet=""
		[ -s "$yq_err" ] && stderr_snippet=$(head -c 400 "$yq_err")
		rm -f "$yq_err"
		echo "phase-log-carry-forward: yq failed to parse $REVIEW_CONFIG: ${stderr_snippet:-<no stderr>}" >&2
		exit 2
	fi
	rm -f "$yq_err"
	[ -n "$cfg_base" ] && [ "$cfg_base" != "null" ] && BASE_REF="$cfg_base"
fi
list_rc=0
EXPECTED=$("$LIST_SCRIPT" "$BASE_REF" 2>"$list_err" | sort -u) || list_rc=$?
if [ "$list_rc" -ne 0 ] || [ -z "$EXPECTED" ]; then
	stderr_snippet=""
	[ "$list_err" != /dev/null ] && [ -s "$list_err" ] && stderr_snippet=$(head -c 400 "$list_err")
	[ "$list_err" != /dev/null ] && rm -f "$list_err"
	echo "phase-log-carry-forward: list-phase1-agents.sh failed (rc=$list_rc) or returned no agents — failing closed: ${stderr_snippet:-<no stderr>}" >&2
	exit 2
fi
[ "$list_err" != /dev/null ] && rm -f "$list_err"

# Find the most-recent round where every expected agent reported
# findings=0 + status in {ok, not-installed, not-applicable}. jq emits round numbers per
# matching entry; bash loop below sorts unique-descending then verifies
# every expected agent appears (extras from older config are accepted).
CLEAN_ROUND=""
# CR PR #790 r9: capture jq stderr so a corrupt PREV_LOG surfaces the
# real parse error instead of being misattributed to "no Phase 1 entries".
rounds_jq_err=$(mktemp) || {
	echo "ERROR: mktemp failed for rounds_jq_err stderr capture — TMPDIR broken" >&2
	exit 2
}
rounds_jq_rc=0
ROUNDS_DESC=$(jq -r '
	select(.phase==1 and .round!=null)
	| .round
' "$PREV_LOG" 2>"$rounds_jq_err" | sort -un -r) || rounds_jq_rc=$?
if [ "$rounds_jq_rc" -ne 0 ] || { [ "$rounds_jq_err" != /dev/null ] && [ -s "$rounds_jq_err" ]; }; then
	stderr_snippet=""
	[ "$rounds_jq_err" != /dev/null ] && [ -s "$rounds_jq_err" ] && stderr_snippet=$(head -c 200 "$rounds_jq_err")
	[ "$rounds_jq_err" != /dev/null ] && rm -f "$rounds_jq_err"
	echo "phase-log-carry-forward: jq rounds-extract failed on $PREV_LOG (rc=$rounds_jq_rc): ${stderr_snippet:-<no stderr>}" >&2
	exit 2
fi
[ "$rounds_jq_err" != /dev/null ] && rm -f "$rounds_jq_err"
[ -z "$ROUNDS_DESC" ] && {
	echo "phase-log-carry-forward: no Phase 1 entries in $PREV_LOG" >&2
	exit 1
}

while IFS= read -r round; do
	[ -z "$round" ] && continue
	# Filter entries for this round.
	# CR PR #790 r17 phase2: capture jq stderr per-round so a malformed
	# entry surfaces a WARN instead of silently being skipped as empty.
	round_jq_err=$(mktemp) || {
		echo "ERROR: mktemp failed for round_jq_err stderr capture — TMPDIR broken" >&2
		exit 2
	}
	ROUND_ENTRIES=$(jq -c --argjson r "$round" '
		select(.phase==1 and .round==$r and (.findings // 0) == 0 and (.status=="ok" or .status=="not-installed" or .status=="not-applicable"))
	' "$PREV_LOG" 2>"$round_jq_err")
	if [ "$round_jq_err" != /dev/null ] && [ -s "$round_jq_err" ]; then
		echo "phase-log-carry-forward: WARN: jq round-filter emitted stderr for round $round: $(head -c 200 "$round_jq_err")" >&2
	fi
	[ "$round_jq_err" != /dev/null ] && rm -f "$round_jq_err"
	[ -z "$ROUND_ENTRIES" ] && continue
	# CR PR #790 r3 MAJOR: don't require exact agent-count match — accept
	# rounds that contain every currently expected agent (extras from older
	# config are fine; carry-forward stays valid through agent-set churn).
	AGENTS_LOGGED=$(printf '%s\n' "$ROUND_ENTRIES" | jq -r '.agent' | sort -u)
	MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$AGENTS_LOGGED"))
	if [ -z "$MISSING" ]; then
		CLEAN_ROUND="$round"
		break
	fi
done <<<"$ROUNDS_DESC"

if [ -z "$CLEAN_ROUND" ]; then
	echo "phase-log-carry-forward: no fully-clean round in $PREV_LOG" >&2
	exit 1
fi

# Carry-forward: emit clean-round entries with .sha = head_sha. Round
# preserved (pre-push gate dedupes on (sha, round) tuple — same round
# on different SHAs is a distinct clean-streak entry).
mkdir -p "$LOG_DIR" || {
	echo "ERROR: cannot mkdir $LOG_DIR" >&2
	exit 2
}
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP=$(mktemp -t phase-log-cf.XXXXXX) || {
	echo "ERROR: mktemp failed" >&2
	exit 2
}
trap '[ -n "${TMP:-}" ] && rm -f "$TMP"' EXIT

# Phase 1 r1 code-simplifier (conf 9) + silent-failure-hunter (conf 8):
# fold the source-tag into the single jq pass (was 2 sequential passes,
# the first overwritten by the second) + capture stderr so a malformed
# PREV_LOG surfaces the real error instead of generic "transform failed".
cf_jq_err=$(mktemp) || {
	echo "ERROR: mktemp failed for cf_jq_err stderr capture — TMPDIR broken" >&2
	exit 2
}
if ! jq -c --argjson r "$CLEAN_ROUND" --arg sha "$HEAD_SHA" --arg ts "$TS" --arg src "$PREV_SHA" '
	select(.phase==1 and .round==$r and (.findings // 0) == 0 and (.status=="ok" or .status=="not-installed" or .status=="not-applicable"))
	| .sha = $sha
	| .ts = $ts
	| .carried_forward_from = $src
' "$PREV_LOG" >"$TMP" 2>"$cf_jq_err"; then
	stderr_snippet=""
	[ "$cf_jq_err" != /dev/null ] && [ -s "$cf_jq_err" ] && stderr_snippet=$(head -c 200 "$cf_jq_err")
	[ "$cf_jq_err" != /dev/null ] && rm -f "$cf_jq_err"
	echo "ERROR: jq carry-forward transform failed: ${stderr_snippet:-<no stderr>}" >&2
	exit 2
fi
[ "$cf_jq_err" != /dev/null ] && rm -f "$cf_jq_err"

# Append atomically.
cat "$TMP" >>"$HEAD_LOG" || {
	echo "ERROR: cannot append to $HEAD_LOG" >&2
	exit 2
}

CARRIED_COUNT=$(wc -l <"$TMP" | tr -d ' ')
echo "phase-log-carry-forward: carried $CARRIED_COUNT clean-round-$CLEAN_ROUND entries from ${PREV_SHA:0:8} → ${HEAD_SHA:0:8}" >&2
exit 0
