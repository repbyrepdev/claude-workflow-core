#!/usr/bin/env bats
# covers: scripts/install-bats-baseline-scheduler.sh
#
# (#2642) Two hooks have pointed at this script since v4.23-V and it did
# not exist — pre-push-pipeline-gate.sh and session-start-report.sh, three
# citations between them. (Line numbers omitted: this branch moved the
# pre-push one twice while open. Grep for the message.) So the push gate's 7-day baseline fallback never fired
# (zero rows in bats-run.jsonl carry baseline:true) and session-start has
# been telling the operator to run a command that would answer "No such
# file". An error message pointing at nothing reads as a supported path.
#
# THESE TESTS NEVER INSTALL ANYTHING. --install writes a launchd plist into
# the operator's real ~/Library/LaunchAgents and calls launchctl; a test
# suite that did that would be modifying the machine it runs on. Only the
# read-only paths are exercised, and --verify is pointed at fixture logs
# via a fake repo root.
#
# shellcheck disable=SC2030,SC2031  # bats runs each @test in a subshell;
# SCHED_PLATFORM is set in the test body and read by _sched in that same
# shell, which is the intent — the warning describes bats, not a bug.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SCRIPT="$REPO_ROOT/scripts/install-bats-baseline-scheduler.sh"
	[ -x "$SCRIPT" ]
	WORK=$(mktemp -d -t bats-sched.XXXXXX) || return 1
	(
		cd "$WORK"
		git init -q
		mkdir -p .claude/logs
	) || return 1
	RUN_LOG="$WORK/.claude/logs/bats-run.jsonl"
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	case "${WORK:-}" in
	*/bats-sched.*) rm -rf "$WORK" ;;
	esac
	return 0
}

_in_repo() { # runs the script with $WORK as the git toplevel
	# STUBBED TOO. This helper looked read-only — it only ever runs
	# --verify — but --verify calls _install_state, which on macOS runs
	# `launchctl print gui/$(id -u)/...` against the OPERATOR'S REAL
	# DOMAIN. So a "fresh repo" assertion was reading host state: it would
	# start failing the day someone followed this script's own --install
	# advice, and it is the same domain-vs-HOME confusion that left a live
	# agent registered on the development machine.
	#
	# Containment is not optional for the read paths either.
	_stub_scheduler
	run env \
		HOME="$FAKEHOME" \
		PATH="$WORK/bin:$PATH" \
		CRONTAB_FILE="$CRONTAB_FILE" \
		LAUNCHCTL_STATE="$LAUNCHCTL_STATE" \
		SCHED_PLATFORM="${SCHED_PLATFORM:-}" \
		bash -c "cd '$WORK' && '$SCRIPT' $1"
}

@test "scheduler: the file two hooks cite actually exists and is executable" {
	# The whole finding, in one assertion.
	[ -x "$SCRIPT" ] || {
		echo "the remedy hooks point at is still missing"
		return 1
	}
	# And the hooks still point HERE — a rename would recreate the defect.
	local citers
	citers=$(grep -rl 'install-bats-baseline-scheduler' "$REPO_ROOT/hooks" 2>/dev/null | wc -l | tr -d ' ')
	[ "$citers" -ge 2 ] || {
		echo "expected the two citing hooks to still reference this script, found $citers"
		return 1
	}
}

@test "scheduler: --dry-run changes nothing and says what it would do" {
	_in_repo --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"--baseline"* ]] || {
		echo "dry-run does not name the command it would schedule: $output"
		return 1
	}
	[[ $output == *"TEST_SH_FULL_OK=1"* ]] || {
		echo "dry-run omits the env a scheduled full run REQUIRES — a bare scripts/test.sh is refused by design: $output"
		return 1
	}
	# Nothing installed as a side effect — asserted as UNCHANGED, not as
	# absent. The first version skipped when an agent already existed on
	# the machine, which made the inertness claim conditional on operator
	# state and, worse, silently untested on exactly the machines where a
	# stray install would matter. Comparing before to after works either
	# way and needs no skip. (The commit gate refused the bare skip for
	# want of an issue ref, which was the right call for the wrong
	# reason — the skip should not have been there at all.)
	local plist="$HOME/Library/LaunchAgents/com.repbyrep.claude-workflow-core.bats-baseline.plist"
	local before after
	before=$([ -f "$plist" ] && cksum <"$plist" || echo absent)
	_in_repo --dry-run
	after=$([ -f "$plist" ] && cksum <"$plist" || echo absent)
	[ "$before" = "$after" ] || {
		echo "--dry-run changed the launchd agent on this machine (before=$before after=$after)"
		return 1
	}
}

@test "scheduler: --verify reports the scheduler and the baseline SEPARATELY" {
	# Two independent questions with different fixes. Collapsing them is how
	# a broken cron reads as healthy: "scheduled" and "actually ran" fail
	# for different reasons and want different remedies.
	#
	# A repo with no log at all is its own case, distinct from a log that
	# exists but holds no baseline row (below) — "nothing has ever run" and
	# "runs happen but never the baseline" are different diagnoses.
	_in_repo --verify
	[ "$status" -eq 1 ] || {
		echo "verify on a fresh repo returned $status, expected 1: $output"
		return 1
	}
	[[ $output == *"NOT INSTALLED"* ]] || {
		echo "verify does not report the missing scheduler: $output"
		return 1
	}
	[[ $output == *"nothing has ever run"* ]] || {
		echo "verify does not report the absent log: $output"
		return 1
	}
}

@test "scheduler: a log with NO baseline row says so, and names the consequence" {
	# The state this repo was actually in: 752 rows, not one of them a
	# baseline, so the push gate's 7-day fallback had never fired. The
	# message has to say that, or the operator reads "no baseline" as
	# cosmetic.
	printf '{"ts":"2099-01-01T00:00:00Z","sha":"abc","status":"pass","baseline":false}\n' >"$RUN_LOG"
	_in_repo --verify
	[ "$status" -ne 0 ]
	[[ $output == *"NEVER RUN"* ]] || {
		echo "verify does not report the missing baseline: $output"
		return 1
	}
	[[ $output == *"never fired"* ]] || {
		echo "verify does not explain the consequence (the 7-day fallback): $output"
		return 1
	}
}

@test "scheduler: --verify reads a RECENT baseline row as healthy" {
	# The row shape the push gate's CUTOFF_7D arm actually reads.
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"ts":"%s","sha":"abc","status":"pass","baseline":true}\n' "$now" >"$RUN_LOG"
	_in_repo --verify
	[[ $output == *"last run $now"* ]] || {
		echo "verify did not find the fresh baseline row: $output"
		return 1
	}
	[[ $output != *"NEVER RUN"* ]] || {
		echo "a present baseline row was reported as never run: $output"
		return 1
	}
	[[ $output == *"0d old"* ]] || {
		echo "verify did not age the row correctly: $output"
		return 1
	}
}

@test "scheduler: --verify returns 0 when installed AND fresh" {
	# NO test asserted --verify's success path. Every one asserted rc 1 or
	# rc != 0, so `_verify` could have been mutated to `return 1`
	# unconditionally and the whole suite would still have passed — while
	# the documented contract is "0 ok" and session-start-report tells the
	# operator to run it.
	SCHED_PLATFORM=cron
	_stub_scheduler
	_sched --install
	[ "$status" -eq 0 ]
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '{"ts":"%s","sha":"abc","status":"pass","baseline":true}\n' "$now" >"$RUN_LOG"
	_sched --verify
	[ "$status" -eq 0 ] || {
		echo "verify on an installed, fresh scheduler returned $status, expected 0: $output"
		return 1
	}
}

@test "scheduler: an UNPARSEABLE timestamp is not reported as healthy" {
	# When neither date(1) dialect parses the row, the first version printed
	# "(age unknown)" and returned the installed-rc — 0. Freshness is the
	# entire point of --verify, and not knowing it is not the same as it
	# being fine. The jq path already returns 1 for the same class.
	SCHED_PLATFORM=cron
	_stub_scheduler
	_sched --install
	[ "$status" -eq 0 ]
	printf '{"ts":"not-a-timestamp","baseline":true}\n' >"$RUN_LOG"
	_sched --verify
	[ "$status" -ne 0 ] || {
		echo "an unparseable baseline timestamp was reported as healthy: $output"
		return 1
	}
}

@test "scheduler: an UNREADABLE log is undeterminable, not 'never ran'" {
	# `[ ! -r ]` was true both when the log was absent and when it existed
	# but could not be read, and both printed "nothing has ever run" — an
	# assertion about history the script had not verified, sending the
	# operator to --install when the fix is a permission.
	SCHED_PLATFORM=cron
	_stub_scheduler
	printf '{"ts":"2099-01-01T00:00:00Z","baseline":true}\n' >"$RUN_LOG"
	chmod 000 "$RUN_LOG"
	_sched --verify
	chmod 644 "$RUN_LOG" 2>/dev/null || true
	if [ "$(id -u)" -eq 0 ]; then
		skip "runs as root (#2642): chmod 000 does not deny, so this cannot fail"
	fi
	[[ $output != *"nothing has ever run"* ]] || {
		echo "an unreadable log was reported as never-run: $output"
		return 1
	}
}

@test "scheduler: --verify reports a STALE baseline, and fails" {
	# >14 days is two missed weekly cadences — the signal session-start
	# surfaces. It must be non-zero, or nothing downstream can act on it.
	printf '{"ts":"2020-01-01T00:00:00Z","sha":"abc","status":"pass","baseline":true}\n' >"$RUN_LOG"
	_in_repo --verify
	[ "$status" -ne 0 ] || {
		echo "a years-old baseline was reported as healthy: $output"
		return 1
	}
	[[ $output == *STALE* ]] || {
		echo "verify does not name the staleness: $output"
		return 1
	}
}

@test "scheduler: a NON-baseline row does not satisfy --verify" {
	# Ordinary per-file runs write rows too. Counting them would report a
	# baseline that never happened — the log is full of them, which is
	# exactly how this could look healthy while being broken.
	printf '{"ts":"2099-01-01T00:00:00Z","sha":"abc","status":"pass","baseline":false}\n' >"$RUN_LOG"
	_in_repo --verify
	[[ $output == *"NEVER RUN"* ]] || {
		echo "an ordinary run row was counted as a baseline: $output"
		return 1
	}
}

@test "scheduler: a corrupt log line does not abort the walk" {
	# fromjson? skips malformed lines. A half-written row must not make
	# verify claim there is no baseline at all.
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf 'this is not json\n{"ts":"%s","status":"pass","baseline":true}\n' "$now" >"$RUN_LOG"
	_in_repo --verify
	[[ $output == *"last run $now"* ]] || {
		echo "a corrupt line hid a real baseline row: $output"
		return 1
	}
}

@test "scheduler: an unknown argument refuses instead of installing" {
	# The dangerous default. A typo must never fall through to --install.
	_in_repo --instal
	[ "$status" -eq 2 ] || {
		echo "a typo'd flag returned $status, expected 2: $output"
		return 1
	}
	[[ $output == *"unknown argument"* ]] || {
		echo "the refusal does not name the problem: $output"
		return 1
	}
}

@test "scheduler: the default action is --verify, not --install" {
	# Running it bare must REPORT, never mutate the machine.
	_in_repo ""
	[[ $output == *scheduler:* ]] || {
		echo "the bare invocation did not run verify: $output"
		return 1
	}
	[[ $output != *installed\ launchd* ]] || {
		echo "the bare invocation INSTALLED something: $output"
		return 1
	}
}

# ---- --install / --uninstall, exercised for real but harmlessly ----------
#
# Phase 0.5 was right that "untested by design" is a poor answer for the
# half of a script that mutates the machine. The reason it looked
# unavoidable was HOME: the plist path is $HOME/Library/LaunchAgents/...,
# so a naive test writes into the operator's real login agents.
#
# HOME redirects the plist FILE. It does NOT redirect the launchd DOMAIN.
#
# The first version of this comment claimed `launchctl bootstrap` "still
# fails there". It does not: bootstrap takes an arbitrary plist path, and
# the domain target is `gui/$(id -u)` — the operator's real one. A phase-1
# agent found a LIVE LaunchAgent registered on the development machine,
# pointing at a bats fixture temp dir that had already been deleted. The
# suite installed it and teardown removed only the file.
#
# Worse than residue: if the operator has actually installed the scheduler
# — the entire point of this change — running the suite would `bootout`
# their real agent, and `--verify` (which then checked only for the plist
# FILE) would keep reporting "installed" while the weekly baseline silently
# stopped firing. The exact never-fired failure this script exists to fix,
# caused by its own tests.
#
# So launchctl is STUBBED, exactly as crontab is. Neither back-end may
# reach the machine.
#
# CRONTAB IS NOT LIKE HOME. On a non-Darwin runner these same tests take
# the cron branch, which calls `crontab -` and would REWRITE THE
# DEVELOPER'S ACTUAL CRONTAB. Phase 0.5 caught that in the first version,
# where the plist assertions were Darwin-guarded but the invocation was
# not — the guard protected the assertion and not the side effect.
#
# So a stub `crontab` goes on PATH for every mutating test. It records
# what it was asked to do into the fixture, which is also what makes the
# cron path assertable at all rather than merely unexercised.
_stub_launchctl() {
	mkdir -p "$WORK/bin"
	cat >"$WORK/bin/launchctl" <<'STUB'
#!/bin/bash
# Records instead of touching the real launchd domain.
FAKE="${LAUNCHCTL_STATE:?stub needs LAUNCHCTL_STATE}"
case "${1:-}" in
bootstrap)
	# $3 is the plist path; register it.
	printf '%s
' "${3:-}" >"$FAKE"
	;;
bootout)
	rm -f "$FAKE"
	;;
print)
	[ -s "$FAKE" ] || exit 113
	printf 'stub: loaded from %s
' "$(cat "$FAKE")"
	;;
*) exit 2 ;;
esac
STUB
	chmod +x "$WORK/bin/launchctl"
	export LAUNCHCTL_STATE="$WORK/fake-launchd"
}

# Both back-ends stubbed, plus a redirected HOME. Used by every test that
# invokes --install or --uninstall.
_stub_scheduler() {
	_stub_crontab
	_stub_launchctl
	FAKEHOME="$WORK/home"
	mkdir -p "$FAKEHOME"
}

_sched() { # $1 = args; runs with every side effect contained
	# PATH is built HERE and passed via `env`, not written into the inner
	# shell's command string. A quoted "$PATH" inside that string does not
	# expand, leaving the stub dir as the ENTIRE path — every real command
	# then fails with "uname: command not found" and the test reports the
	# script broken. Second time this exact trap has fired in this session.
	run env \
		HOME="$FAKEHOME" \
		PATH="$WORK/bin:$PATH" \
		CRONTAB_FILE="$CRONTAB_FILE" \
		LAUNCHCTL_STATE="$LAUNCHCTL_STATE" \
		SCHED_PLATFORM="${SCHED_PLATFORM:-}" \
		bash -c "cd '$WORK' && '$SCRIPT' $1"
}

_stub_crontab() {
	mkdir -p "$WORK/bin"
	cat >"$WORK/bin/crontab" <<'STUB'
#!/bin/bash
# Records instead of mutating. -l prints the fake table; `-` reads a new one.
FAKE="${CRONTAB_FILE:?stub needs CRONTAB_FILE}"
case "${1:-}" in
-l) [ -f "$FAKE" ] && cat "$FAKE" || exit 1 ;;
-) cat >"$FAKE" ;;
*) exit 2 ;;
esac
STUB
	chmod +x "$WORK/bin/crontab"
	export CRONTAB_FILE="$WORK/fake-crontab"
}

@test "scheduler: --install writes a plist and reports where" {
	_stub_scheduler
	_sched --install
	[ "$status" -eq 0 ] || {
		echo "--install failed (rc $status): $output"
		return 1
	}
	local plist="$FAKEHOME/Library/LaunchAgents/com.repbyrep.claude-workflow-core.bats-baseline.plist"
	if [ "$(uname -s)" = "Darwin" ]; then
		[ -s "$plist" ] || {
			echo "--install reported success but wrote no plist at $plist"
			return 1
		}
		# The scheduled command must carry the env a full run REQUIRES; a
		# bare scripts/test.sh is refused by design, so a plist missing it
		# would install a job that can never succeed.
		grep -q 'TEST_SH_FULL_OK=1' "$plist" || {
			echo "the installed job omits TEST_SH_FULL_OK — it would be refused every week: $(cat "$plist")"
			return 1
		}
		grep -q -- '--baseline' "$plist" || {
			echo "the installed job does not pass --baseline, so its rows would not satisfy the push gate: $(cat "$plist")"
			return 1
		}
		# And it must run in THIS repo, not wherever launchd starts.
		grep -qF "$WORK" "$plist" || {
			echo "the installed job does not cd into the repo: $(cat "$plist")"
			return 1
		}
	fi
	[[ $output == *installed* ]] || {
		echo "--install did not say what it did: $output"
		return 1
	}
}

@test "scheduler: --install is idempotent — one entry, not two" {
	# The title says "not duplicate or error" and the first version asserted
	# only the "not error" half: rc 0 twice. Remove the already-installed
	# early return from the cron branch and a second run appends a second
	# tag and line — and that test still passed, because nothing read the
	# crontab back. The duplication is the claim, so the duplication is what
	# gets counted.
	SCHED_PLATFORM=cron
	_stub_scheduler
	_sched --install
	[ "$status" -eq 0 ]
	_sched --install
	[ "$status" -eq 0 ] || {
		echo "a second --install failed (rc $status): $output"
		return 1
	}
	local n
	n=$(grep -cF "claude-workflow-core bats baseline" "$CRONTAB_FILE" 2>/dev/null || true)
	[ "$n" -eq 1 ] || {
		echo "two --install runs left $n entries, expected exactly 1: $(cat "$CRONTAB_FILE")"
		return 1
	}
}

@test "scheduler: --uninstall removes what --install wrote" {
	_stub_scheduler
	local plist="$FAKEHOME/Library/LaunchAgents/com.repbyrep.claude-workflow-core.bats-baseline.plist"
	_stub_crontab
	_sched --install
	[ "$status" -eq 0 ]
	_sched --uninstall
	[ "$status" -eq 0 ] || {
		echo "--uninstall failed (rc $status): $output"
		return 1
	}
	if [ "$(uname -s)" = "Darwin" ]; then
		[ ! -f "$plist" ] || {
			echo "--uninstall reported success but the plist is still there"
			return 1
		}
	fi
}

@test "scheduler: --uninstall removes the CRON entry, and nothing else" {
	# The cron removal was asserted on no platform: skipped on Darwin,
	# executed-but-uninspected on Linux — and it is the branch whose own
	# comment records that it once "claimed a removal it had not verified".
	# It is also the half that mutates operator state, where the failure
	# mode is a scheduler the operator believes is gone.
	SCHED_PLATFORM=cron
	_stub_scheduler
	# A pre-existing unrelated job, which must survive.
	printf '%s\n' "0 9 * * 1 echo somebody-elses-job" >"$CRONTAB_FILE"
	_sched --install
	[ "$status" -eq 0 ]
	grep -qF "claude-workflow-core bats baseline" "$CRONTAB_FILE" || {
		echo "install did not write the entry: $(cat "$CRONTAB_FILE")"
		return 1
	}
	_sched --uninstall
	[ "$status" -eq 0 ] || {
		echo "--uninstall failed (rc $status): $output"
		return 1
	}
	grep -qF "claude-workflow-core bats baseline" "$CRONTAB_FILE" && {
		echo "--uninstall reported success but the entry is still there: $(cat "$CRONTAB_FILE")"
		return 1
	}
	grep -qF "somebody-elses-job" "$CRONTAB_FILE" || {
		echo "--uninstall deleted an UNRELATED job: $(cat "$CRONTAB_FILE")"
		return 1
	}
}

@test "scheduler: an unreadable crontab REFUSES rather than replacing it" {
	# `crontab -l` rc 1 means "no crontab yet" — a normal empty start. Any
	# other rc means we do not know the contents, and writing back from an
	# assumed-empty string replaces every job the operator has with ours.
	# The uninstall path was hardened for grep's rc while the read that
	# PRODUCES its input was not.
	SCHED_PLATFORM=cron
	_stub_scheduler
	# A stub whose -l fails hard (rc 2), as a denied or broken spool does.
	cat >"$WORK/bin/crontab" <<'STUB'
#!/bin/bash
case "${1:-}" in
-l) echo "crontab: cannot read" >&2; exit 2 ;;
-) cat >"${CRONTAB_FILE:?}" ;;
esac
STUB
	chmod +x "$WORK/bin/crontab"
	printf '%s\n' "0 9 * * 1 echo precious" >"$CRONTAB_FILE"
	_sched --install
	[ "$status" -eq 2 ] || {
		echo "an unreadable crontab did not refuse (rc $status): $output"
		return 1
	}
	grep -qF precious "$CRONTAB_FILE" || {
		echo "the operator's crontab was REPLACED despite the read failing: $(cat "$CRONTAB_FILE")"
		return 1
	}
}

@test "scheduler: --verify sees the agent that --install wrote" {
	# The two halves must agree. An installer whose own verify cannot find
	# its work is how "cron may be broken" becomes unfalsifiable.
	_stub_scheduler
	_sched --install
	[ "$status" -eq 0 ]
	_sched --verify
	[[ $output == *"scheduler:  installed"* ]] || {
		echo "verify cannot see the agent install just wrote: $output"
		return 1
	}
	[[ $output != *"NOT INSTALLED"* ]] || {
		echo "verify reports NOT INSTALLED right after a successful install: $output"
		return 1
	}
}

@test "scheduler: the CRON entry it writes is complete and correct" {
	SCHED_PLATFORM=cron
	# Phase 0.5 conf 6: the cron branch's status was checked but its CONTENT
	# never was, so a CRON_LINE missing TEST_SH_FULL_OK — which a bare
	# scripts/test.sh is refused without — would install a job that can
	# never succeed, weekly, silently. The stub records what was written,
	# which is what makes this assertable at all.
	_stub_scheduler
	_sched --install
	[ "$status" -eq 0 ] || {
		echo "--install failed: $output"
		return 1
	}
	[ -s "$CRONTAB_FILE" ] || {
		echo "the cron branch wrote nothing"
		return 1
	}
	grep -q 'TEST_SH_FULL_OK=1' "$CRONTAB_FILE" || {
		echo "the cron entry omits TEST_SH_FULL_OK — a bare scripts/test.sh is refused, so this job could never succeed: $(cat "$CRONTAB_FILE")"
		return 1
	}
	grep -q -- '--baseline' "$CRONTAB_FILE" || {
		echo "the cron entry does not pass --baseline, so its rows would not satisfy the push gate: $(cat "$CRONTAB_FILE")"
		return 1
	}
}

@test "scheduler: both back-ends schedule the SAME time" {
	# The schedule was written twice — CRON_LINE and the plist's
	# StartCalendarInterval — with nothing comparing them, so a change to
	# one would have left the platforms on different weeks. Both now derive
	# from SCHED_*; this asserts they agree, by reading the script itself.
	local weekday hour minute
	weekday=$(grep -m1 '^SCHED_WEEKDAY=' "$SCRIPT" | sed 's/[^0-9]*\([0-9]*\).*/\1/')
	hour=$(grep -m1 '^SCHED_HOUR=' "$SCRIPT" | sed 's/[^0-9]*\([0-9]*\).*/\1/')
	minute=$(grep -m1 '^SCHED_MINUTE=' "$SCRIPT" | sed 's/[^0-9]*\([0-9]*\).*/\1/')
	[ -n "$weekday" ] && [ -n "$hour" ] && [ -n "$minute" ] || {
		echo "could not read the schedule constants — this test checked nothing"
		return 1
	}
	# Neither back-end may carry its own literal any more.
	grep -qE '^CRON_LINE=.*\$SCHED_MINUTE .*\$SCHED_HOUR .*\$SCHED_WEEKDAY' "$SCRIPT" || {
		echo "CRON_LINE does not derive from the shared schedule constants"
		return 1
	}
	grep -q 'Weekday</key><integer>${SCHED_WEEKDAY}' "$SCRIPT" || {
		echo "the plist does not derive from the shared schedule constants"
		return 1
	}
}

@test "scheduler: a jq failure is UNDETERMINABLE, not 'never run'" {
	# Same empty last_ts either way, completely different remedy: one is
	# "install the scheduler", the other is "install jq". Reporting the
	# first for the second sends the operator down the wrong path.
	#
	# Forced with a jq stub that fails, earlier on PATH than the real one.
	mkdir -p "$WORK/bin"
	printf '#!/bin/bash\necho "jq: simulated failure" >&2\nexit 5\n' >"$WORK/bin/jq"
	chmod +x "$WORK/bin/jq"
	printf '{"ts":"2099-01-01T00:00:00Z","baseline":true}\n' >"$RUN_LOG"
	run bash -c "cd '$WORK' && PATH='$WORK/bin:$PATH' '$SCRIPT' --verify"
	[ "$status" -ne 0 ]
	[[ $output == *UNDETERMINABLE* ]] || {
		echo "a jq failure was reported as a missing baseline: $output"
		return 1
	}
	[[ $output == *"NOT the same as"* ]] || {
		echo "the message does not distinguish the two cases: $output"
		return 1
	}
}
