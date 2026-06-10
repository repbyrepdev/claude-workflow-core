#!/bin/bash
set -euo pipefail
# v4.21 (#520): poll the CodeRabbit status check on a PR until it
# reaches a terminal state (success/failure/cancelled). Prints a
# heartbeat every poll + a final summary.
#
# Usage:
#   .claude/scripts/cr/watch-until-done.sh <pr-num>
#   .claude/scripts/cr/watch-until-done.sh <pr-num> --interval 30 --timeout 600
#
# Exit codes:
#   0 — CR completed successfully (pass)
#   1 — CR completed with failure
#   2 — timeout reached OR invocation error (arg validation, gh failure)
#   3 — CR not applicable: posted nothing (PR paths outside .coderabbit.yaml
#       auto_review path_filters), CR is not a required check, and every other
#       check is terminal — there is no CR check to wait for (#2332)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# REPO_ROOT pre-seeds the value the sourced _common.sh consumes (its
# `: "${REPO_ROOT:=...}"` default-assign + export); it is read by that lib,
# not locally — hence the SC2034 suppression. The script-relative fallback
# is more robust than _common.sh's bare `pwd` when cwd != repo root.
# shellcheck disable=SC2034
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

# #2332: detect the "CR posts nothing because the PR is path-filtered out of
# .coderabbit.yaml auto_review" case, so the poll loop can exit terminal
# instead of waiting out the full timeout (the false "CR is down" trap that
# parked PR #2330 for ~15h). Used ONLY to avoid an infinite wait — never to
# skip a review that is actually coming: CR posts its pending check within
# seconds when it engages, so sustained absence reliably means it will not.
_cr_is_required() {
	# 0 = "CodeRabbit" is a required status check on the PR's base branch.
	local owner_repo base
	owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || return 1
	base=$(gh pr view "$PR" --json baseRefName --jq '.baseRefName' 2>/dev/null) || return 1
	gh api "repos/$owner_repo/branches/$base/protection" \
		--jq '((.required_status_checks.contexts // []) + ((.required_status_checks.checks // []) | map(.context))) | any(. == "CodeRabbit")' 2>/dev/null |
		grep -qx true
}

_other_checks_terminal() {
	# 0 = no NON-CodeRabbit check row is still pending/queued (all terminal).
	# $1 = raw `gh pr checks` output (tab-separated: name<TAB>state<TAB>...).
	printf '%s\n' "$1" | awk -F'\t' '
		tolower($1) == "coderabbit" { next }
		{ s = tolower($2); if (s == "pending" || s == "queued" || s == "") pend = 1 }
		END { exit pend ? 1 : 0 }
	'
}

PR=""
INTERVAL=20
TIMEOUT=900
while [ $# -gt 0 ]; do
	case "$1" in
	--interval)
		INTERVAL="${2:?}"
		shift 2
		;;
	--timeout)
		TIMEOUT="${2:?}"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		if [ -z "$PR" ] && [[ $1 =~ ^[0-9]+$ ]]; then
			PR="$1"
			shift
		else
			scm_fail "unknown arg: $1"
		fi
		;;
	esac
done
[ -n "$PR" ] || scm_fail "usage: $0 <pr-num> [--interval SEC] [--timeout SEC]"
[[ $INTERVAL =~ ^[0-9]+$ ]] || scm_fail "interval must be numeric"
[[ $TIMEOUT =~ ^[0-9]+$ ]] || scm_fail "timeout must be numeric"

START=$(date +%s)
echo "Watching CodeRabbit on PR #$PR (poll every ${INTERVAL}s, timeout ${TIMEOUT}s)..."

# #2332: resolve once whether CodeRabbit is a required check (doesn't change
# during the watch). If NOT required and CR posts nothing (path-filtered PR),
# the absent-CR branch exits terminal (3) rather than waiting out the timeout.
if _cr_is_required; then CR_REQUIRED=yes; else CR_REQUIRED=no; fi

# Poll loop: parse field 2 (state) of the CodeRabbit row from
# `gh pr checks` output (one row per status check). Track consecutive
# polls where the CR row is absent from otherwise-populated output so
# we can distinguish "CR not yet queued" from "CR not installed on repo".
ABSENT_WITH_OTHERS=0
ABSENT_WARN_THRESHOLD=3
while :; do
	ELAPSED=$(($(date +%s) - START))
	if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
		scm_warn "timeout reached (${TIMEOUT}s) before CR reached terminal state"
		scm_log cr-watch "$(printf '{"pr":%s,"outcome":"timeout","elapsed":%s}' "$PR" "$ELAPSED")"
		exit 2
	fi

	# Split gh call from awk parse: if we pipe directly + `|| true`, every
	# gh failure (auth, network, PR not found) collapses to STATE="" and
	# routes to the pending branch — silently polling until timeout
	# instead of surfacing the real error. Fail loud on gh error.
	if ! RAW=$(gh pr checks "$PR" 2>&1); then
		scm_fail "gh pr checks failed for #$PR: $RAW"
	fi
	# `-F '\t'`: `gh pr checks` uses tab-separated columns. Default FS
	# splits on any whitespace, which would break if a check name ever
	# contained spaces.
	STATE=$(printf '%s\n' "$RAW" | awk -F'\t' 'tolower($1) == "coderabbit" {print $2; exit}')
	case "$STATE" in
	pass | success)
		echo "[${ELAPSED}s] CodeRabbit: $STATE ✓"
		scm_log cr-watch "$(printf '{"pr":%s,"outcome":"pass","elapsed":%s}' "$PR" "$ELAPSED")"
		exit 0
		;;
	fail | failure | error | cancelled)
		echo "[${ELAPSED}s] CodeRabbit: $STATE ✗"
		scm_log cr-watch "$(printf '{"pr":%s,"outcome":"fail","state":"%s","elapsed":%s}' "$PR" "$STATE" "$ELAPSED")"
		exit 1
		;;
	pending | queued | "")
		# "Is the CodeRabbit row missing from gh output, vs present-but-
		# transiently-empty-state?" Use the actual awk presence test, not
		# the STATE variable (which goes empty on both "row absent" AND
		# "row present with blank state column" during transient queuing).
		if printf '%s\n' "$RAW" | awk -F'\t' 'tolower($1) == "coderabbit" {found=1} END {exit !found}'; then
			# CR row IS present — reset counter so intermittent blips
			# don't accumulate across a long watch.
			ABSENT_WITH_OTHERS=0
		elif [ -n "$RAW" ]; then
			# CR row genuinely absent AND gh produced output. Count
			# CONSECUTIVE absence polls (comment said consecutive; now
			# code enforces it via the reset above).
			ABSENT_WITH_OTHERS=$((ABSENT_WITH_OTHERS + 1))
			if [ "$ABSENT_WITH_OTHERS" = "$ABSENT_WARN_THRESHOLD" ]; then
				scm_warn "CodeRabbit row absent from gh checks for $ABSENT_WITH_OTHERS consecutive polls — is coderabbitai installed on this repo?"
			fi
		fi
		# #2332: CR genuinely not coming — absent for the warn threshold, NOT a
		# required check, and every OTHER check terminal → the PR's paths are
		# path-filtered out of CR auto_review, so no CR check is coming. Exit
		# terminal (3) instead of polling to the full timeout (the false "CR is
		# down" trap that parked PR #2330 for ~15h). ABSENT_WITH_OTHERS is only
		# nonzero when CR has been sustained-absent, so this never fires while
		# CR is present/queued (that branch resets the counter).
		if [ "$ABSENT_WITH_OTHERS" -ge "$ABSENT_WARN_THRESHOLD" ] &&
			[ "$CR_REQUIRED" = no ] && _other_checks_terminal "$RAW"; then
			echo "[${ELAPSED}s] CodeRabbit: absent + not a required check + all other checks terminal → not applicable (PR paths outside .coderabbit.yaml auto_review). Treating as terminal; force '@coderabbitai review' if a review is desired."
			scm_log cr-watch "$(printf '{"pr":%s,"outcome":"not-applicable-path-filtered","elapsed":%s}' "$PR" "$ELAPSED")"
			exit 3
		fi
		echo "[${ELAPSED}s] CodeRabbit: ${STATE:-not-started} (poll again in ${INTERVAL}s)"
		sleep "$INTERVAL"
		;;
	*)
		echo "[${ELAPSED}s] CodeRabbit: $STATE (unrecognized — polling)"
		sleep "$INTERVAL"
		;;
	esac
done
