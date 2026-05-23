#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W5 (#817) — Phase 0.5 audit-log dedup filter.
#
# Phase 0.5 agents (comment-analyzer, pr-test-analyzer, silent-failure-hunter,
# code-reviewer, code-simplifier) are non-incremental — they re-review the
# whole file fresh each round, without awareness of fixes/rejections applied
# in prior rounds. Result: a "treadmill" where r2 re-flags exactly the
# findings r1 already addressed (verified on PR #819 — same finding at
# line 380 across r1 → r2 despite the fix landing in commit 1563e5e).
#
# This filter reads a JSON array of findings on stdin, looks each one up
# against `.claude/audit/prove-yourself.jsonl`, and suppresses any whose
# `description` text appears verbatim in a prior `finding_text` field
# (any record with a non-null finding_text — both kind=fix AND
# kind=rejection records are addressed-once and thus warrant suppression).
# Output is the filtered array on stdout.
#
# Match shape:
#   audit.finding_text (e.g. "Phase 0.5 r1 ... (low, conf=6): ... <DESCRIPTION>")
#   contains
#   finding.description (e.g. "<DESCRIPTION>")
#
# Substring is sufficient — the audit records preserve the original agent's
# description verbatim as the suffix of finding_text. False-positive risk
# is low (descriptions are sentence-length specific text, not category
# tags). False-negative risk is also low because we'd only miss if the
# audit operator paraphrased — which is rare and at worst surfaces a
# legitimate re-flag (the cost is one extra audit record, not a regression).
#
# Usage:
#   cat round-N-findings.json | .claude/hooks/phase0.5-dedupe-against-audit.sh
#   .claude/hooks/phase0.5-dedupe-against-audit.sh < round-N-findings.json
#
# Output:
#   stdout: JSON array of un-suppressed findings (may be [])
#   stderr: human-readable count of suppressed entries (only if > 0)
#
# Exit:
#   0 = ran successfully (filtered output emitted; audit log absent = pass-through)
#   1 = malformed input (not a JSON array)
#   2 = script not co-located with a .claude/ tree (cannot derive audit path) OR
#       audit log present but jq parse of finding_text records failed
#       (corrupt JSONL — fail-loud, don't silently dedup with partial data)

# CR-CLI Phase 2 r2 critical: derive REPO_ROOT script-relative instead of via
# `git rev-parse` — the script always lives at $REPO/.claude/hooks/<file>, so
# `dirname "${BASH_SOURCE[0]}"/../../..` is the deterministic, error-surfacing
# path (no git error suppression, works in worktrees + subdirs).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../.." && pwd; })
if [ ! -d "$REPO_ROOT/.claude" ]; then
	echo "dedupe-against-audit: cannot resolve repo root (\$SCRIPT_DIR/../.. missing .claude/): $REPO_ROOT" >&2
	exit 2
fi
AUDIT_LOG="$REPO_ROOT/.claude/audit/prove-yourself.jsonl"

# Read stdin into a variable so we can validate before processing.
# CR-CLI Phase 2 r5: capture cat's exit status — `INPUT=$(cat)` alone
# would silently empty INPUT on a broken-pipe / closed-fd read, which
# downstream would treat as "empty array → exit 0" instead of fail-loud.
_cat_rc=0
INPUT=$(cat) || _cat_rc=$?
if [ "$_cat_rc" -ne 0 ]; then
	echo "dedupe-against-audit: stdin read failed (cat rc=$_cat_rc)" >&2
	exit 2
fi
if [ -z "$INPUT" ]; then
	echo "[]"
	exit 0
fi

# Validate JSON-array shape upfront — keeps downstream jq calls from
# silently emitting empty output on malformed input.
if ! echo "$INPUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
	echo "dedupe-against-audit: input is not a JSON array — refusing to filter" >&2
	exit 1
fi

# Audit log absent → no filtering possible; pass through. (Bootstrap or
# fresh-repo case. Not an error — caller may not have any prior records.)
if [ ! -f "$AUDIT_LOG" ]; then
	echo "$INPUT"
	exit 0
fi

# Extract all known finding_text values (one per line). Newline-separator
# is safe because finding_text is single-line JSON-escaped.
# Phase 1 r1 silent-failure-hunter: capture jq stderr + rc separately so
# corrupt audit-log JSONL fails loud (rc=2) instead of silently emitting
# partial output and conflating with the legitimate "bootstrap — no
# entries yet" branch below.
_jq_err=$(mktemp -t p05dd-jq-err.XXXXXX)
# CR-CLI Phase 2 r2 minor: trap-based cleanup so the tempfile never leaks
# on early exits (jq SIGTERM, set -e abort, exec interrupt). Explicit
# `rm -f` calls below remain as defense-in-depth but the trap is the
# safety net.
trap 'rm -f "$_jq_err"' EXIT
_jq_rc=0
KNOWN_TEXTS=$(jq -r 'select(.finding_text != null) | .finding_text' "$AUDIT_LOG" 2>"$_jq_err") || _jq_rc=$?
if [ "$_jq_rc" -ne 0 ]; then
	echo "dedupe-against-audit: jq parse of audit log $AUDIT_LOG failed (rc=$_jq_rc) — refusing to dedup against partial data" >&2
	head -c 500 "$_jq_err" >&2
	echo "" >&2
	exit 2
fi
rm -f "$_jq_err"
trap - EXIT

# v4.28-W5 #855 fix: ALSO extract known cluster_id values. The text-match
# filter (below) requires VERBATIM substring match, which breaks when agents
# reword the same finding across rounds — same cluster_id, different prose.
# cluster_id is the stable identity (hash of finding content); matching on
# it as well closes the wording-drift escape hatch and keeps already-
# addressed clusters suppressed regardless of how the agent phrases them.
_cluster_err=$(mktemp -t p05dd-cluster-err.XXXXXX)
trap 'rm -f "$_cluster_err"' EXIT
_cluster_rc=0
KNOWN_CLUSTER_IDS=$(jq -r 'select(.cluster_id != null) | .cluster_id' "$AUDIT_LOG" 2>"$_cluster_err") || _cluster_rc=$?
if [ "$_cluster_rc" -ne 0 ]; then
	echo "dedupe-against-audit: jq parse of audit log cluster_ids failed (rc=$_cluster_rc) — refusing to dedup against partial data" >&2
	head -c 500 "$_cluster_err" >&2
	echo "" >&2
	exit 2
fi
rm -f "$_cluster_err"
trap - EXIT

if [ -z "$KNOWN_TEXTS" ] && [ -z "$KNOWN_CLUSTER_IDS" ]; then
	# Bootstrap: no audit entries with finding_text OR cluster_id yet —
	# nothing to dedupe. (Distinguishable from "corrupt log" because that
	# path exited rc=2 above; this branch is reached only when jq succeeded
	# but emitted zero records of either kind.)
	echo "$INPUT"
	exit 0
fi

# Filter: drop findings where EITHER:
#   (a) .description appears verbatim as substring in any known finding_text, OR
#   (b) .cluster_id matches any known cluster_id from audit records.
# Either match → drop. Pass both via --arg (jq sees verbatim).
# v4.28-W5 #855: cluster_id branch added because agents reword the same
# finding across rounds — same cluster_id but different prose breaks the
# pure text-match filter. cluster_id is the stable identity.
# CR-in-CI Phase 2 r3 critical: explicit rc + stderr capture on the
# primary filter — without it a jq failure would leave $FILTERED empty
# and the final `echo "$FILTERED"` would emit an empty string (invalid
# JSON) with exit 0. Fail-closed for the primary contract.
_filter_err=$(mktemp -t p05dd-filter-err.XXXXXX)
trap 'rm -f "$_filter_err"' EXIT
_filter_rc=0
FILTERED=$(echo "$INPUT" | jq \
	--arg known "$KNOWN_TEXTS" \
	--arg known_clusters "$KNOWN_CLUSTER_IDS" '
	($known | split("\n") | map(select(length > 0))) as $known_arr
	| ($known_clusters | split("\n") | map(select(length > 0))) as $known_cluster_arr
	| map(select(
		.description as $d
		| .cluster_id as $cid
		| (
		    # KEEP only when NEITHER text-substring NOR cluster_id matches.
		    (
		      ($d | length) == 0
		      or ($known_arr | any(. as $k | $k | contains($d)) | not)
		    )
		    and
		    (
		      $cid == null
		      or ($cid | length) == 0
		      or ($known_cluster_arr | any(. == $cid) | not)
		    )
		  )
	))
' 2>"$_filter_err") || _filter_rc=$?
if [ "$_filter_rc" -ne 0 ]; then
	echo "dedupe-against-audit: primary filter jq failed (rc=$_filter_rc) — refusing to emit invalid output" >&2
	head -c 500 "$_filter_err" >&2
	echo "" >&2
	exit 2
fi
rm -f "$_filter_err"
trap - EXIT

# Report suppression count to stderr (advisory; doesn't affect exit code).
# CR-CLI Phase 2 r6 → CR-in-CI: capture jq stderr explicitly so a counting
# failure surfaces a diagnostic instead of silently swallowing (no
# 2>/dev/null), AND falls back to '?' so the primary contract (filtered
# JSON array on stdout) is never blocked by a counting glitch.
_count_err=$(mktemp -t p05dd-count-err.XXXXXX)
trap 'rm -f "$_count_err"' EXIT
_ic_rc=0
input_count=$(echo "$INPUT" | jq 'length' 2>"$_count_err") || _ic_rc=$?
if [ "$_ic_rc" -ne 0 ]; then
	echo "dedupe-against-audit: jq input_count failed (rc=$_ic_rc): $(head -c 300 "$_count_err")" >&2
	input_count='?'
fi
: >"$_count_err"
_oc_rc=0
output_count=$(echo "$FILTERED" | jq 'length' 2>"$_count_err") || _oc_rc=$?
if [ "$_oc_rc" -ne 0 ]; then
	echo "dedupe-against-audit: jq output_count failed (rc=$_oc_rc): $(head -c 300 "$_count_err")" >&2
	output_count='?'
fi
rm -f "$_count_err"
trap - EXIT
# Guard arithmetic — only compute suppressed-count when both sides parsed.
if [ "$input_count" != "?" ] && [ "$output_count" != "?" ]; then
	suppressed=$((input_count - output_count))
	if [ "$suppressed" -gt 0 ]; then
		echo "phase0.5-dedupe: suppressed $suppressed finding(s) already covered by prove-yourself audit log" >&2
	fi
fi

echo "$FILTERED"
