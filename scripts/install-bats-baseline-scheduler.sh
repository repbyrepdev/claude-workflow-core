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
# (Line numbers deliberately omitted. The first version cited :859; this
# branch then moved that line twice, to :884 and back to :858, so the
# correction drifted as fast as the thing it corrected. A citation that
# drifts is worse than none — it sends the reader somewhere wrong with
# confidence. Grep for the message instead.)
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

# NO `|| pwd` fallback. This script SCHEDULES a command that cds into
# REPO_ROOT and runs the test suite weekly. Falling back to the current
# directory means scheduling a job against wherever the operator happened
# to be standing — which will not be a repo, so the job fails silently
# every week, and the backstop this whole change exists to provide reports
# itself installed. Outside a repo there is no right answer, so refuse.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
if [ -z "$REPO_ROOT" ]; then
	echo "install-bats-baseline-scheduler: not inside a git repository — refusing to schedule a job against an arbitrary directory" >&2
	exit 2
fi
cd "$REPO_ROOT" || exit 2

# The repo path is interpolated into an XML document AND into a crontab
# line AND into a `bash -lc` command string. Each has different
# metacharacters, and the security pass demonstrated all three: a path
# containing `</string>` injects extra ProgramArguments that launchd then
# executes weekly; a path containing a newline injects a whole additional
# crontab entry; `;` or `$(...)` is shell injection into the scheduled
# command. A `%` truncates a cron command, and a bare space breaks the `cd`
# so the job silently never runs.
#
# Escaping correctly for three grammars at once is the kind of thing that
# is wrong in one of them. REFUSING is the honest move: these characters do
# not belong in a repository path, the operator can see the problem
# immediately, and nothing is scheduled from an ambiguous string.
#
# Stated as an ALLOW-LIST, not a deny-list. The first version enumerated
# the dangerous characters and got the bracket-expression escaping wrong,
# refusing this repo's own perfectly ordinary path — a deny-list has to be
# exhaustive across three grammars AND correctly escaped, and it was
# neither. An allow-list is wrong only in the safe direction: it refuses a
# path it could have handled, and says so.
case "$REPO_ROOT" in
*[!a-zA-Z0-9/._-]*)
	echo "install-bats-baseline-scheduler: REFUSING — the repository path contains a character that cannot be safely written into a launchd plist or a crontab line:" >&2
	echo "  $REPO_ROOT" >&2
	echo "  Scheduling from it risks injecting extra arguments or an extra cron entry. Move the repo to a path without spaces, quotes, or shell/XML metacharacters." >&2
	exit 2
	;;
esac

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
	# A here-doc, not `sed -n '4,40p' "$0"`. The range was already wrong —
	# it stopped at the "# Usage:" header and printed none of the usage —
	# and a hand-maintained line range over the file's own comments is the
	# same drifting-citation defect the header of this file complains
	# about, one screen further down.
	cat >&2 <<'USAGE'
install-bats-baseline-scheduler.sh — weekly bats baseline scheduler

  --install     schedule it (launchd on macOS, cron elsewhere)
  --verify      is it scheduled, and did it actually run? (default)
  --uninstall   remove it
  --dry-run     print what would be scheduled, change nothing

Env:
  SCHED_PLATFORM=launchd|cron   force a back-end (testing)

Exit: 0 ok · 1 verify found a problem · 2 usage/precondition
USAGE
	exit 2
}

# SCHED_PLATFORM overrides the auto-detected back-end. It exists so the
# cron path can be exercised on a macOS developer machine — without it the
# entire cron half is unreachable on the only platform this suite runs on,
# and the tests that claim to check it assert nothing. The test suite
# passed a `_FORCE_CRON` that this script never read, which is exactly that
# failure wearing the appearance of coverage.
_platform() {
	case "${SCHED_PLATFORM:-}" in
	launchd | cron)
		printf '%s\n' "$SCHED_PLATFORM"
		return 0
		;;
	'') ;;
	*)
		echo "install-bats-baseline-scheduler: SCHED_PLATFORM must be 'launchd' or 'cron', got '$SCHED_PLATFORM'" >&2
		exit 2
		;;
	esac
	case "$(uname -s)" in
	Darwin) printf 'launchd\n' ;;
	*) printf 'cron\n' ;;
	esac
}

# Resolved ONCE. It cannot change within a run, and it was being recomputed
# through a command substitution seven times.
PLATFORM=$(_platform)

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

# Three states, not two. "the plist is on disk" is a PROXY for "launchd
# knows about this job", and they come apart on the path this script itself
# creates: _install treats a failed `launchctl bootstrap` as non-fatal and
# leaves the plist behind, after which a file check reports "installed"
# for a job launchd has never heard of — the unfalsifiable "cron may be
# broken" state this script exists to end.
#
# Echoes: loaded | written-not-loaded | absent | unknown
_install_state() {
	case "$PLATFORM" in
	launchd)
		# launchctl's rc distinguishes "no such service" from "could not
		# ask" — 113 is the not-found code, anything else means the query
		# itself failed and the answer is UNKNOWN, not absent. Collapsing
		# them would report a job as missing when launchctl is simply
		# unavailable, and the remedy for those differs.
		local lrc=0
		launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || lrc=$?
		if [ "$lrc" -eq 0 ]; then
			printf 'loaded\n'
		elif [ "$lrc" -ne 113 ] && ! command -v launchctl >/dev/null 2>&1; then
			printf 'unknown\n'
		elif [ -f "$PLIST" ]; then
			printf 'written-not-loaded\n'
		else
			printf 'absent\n'
		fi
		;;
	cron)
		local out crc=0
		out=$(crontab -l 2>/dev/null) || crc=$?
		if [ "$crc" -gt 1 ]; then
			printf 'unknown\n'
		elif printf '%s\n' "$out" | grep -qF "$CRON_TAG"; then
			printf 'loaded\n'
		else
			printf 'absent\n'
		fi
		;;
	esac
}

_is_installed() {
	[ "$(_install_state)" = "loaded" ]
}

_install() {
	mkdir -p "$LOG_DIR" || {
		echo "install-bats-baseline-scheduler: cannot create $LOG_DIR" >&2
		exit 2
	}
	case "$PLATFORM" in
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
		local _lc_err _lc_detail
		_lc_err=$(mktemp -t sched-lc.XXXXXX) || _lc_err="/dev/null"
		if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>"$_lc_err"; then
			_lc_detail=""
			[ "$_lc_err" != "/dev/null" ] && [ -s "$_lc_err" ] && _lc_detail=" launchctl said: $(head -c 200 "$_lc_err")"
			echo "install-bats-baseline-scheduler: wrote $PLIST but launchctl bootstrap failed.${_lc_detail}" >&2
			echo "  The job will load at next login. To load now: launchctl bootstrap gui/$(id -u) $PLIST" >&2
		fi
		[ "$_lc_err" != "/dev/null" ] && rm -f "$_lc_err"
		printf '✓ installed launchd agent %s (weekday=%s %02d:%02d)\n' "$LABEL" "$SCHED_WEEKDAY" "$SCHED_HOUR" "$SCHED_MINUTE"
		echo "  plist: $PLIST"
		;;
	cron)
		local current crc=0
		# rc 1 = "no crontab for user", a normal empty start. Anything else
		# (127 = crontab missing, denied by cron.deny, broken spool) means
		# we do NOT know the current contents — and writing back from an
		# assumed-empty string would delete every other job the operator
		# has. The uninstall path was hardened for grep's rc and this read,
		# which produces its input, was not.
		current=$(crontab -l 2>/dev/null) || crc=$?
		if [ "$crc" -gt 1 ]; then
			echo "install-bats-baseline-scheduler: cannot read the current crontab (rc=$crc) — REFUSING to write one, which would replace any other scheduled jobs" >&2
			exit 2
		fi
		if printf '%s\n' "$current" | grep -qF "$CRON_TAG"; then
			echo "✓ already installed (cron)"
			return 0
		fi
		printf '%s\n%s\n%s\n' "$current" "$CRON_TAG" "$CRON_LINE" | crontab - || {
			echo "install-bats-baseline-scheduler: crontab write failed" >&2
			exit 2
		}
		printf '✓ installed cron entry (weekday=%s %02d:%02d)\n' "$SCHED_WEEKDAY" "$SCHED_HOUR" "$SCHED_MINUTE"
		;;
	esac
	echo "  runs: $SCHED_CMD"
	echo "  log:  $BASELINE_LOG"
}

_uninstall() {
	case "$PLATFORM" in
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
		local current filtered crc=0
		current=$(crontab -l 2>/dev/null) || crc=$?
		if [ "$crc" -gt 1 ]; then
			echo "install-bats-baseline-scheduler: cannot read the current crontab (rc=$crc) — REFUSING to write one, which would delete every other scheduled job" >&2
			exit 2
		fi
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
	# Report the STATE, not a boolean. _install_state distinguishes four
	# outcomes and collapsing them to installed/not-installed throws away
	# exactly the one that matters: a plist written but never loaded is the
	# unfalsifiable "cron may be broken" case this script exists to end,
	# and it is not the same as absent (different fix) or unknown (no
	# answer at all).
	local rc=0 state
	state=$(_install_state)
	case "$state" in
	loaded)
		echo "scheduler:  installed and loaded ($PLATFORM)"
		;;
	written-not-loaded)
		echo "scheduler:  plist WRITTEN BUT NOT LOADED ($PLATFORM) — launchd does not know about $LABEL, so nothing will fire. Re-run --install, or: launchctl bootstrap gui/$(id -u) $PLIST" >&2
		rc=1
		;;
	absent)
		echo "scheduler:  NOT INSTALLED — run: scripts/install-bats-baseline-scheduler.sh --install" >&2
		rc=1
		;;
	*)
		echo "scheduler:  UNDETERMINABLE ($PLATFORM) — could not read the current schedule. This is NOT the same as not installed." >&2
		rc=1
		;;
	esac

	# ABSENT and UNREADABLE are different facts with different fixes, and
	# `[ ! -r ]` was true of both — so a permissions problem was reported as
	# "nothing has ever run", an assertion about history the script had not
	# verified, sending the operator to --install when the fix is a chmod.
	# The jq branch below already draws this distinction; this one did not.
	if [ ! -e "$RUN_LOG" ]; then
		echo "baseline:   no $RUN_LOG yet — nothing has ever run" >&2
		return 1
	fi
	if [ ! -r "$RUN_LOG" ]; then
		echo "baseline:   UNDETERMINABLE — $RUN_LOG exists but cannot be read (permissions?). This is NOT the same as never run." >&2
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
		# NOT `return $rc` — which is 0 whenever the scheduler is installed,
		# reporting healthy for a freshness question that was never
		# answered. Freshness is the whole point of --verify, and the jq
		# branch above already returns 1 for the same class of not-knowing.
		echo "baseline:   UNDETERMINABLE — could not parse '$last_ts' with either date(1) dialect, so the age is unknown. This is NOT the same as fresh." >&2
		return 1
	fi
	age_d=$(((now_s - last_s) / 86400))
	if [ "$age_d" -lt 0 ]; then
		# A row dated in the future is not fresh, it is wrong — a clock
		# skew, a hand-edited log, or a fabricated entry. Reporting "-4000d
		# old" as healthy would let any such row satisfy the freshness
		# check forever, which is the easiest possible way to fake a
		# baseline that never ran.
		echo "baseline:   INVALID — '$last_ts' is in the FUTURE (${age_d}d). A future timestamp cannot be a record of a run that happened." >&2
		return 1
	fi
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
	echo "platform: $PLATFORM"
	printf 'would schedule (weekday=%s %02d:%02d):\n' "$SCHED_WEEKDAY" "$SCHED_HOUR" "$SCHED_MINUTE"
	echo "  $SCHED_CMD"
	case "$PLATFORM" in
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
