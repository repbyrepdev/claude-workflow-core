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

# Resolve whether CodeRabbit is a REQUIRED status check on the PR's base
# branch. Echoes exactly one of: yes | no | unknown.
#
#   yes     — CodeRabbit is in the base branch's required-check list.
#   no      — branch protected but CR not required, OR branch unprotected
#             (the plugin's own main is unprotected — it MUST stay exit-3
#             eligible, so unprotected resolves to "no", not "unknown").
#   unknown — could not determine (transient gh/auth/permission/network
#             error). Callers MUST treat `unknown` like `yes`: keep waiting.
#             Never let an indeterminate result enable the exit-3 path, or a
#             gh blip could skip a genuinely-required review (#2332 r1: fail
#             CLOSED, not open).
#
# Call only inside a command substitution (`x=$(_cr_required_state)`); a bare
# call under `set -e` whose final command returned non-zero would abort.
_cr_required_state() {
	local owner_repo base protected req
	owner_repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || {
		echo unknown
		return
	}
	base=$(gh pr view "$PR" --json baseRefName --jq '.baseRefName' 2>/dev/null) || {
		echo unknown
		return
	}
	# Branch-object read needs no admin scope and reports whether the branch
	# is protected at all. Unprotected → CR cannot be a required check → "no".
	# A failure here is indeterminate → "unknown".
	protected=$(gh api "repos/$owner_repo/branches/$base" --jq '.protected' 2>/dev/null) || {
		echo unknown
		return
	}
	[ "$protected" = false ] && {
		echo no
		return
	}
	[ "$protected" = true ] || {
		echo unknown
		return
	}
	# Protected branch: read the required-check list (needs admin scope). A
	# failure here (403 token scope / 5xx / network) is indeterminate →
	# "unknown" (fail closed: keep waiting, don't risk skipping a required CR).
	req=$(gh api "repos/$owner_repo/branches/$base/protection" \
		--jq '((.required_status_checks.contexts // []) + ((.required_status_checks.checks // []) | map(.context))) | any(ascii_downcase == "coderabbit")' 2>/dev/null) || {
		echo unknown
		return
	}
	if [ "$req" = true ]; then echo yes; else echo no; fi
}

_other_checks_terminal() {
	# 0 = every NON-CodeRabbit check row is in a known TERMINAL state.
	# $1 = raw `gh pr checks` output (tab-separated: name<TAB>bucket<TAB>...).
	# Column 2 is gh's BUCKET string (pass|fail|pending|skipping|cancel); we
	# allowlist the terminal ones (plus the raw-state spellings the main poll
	# loop also accepts). ANY other value — pending, queued, in_progress,
	# waiting, a blank state column, or an unrecognized future state — counts
	# as non-terminal (keep waiting). Empty input (no rows observed) is
	# non-terminal too. Fail closed: never let an unmodeled state look
	# terminal and trip a premature exit 3.
	[ -n "$1" ] || return 1
	printf '%s\n' "$1" | awk -F'\t' '
		tolower($1) == "coderabbit" { next }
		{
			s = tolower($2)
			if (s != "pass" && s != "success" && s != "fail" && s != "failure" &&
			    s != "error" && s != "cancel" && s != "cancelled" && s != "canceled" &&
			    s != "skipping" && s != "skipped" && s != "neutral")
				pend = 1
		}
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

# #2332: resolve once whether CodeRabbit is required (doesn't change during the
# watch). Only a definite "no" (CR cannot block merge) enables the path-filtered
# exit-3 below; "yes" and "unknown" both keep waiting (fail closed).
CR_REQUIRED=$(_cr_required_state)

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
			# CR row genuinely absent AND gh produced output (the empty-RAW
			# case can't reach here — gh failure already exited via scm_fail
			# above). Count CONSECUTIVE absence polls (the reset above is
			# what makes the count consecutive, not cumulative).
			ABSENT_WITH_OTHERS=$((ABSENT_WITH_OTHERS + 1))
			if [ "$ABSENT_WITH_OTHERS" = "$ABSENT_WARN_THRESHOLD" ]; then
				scm_warn "CodeRabbit row absent from gh checks for $ABSENT_WITH_OTHERS consecutive polls — is coderabbitai installed on this repo?"
			fi
		fi
		# #2332: sustained-absent + not required + all other checks terminal →
		# the PR is path-filtered out of CR auto_review (see preamble). Exit
		# terminal (3) rather than wait out the timeout. The counter is only
		# nonzero after sustained absence, so this can't fire while CR is live.
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
