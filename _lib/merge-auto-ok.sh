#!/bin/bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`: sourcing scripts define their own option discipline.
#
# auto-register: false
# (#2549) Decide whether a PR is provably green enough to ARM GitHub native
# auto-merge instead of holding the operator gate.
#
# The gate at merge-gate is deliberate — SKILL.md states the design goal as
# "ONE gate (approve-to-ship at merge time)". But it fires unconditionally,
# including when the PR is provably green with nothing outstanding. On #2540
# the operator pressed the button after ~12 rounds in which every finding had
# already been fixed-and-verified or rejected-with-evidence; nothing was left
# to decide.
#
# Arming `--auto` does NOT weaken review. GitHub still enforces the branch
# ruleset, including any required approving review, and blocks author
# self-approval. It only stops requiring a human to press merge AFTER the
# machine has already agreed.
#
# THE THREE SIGNALS, all of which must hold:
#   1. every required check per .github/required-checks-list.yml is green
#   2. unaddressed CR threads == 0
#   3. mergeStateStatus == CLEAN
#
# ...and three prior refusals that short-circuit before any of them are read:
#   MERGE_GATE_AUTO=0        operator disabled auto mode          → rc 1
#   isDraft                  a draft is never auto-merged         → rc 1
#   needs-operator label     human gate forced regardless         → rc 1
#
# FAIL CLOSED on any signal that cannot be READ. "I could not determine it" is
# not "it is fine" — that distinction is the whole reason this lib exists as
# something testable rather than an inline condition.
#
# A `pass` check is not automatically evidence: on #2540 the CodeRabbit check
# reported pass with description "Review rate limited" while having performed
# NO review. Check state alone is insufficient, so a pass whose description
# says no review ran returns rc 2 — "could not determine", not rc 1
# "not green". The distinction is deliberate: the check did not fail, it
# failed to HAPPEN, and those want different operator action.
#
# merge_auto_ok <pr>
#   rc 0 = arm auto-merge · 1 = hold the human gate (reason on stdout)
#   rc 2 = could not determine (also holds the gate; distinct for callers)

# Descriptions that mean "this check passed without doing its job".
_MERGE_AUTO_HOLLOW_RE='rate.?limit|no review|skipped|not run|review.?paused|auto.?paused'

merge_auto_ok() {
	local pr="${1:-}"
	[ -n "$pr" ] || {
		echo "merge-auto-ok: no PR number given"
		return 2
	}

	# Operator kill switch. Default ON per #2549, off with MERGE_GATE_AUTO=0.
	if [ "${MERGE_GATE_AUTO:-1}" = "0" ]; then
		echo "MERGE_GATE_AUTO=0 — operator disabled auto-merge"
		return 1
	fi

	local view
	view=$(gh pr view "$pr" \
		--json mergeStateStatus,mergeable,labels,statusCheckRollup,isDraft 2>/dev/null) || {
		echo "could not read PR state (gh pr view failed)"
		return 2
	}
	[ -n "$view" ] || {
		echo "gh pr view returned nothing"
		return 2
	}

	# A draft is never auto-mergeable, and saying so is clearer than letting
	# mergeStateStatus report DRAFT further down.
	if [ "$(printf '%s' "$view" | jq -r '.isDraft // false')" = "true" ]; then
		echo "PR is a draft"
		return 1
	fi

	# `needs-operator` forces the human gate regardless of every other signal.
	# This is the deliberate escape hatch for a change that is green but wants
	# a person to look at it anyway.
	local _labels _lrc=0
	_labels=$(printf '%s' "$view" | jq -r '[.labels[]?.name] | join(" ")' 2>/dev/null) || _lrc=$?
	if [ "$_lrc" -ne 0 ]; then
		# A jq failure here previously read the same as "label absent", which
		# would carry an unreadable PR toward auto-merge. Unreadable is rc 2.
		echo "labels unreadable — cannot confirm needs-operator is absent"
		return 2
	fi
	case " $_labels " in
	*" needs-operator "*)
		echo "needs-operator label present — human gate forced"
		return 1
		;;
	esac

	local mss
	mss=$(printf '%s' "$view" | jq -r '.mergeStateStatus // ""')
	case "$mss" in
	CLEAN) ;;
	"" | null)
		echo "mergeStateStatus unreadable"
		return 2
		;;
	*)
		echo "mergeStateStatus is $mss (need CLEAN)"
		return 1
		;;
	esac

	# --- required checks ---------------------------------------------------
	local ssot="${MERGE_AUTO_CHECKS_SSOT:-}"
	if [ -z "$ssot" ]; then
		local root
		root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
		ssot="$root/.github/required-checks-list.yml"
	fi
	[ -r "$ssot" ] || {
		echo "required-checks SSOT unreadable ($ssot)"
		return 2
	}
	local required
	required=$(yq -r '.required[].check_name' "$ssot" 2>/dev/null) || required=""
	[ -n "$required" ] || {
		echo "required-checks SSOT listed no checks — refusing to call that green"
		return 2
	}

	local name state desc missing=0 hollow=0 notgreen=0 detail=""
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		local row
		row=$(printf '%s' "$view" | jq -c --arg n "$name" \
			'[.statusCheckRollup[]? | select((.name // .context // "") == $n)] | last // empty' 2>/dev/null)
		if [ -z "$row" ] || [ "$row" = "null" ]; then
			missing=$((missing + 1))
			detail="$detail ${name}=absent"
			continue
		fi
		state=$(printf '%s' "$row" | jq -r '(.conclusion // .state // "") | ascii_upcase')
		desc=$(printf '%s' "$row" | jq -r '(.description // .title // "")')
		case "$state" in
		SUCCESS | NEUTRAL | SKIPPED) ;;
		*)
			notgreen=$((notgreen + 1))
			detail="$detail ${name}=${state:-unknown}"
			continue
			;;
		esac
		# Green, but did it actually do anything?
		if printf '%s' "$desc" | grep -qiE "$_MERGE_AUTO_HOLLOW_RE"; then
			hollow=$((hollow + 1))
			detail="$detail ${name}=hollow(${desc})"
		fi
	done <<<"$required"

	if [ "$missing" -gt 0 ]; then
		echo "required check(s) absent from the rollup:$detail"
		return 2
	fi
	if [ "$hollow" -gt 0 ]; then
		echo "required check(s) passed without running:$detail"
		return 2
	fi
	if [ "$notgreen" -gt 0 ]; then
		echo "required check(s) not green:$detail"
		return 1
	fi

	# --- unaddressed CR threads -------------------------------------------
	local helper="" count
	if [ -n "${MERGE_AUTO_THREAD_HELPER:-}" ]; then
		helper="$MERGE_AUTO_THREAD_HELPER"
	else
		local root2
		root2=$(git rev-parse --show-toplevel 2>/dev/null) || root2=""
		[ -x "$root2/scripts/cr/thread-reply.sh" ] && helper="$root2/scripts/cr/thread-reply.sh"
		[ -z "$helper" ] && [ -x "$root2/.claude/scripts/cr/thread-reply.sh" ] &&
			helper="$root2/.claude/scripts/cr/thread-reply.sh"
	fi
	[ -n "$helper" ] || {
		echo "thread-reply helper not found — cannot count unaddressed threads"
		return 2
	}
	count=$("$helper" "$pr" --count 2>/dev/null) || {
		echo "unaddressed-thread count failed"
		return 2
	}
	case "$count" in
	'' | *[!0-9]*)
		echo "unaddressed-thread count unreadable ('$count')"
		return 2
		;;
	esac
	if [ "$count" -gt 0 ]; then
		echo "$count unaddressed CR thread(s)"
		return 1
	fi

	echo "all required checks green, 0 unaddressed threads, mergeStateStatus CLEAN"
	return 0
}
