#!/bin/bash
set -euo pipefail
# (#2642) The weekly bats-baseline scheduler.
#
# TWO HOOKS HAVE CITED THIS FILE AS THE REMEDY SINCE v4.23-V, AND IT DID
# NOT EXIST:
#
#   hooks/pre-push-pipeline-gate.sh      "rely on weekly baseline cron
#                                         (check: ... --verify)"
#   hooks/session-start-report.sh        "install via ..."
#   hooks/session-start-report.sh        "cron may be broken. Verify: ..."
#
# (Line numbers deliberately omitted: the first version cited :859 and
# this same diff pushed that line to :884. A citation that drifts is worse
# than none — it sends the reader to the wrong place with confidence.)
#
# So the push gate's 7-day baseline fallback (its CUTOFF_7D arm) has never
# once fired — `grep -c '"baseline":true' .claude/logs/bats-run.jsonl`
# returned 0 across the whole log — and session-start-report has been
# telling the operator to run a command that would fail with "No such
# file". An error message pointing at nothing is worse than none: it reads
# as a supported path and costs a debugging detour to discover it is not.
#
# WHY THIS MATTERS MORE NOW (#2642): bats deliberately does NOT run in CI —
# a 15-18 minute serial suite on billed Actions minutes is the wrong trade.
# The enforcement is entirely local: per-file content-hash pass rows from
# the commit gate, plus this weekly baseline as the backstop for files
# nobody has touched lately. With CI ruled out, the baseline is the only
# thing standing behind the per-file runs, so it has to actually exist.
#
# WHAT IT SCHEDULES
#
#   TEST_SH_FULL_OK=1 scripts/test.sh --baseline --full
#
# `--baseline` stamps every JSONL row with `baseline: true`, which is what
# the push gate's 7-day window reads. `TEST_SH_FULL_OK=1` is required
# because a bare `scripts/test.sh` is refused by design (it defeats the
# iteration loop); a scheduled run is exactly the sanctioned exception.
#
# Usage:
#   install-bats-baseline-scheduler.sh --install   # launchd (macOS) / cron
#   install-bats-baseline-scheduler.sh --verify    # is it installed + fresh?
#   install-bats-baseline-scheduler.sh --uninstall
#   install-bats-baseline-scheduler.sh --dry-run   # print, change nothing
#
# Exit: 0 ok · 1 verify found a problem · 2 usage/precondition

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT" || exit 2

LABEL="com.repbyrep.claude-workflow-core.bats-baseline"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$REPO_ROOT/.claude/logs"
BASELINE_LOG="$LOG_DIR/bats-baseline.log"
RUN_LOG="$LOG_DIR/bats-run.jsonl"
# Sunday 03:00 local. Weekly, matching the push gate's 7-day window.
#
# ONE definition, consumed by both back-ends. It was written twice — once
# in CRON_LINE and once in the plist's StartCalendarInterval — so a change
# to one would have silently left the platforms on different schedules,
# and nothing compares them.
SCHED_WEEKDAY=0 # 0 = Sunday, in both cron's and launchd's numbering
SCHED_HOUR=3
SCHED_MINUTE=0
SCHED_CMD="TEST_SH_FULL_OK=1 scripts/test.sh --baseline --full"
CRON_LINE="$SCHED_MINUTE $SCHED_HOUR * * $SCHED_WEEKDAY cd $REPO_ROOT && $SCHED_CMD >>$BASELINE_LOG 2>&1"
CRON_TAG="# claude-workflow-core bats baseline (#2642)"

_usage() {
	sed -n '4,40p' "$0" >&2
	exit 2
}

_platform() {
	case "$(uname -s)" in
	Darwin) printf 'launchd\n' ;;
	*) printf 'cron\n' ;;
	esac
}

_plist_body() {
	# StartCalendarInterval, not StartInterval: a laptop that was asleep at
	# 03:00 Sunday runs the job when it next wakes, which is the behaviour
	# a weekly backstop wants. StartInterval would silently skip the week.
	cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd ${REPO_ROOT} &amp;&amp; ${SCHED_CMD}</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>${SCHED_WEEKDAY}</integer>
    <key>Hour</key><integer>${SCHED_HOUR}</integer>
    <key>Minute</key><integer>${SCHED_MINUTE}</integer>
  </dict>
  <key>StandardOutPath</key><string>${BASELINE_LOG}</string>
  <key>StandardErrorPath</key><string>${BASELINE_LOG}</string>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
PLIST
}

_is_installed() {
	case "$(_platform)" in
	launchd) [ -f "$PLIST" ] ;;
	cron) crontab -l 2>/dev/null | grep -qF "$CRON_TAG" ;;
	esac
}

_install() {
	mkdir -p "$LOG_DIR" || {
		echo "install-bats-baseline-scheduler: cannot create $LOG_DIR" >&2
		exit 2
	}
	case "$(_platform)" in
	launchd)
		mkdir -p "$(dirname "$PLIST")" || {
			echo "install-bats-baseline-scheduler: cannot create $(dirname "$PLIST")" >&2
			exit 2
		}
		_plist_body >"$PLIST" || {
			echo "install-bats-baseline-scheduler: cannot write $PLIST" >&2
			exit 2
		}
		# bootout first so a re-install replaces rather than erroring on a
		# duplicate label; its failure when nothing is loaded is expected.
		launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
		_lc_err=$(mktemp -t sched-lc.XXXXXX) || _lc_err="/dev/null"
		if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>"$_lc_err"; then
			_lc_detail=""
			[ "$_lc_err" != "/dev/null" ] && [ -s "$_lc_err" ] && _lc_detail=" launchctl said: $(head -c 200 "$_lc_err")"
			echo "install-bats-baseline-scheduler: wrote $PLIST but launchctl bootstrap failed.${_lc_detail}" >&2
			echo "  The job will load at next login. To load now: launchctl bootstrap gui/$(id -u) $PLIST" >&2
		fi
		[ "$_lc_err" != "/dev/null" ] && rm -f "$_lc_err"
		echo "✓ installed launchd agent $LABEL (Sundays 03:00)"
		echo "  plist: $PLIST"
		;;
	cron)
		local current
		current=$(crontab -l 2>/dev/null || true)
		if printf '%s\n' "$current" | grep -qF "$CRON_TAG"; then
			echo "✓ already installed (cron)"
			return 0
		fi
		printf '%s\n%s\n%s\n' "$current" "$CRON_TAG" "$CRON_LINE" | crontab - || {
			echo "install-bats-baseline-scheduler: crontab write failed" >&2
			exit 2
		}
		echo "✓ installed cron entry (Sundays 03:00)"
		;;
	esac
	echo "  runs: TEST_SH_FULL_OK=1 scripts/test.sh --baseline --full"
	echo "  log:  $BASELINE_LOG"
}

_uninstall() {
	case "$(_platform)" in
	launchd)
		launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
		# `rm -f` succeeds on a missing file, which is the intent — but it
		# can still FAIL on a read-only directory, and printing "removed"
		# after that is a claim the script did not verify. Same defect the
		# cron branch had.
		rm -f "$PLIST"
		if [ -e "$PLIST" ]; then
			echo "install-bats-baseline-scheduler: could not remove $PLIST — the agent is still installed" >&2
			exit 2
		fi
		echo "✓ removed launchd agent $LABEL"
		;;
	cron)
		local current filtered
		current=$(crontab -l 2>/dev/null || true)
		# grep rc 1 means "nothing left after filtering", which is a normal
		# outcome here (the entry was the only line). Only rc >1 is a real
		# failure. `|| true` on the whole pipeline flattened both, and then
		# printed success regardless of whether the crontab was written —
		# _install checks the same command and errors on it, so this half
		# was claiming a removal it had not verified.
		filtered=$(printf '%s\n' "$current" | grep -vF "$CRON_TAG" | grep -vF "$CRON_LINE") || {
			local grc=$?
			if [ "$grc" -gt 1 ]; then
				echo "install-bats-baseline-scheduler: grep failed (rc=$grc) filtering the crontab — NOT writing it back" >&2
				exit 2
			fi
			filtered=""
		}
		if ! printf '%s\n' "$filtered" | crontab -; then
			echo "install-bats-baseline-scheduler: crontab write FAILED — the entry was NOT removed" >&2
			exit 2
		fi
		echo "✓ removed cron entry"
		;;
	esac
}

_verify() {
	# Two independent questions, reported separately — "scheduled" and
	# "actually ran recently" fail for different reasons and have different
	# fixes, and collapsing them is how a broken cron reads as healthy.
	local rc=0
	if _is_installed; then
		echo "scheduler:  installed ($(_platform))"
	else
		echo "scheduler:  NOT INSTALLED — run: scripts/install-bats-baseline-scheduler.sh --install" >&2
		rc=1
	fi

	if [ ! -r "$RUN_LOG" ]; then
		echo "baseline:   no $RUN_LOG yet — nothing has ever run" >&2
		return 1
	fi
	local last_ts
	# The newest row with baseline:true. `fromjson?` skips malformed lines
	# rather than aborting the walk.
	local jq_err jq_rc=0
	jq_err=$(mktemp -t sched-jq.XXXXXX) || jq_err="/dev/null"
	last_ts=$(jq -r -R 'fromjson? | select(.baseline == true) | .ts // empty' "$RUN_LOG" 2>"$jq_err" | tail -1) || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		# jq missing, jq broken, log unreadable — every one of those yields
		# an empty last_ts, identical to a log with no baseline row. Same
		# observable, completely different remedy: one is "install the
		# scheduler", the other is "install jq". Reporting the first for the
		# second sends the operator down the wrong path entirely.
		local detail=""
		[ "$jq_err" != "/dev/null" ] && [ -s "$jq_err" ] && detail=" — jq said: $(head -c 200 "$jq_err")"
		echo "baseline:   UNDETERMINABLE — jq failed reading $RUN_LOG (rc=$jq_rc)${detail}. This is NOT the same as 'never run'." >&2
		[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
		return 1
	fi
	[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
	if [ -z "$last_ts" ]; then
		echo "baseline:   NEVER RUN — no row in $RUN_LOG carries baseline:true." >&2
		echo "            The push gate's 7-day fallback has therefore never fired." >&2
		return 1
	fi
	echo "baseline:   last run $last_ts"

	# Age, in whole days, without GNU date: compare epoch seconds.
	local now_s last_s age_d
	now_s=$(date -u +%s)
	# BSD date needs -j -f; GNU needs -d. Try both, and if neither works
	# say so rather than reporting a wrong age.
	last_s=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_ts" +%s 2>/dev/null ||
		date -u -d "$last_ts" +%s 2>/dev/null || printf '')
	if [ -z "$last_s" ]; then
		echo "baseline:   (could not parse '$last_ts' with either date(1) dialect — age unknown)" >&2
		return "$rc"
	fi
	age_d=$(((now_s - last_s) / 86400))
	echo "baseline:   ${age_d}d old"
	if [ "$age_d" -gt 14 ]; then
		echo "baseline:   STALE (>14d, two missed cadences) — the scheduler may be broken." >&2
		rc=1
	fi
	return "$rc"
}

case "${1:---verify}" in
--install) _install ;;
--uninstall) _uninstall ;;
--verify) _verify ;;
--dry-run)
	echo "platform: $(_platform)"
	echo "would schedule (Sundays 03:00):"
	echo "  TEST_SH_FULL_OK=1 scripts/test.sh --baseline --full"
	case "$(_platform)" in
	launchd) echo "  via launchd agent at $PLIST" ;;
	cron) echo "  via cron: $CRON_LINE" ;;
	esac
	echo "installed now: $(_is_installed && echo yes || echo no)"
	;;
-h | --help) _usage ;;
*)
	echo "install-bats-baseline-scheduler: unknown argument '$1'" >&2
	_usage
	;;
esac
