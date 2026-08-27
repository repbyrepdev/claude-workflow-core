#!/bin/bash
set -u
# NB: this file sets `set -u` for the case where it is EXECUTED. When SOURCED
# — the only way it is actually used — that line is a no-op against what
# matters, because shell options are per-SHELL, not per-file. An earlier
# version of this header said "sourcing scripts define their own option
# discipline" as though that isolated this code from theirs; it is the
# opposite. `merge_auto_ok` runs under the CALLER's options, and its only
# caller is scripts/ship-pr-cycle.sh, which sets `set -euo pipefail`.
#
# So every `var=$(... | jq ...)` in here runs with errexit AND pipefail
# active, and an unguarded one ABORTS cmd_next instead of returning the rc 2
# this file exists to produce — delivering neither "not green" nor "could not
# tell", just an unexplained non-zero exit at merge-gate. Each substitution
# below therefore captures its own rc.
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
#   2. hooks/_pr-cr-findings.sh reports clean (all FOUR of its sources)
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

	# OPT-IN, not opt-out. #2549 specified default-on; phase-1 review then
	# found four independent ways this returned rc 0 on a PR that should have
	# held, and they COMPOSE — a rate-limited CodeRabbit plus a skipped
	# required check plus a thread CR had re-flagged all read green at once.
	# Every one is fixed below, but a predicate that decides to merge without
	# a human earns default-on by being trusted, and it has not been trusted
	# yet. Turn it on with MERGE_GATE_AUTO=1 once it has run alongside the
	# human gate for a while and agreed with it.
	if [ "${MERGE_GATE_AUTO:-0}" != "1" ]; then
		echo "auto-merge is opt-in (set MERGE_GATE_AUTO=1); holding the operator gate"
		return 1
	fi

	local view
	view=$(gh pr view "$pr" \
		--json mergeStateStatus,labels,isDraft 2>/dev/null) || {
		echo "could not read PR state (gh pr view failed)"
		return 2
	}
	# Checks come from `gh pr checks`, NOT from `gh pr view --json
	# statusCheckRollup`. The rollup carries no `description`/`title` field at
	# all — verified against live PR #2635, where a CheckRun node holds only
	# {__typename, completedAt, conclusion, detailsUrl, name, startedAt,
	# status, workflowName}. Reading `.description` from it made the entire
	# hollow-check dead code: `desc` was always "", the regex never matched,
	# and the #2540 shape it exists to refuse sailed through to rc 0. The unit
	# tests passed only because their fixture hand-injected a `description`
	# key that gh never produces — they proved the fixture, not the system.
	# `gh pr checks` exits NON-ZERO when a check is failing (1) or pending (8)
	# — those are answers, not errors, and it still prints valid JSON. Treating
	# a non-zero rc as unreadable turned "a required check failed" (rc 1, go
	# fix it) into "could not determine" (rc 2, something is broken), which
	# defeats the very rc distinction this file is built around. Only an
	# unusable PAYLOAD is a read failure.
	local checks checks_rc=0
	checks=$(gh pr checks "$pr" --json name,state,description 2>/dev/null) || checks_rc=$?
	if [ -z "$checks" ] || ! printf '%s' "$checks" | jq -e 'type == "array"' >/dev/null 2>&1; then
		echo "could not read PR checks (gh rc=$checks_rc, payload unusable)"
		return 2
	fi
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

	local mss mss_rc=0
	mss=$(printf '%s' "$view" | jq -r '.mergeStateStatus // ""') || mss_rc=$?
	[ "$mss_rc" -eq 0 ] || {
		echo "mergeStateStatus unreadable (jq rc=$mss_rc)"
		return 2
	}
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
	# yq's rc captured separately from the empty-result test. Both are rc 2,
	# but they send the operator to different places: a parse failure means
	# the file is malformed or yq is missing, while an empty extraction means
	# the file is fine and genuinely lists nothing. Collapsing them printed
	# "listed no checks" about a file that lists plenty.
	local required required_rc=0
	required=$(yq -r '.required[].check_name' "$ssot" 2>/dev/null) || required_rc=$?
	if [ "$required_rc" -ne 0 ]; then
		echo "required-checks SSOT could not be parsed (yq rc=$required_rc on $ssot) — cannot determine what is required"
		return 2
	fi
	[ -n "$required" ] || {
		echo "required-checks SSOT listed no checks — refusing to call that green"
		return 2
	}

	local name state desc missing=0 hollow=0 notgreen=0 detail=""
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		local row row_rc=0 sd_rc=0
		row=$(printf '%s' "$checks" | jq -c --arg n "$name" \
			'[.[]? | select((.name // "") == $n)] | last // empty' 2>/dev/null) || row_rc=$?
		if [ "$row_rc" -ne 0 ]; then
			echo "check rollup unreadable for '$name' (jq rc=$row_rc)"
			return 2
		fi
		if [ -z "$row" ] || [ "$row" = "null" ]; then
			missing=$((missing + 1))
			detail="$detail ${name}=absent"
			continue
		fi
		state=$(printf '%s' "$row" | jq -r '(.state // "") | ascii_upcase') || sd_rc=$?
		desc=$(printf '%s' "$row" | jq -r '(.description // "")') || sd_rc=$?
		if [ "$sd_rc" -ne 0 ]; then
			echo "check state/description unreadable for '$name' (jq rc=$sd_rc)"
			return 2
		fi
		case "$state" in
		SUCCESS) ;;
		SKIPPED | NEUTRAL)
			# A required check that was SKIPPED is the definition of "passed
			# without doing its job" — a path filter, a false `if:`, a
			# cancelled matrix leg. GitHub counts it as satisfied for branch
			# protection, so mergeStateStatus stays CLEAN and nothing else
			# catches it. This file previously accepted it as green while its
			# own hollow-regex listed "skipped" as disqualifying.
			hollow=$((hollow + 1))
			detail="$detail ${name}=${state}"
			continue
			;;
		"" | null)
			# Unreadable, or still running: `//` does not fall through an
			# empty STRING, so an in-progress check yields "". Not the same as
			# failing, and rc 2 says so.
			missing=$((missing + 1))
			detail="$detail ${name}=unreadable-or-running"
			continue
			;;
		*)
			notgreen=$((notgreen + 1))
			detail="$detail ${name}=${state}"
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

	# --- CR findings: the SAME check the merge gate runs --------------------
	#
	# Delegates to hooks/_pr-cr-findings.sh rather than counting threads
	# itself. That helper is the authority and consults FOUR sources —
	# unresolved current threads, STRANDED outdated threads, CR walkthrough
	# "Pre-merge checks" failures, and outside-diff-range findings embedded in
	# review bodies. This lib previously consulted only the first, so a PR
	# with a failed walkthrough check or an outside-diff finding was "provably
	# green" here while pre-merge-cr-comments-gate.sh would have refused it.
	#
	# That mattered more than it looks: the auto path runs the merge as a
	# grandchild process, where no PreToolUse hook fires, so the gate could
	# not catch afterwards what this missed. The one path that merges with no
	# human was the one path skipping the four-source check.
	local findings_helper="" fh_out fh_rc=0
	if [ -n "${MERGE_AUTO_FINDINGS_HELPER:-}" ]; then
		findings_helper="$MERGE_AUTO_FINDINGS_HELPER"
	else
		# `c` declared local too: this file is SOURCED, so an undeclared loop
		# variable is written into the caller's shell, where a `c` of its own
		# would be silently overwritten from inside a function it only asked a
		# yes/no question of.
		local repo_root c
		repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
		for c in "$repo_root/hooks/_pr-cr-findings.sh" "$repo_root/.claude/hooks/_pr-cr-findings.sh"; do
			[ -x "$c" ] && findings_helper="$c" && break
		done
	fi
	# Executable, not merely named: an override pointing at a missing path
	# otherwise fell through to "the helper ran and reported findings" (rc 1)
	# instead of "the check could not run" (rc 2), which is the distinction
	# this whole file exists to keep.
	if [ -z "$findings_helper" ] || [ ! -x "$findings_helper" ]; then
		echo "_pr-cr-findings.sh not found or not executable ('${findings_helper:-unset}') — cannot verify CR findings"
		return 2
	fi
	fh_out=$("$findings_helper" "$pr" 2>&1) || fh_rc=$?
	if [ "$fh_rc" -ne 0 ]; then
		# rc 1 is "findings present OR query failure" — the helper does not
		# distinguish, and neither should this: both mean the gate holds.
		echo "CR findings outstanding (or unreadable): $(printf '%s' "$fh_out" | grep -iE 'TOTAL needing cleanup|ERROR' | head -1)"
		return 1
	fi

	echo "all required checks green, CR findings clean (4-source), mergeStateStatus CLEAN"
	return 0
}
