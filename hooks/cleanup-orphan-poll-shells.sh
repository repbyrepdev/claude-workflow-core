#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W5 #861: kill orphan `until ! pgrep ... ; do sleep` polling shells
# left over from prior Claude sessions where a `Bash run_in_background:true`
# poll loop kept iterating after its target process exited.
#
# (`auto-register: false` here means "skip the meta-freshness auto-
# registration walker"; this hook is wired manually in .claude/settings.json
# under SessionStart + UserPromptSubmit + Stop.)
#
# Trigger: SessionStart + UserPromptSubmit + Stop hooks. SessionStart
# catches orphans from PRIOR sessions. UserPromptSubmit + Stop catch
# orphans spawned WITHIN this session (sessions can span many hours
# across multiple epics — relying on SessionStart alone would let
# in-session orphans accumulate until next session restart).
# Threshold: only kills processes older than 30 minutes — protects in-
# flight legitimate waits started seconds ago by this session.
#
# Pattern detection: matches ANY user process whose command line contains
# `until ! pgrep` OR `until grep -q "completed"` — substring match, not
# shell-binary-specific (orphan shape is in the cmdline, not the binary).
# Both shapes observed during v4.28-W5 #836 dogfood (some 11 days old).
#
# Logs: appends per-kill JSONL records to .claude/logs/orphan-cleanup.jsonl
# with {ts, pid, age_s, cmd_prefix}. Operator-visible audit trail.
#
# Memory: complements the user-scope memory `feedback_use_monitor_for_
# until_loops` (lives under ~/.claude/projects/<proj>/memory/, not tracked
# in this repo) — which says "don't use Bash run_in_background with
# until-pgrep, use Monitor". This hook is the safety net for when that
# rule gets violated.

# Resolve repo root from script location first (decouples from caller's cwd),
# falling back to `git rev-parse` if the script is invoked from outside the
# normal hook layout. Either way, `exit 0` (no-op) if no repo can be found —
# this hook is a cleanup utility, not a critical-path gate.
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=""
if [ -d "$SELF_DIR/../.." ] && [ -d "$SELF_DIR/../../.git" ]; then
	REPO_ROOT=$(cd "$SELF_DIR/../.." && pwd)
else
	rev_err=$(mktemp -t orphan-cleanup-rev-err.XXXXXX 2>/dev/null) || rev_err="/dev/null"
	REPO_ROOT=$(git rev-parse --show-toplevel 2>"$rev_err") || REPO_ROOT=""
	if [ -z "$REPO_ROOT" ] && [ "$rev_err" != "/dev/null" ] && [ -s "$rev_err" ]; then
		echo "cleanup-orphan-poll-shells: git rev-parse failed: $(head -c 200 "$rev_err") — skipping (not a repo or git error)" >&2
	fi
	[ "$rev_err" != "/dev/null" ] && rm -f "$rev_err"
fi
[ -n "$REPO_ROOT" ] || exit 0

LOG_DIR="$REPO_ROOT/.claude/logs"
LOG_FILE="$LOG_DIR/orphan-cleanup.jsonl"
mkdir_err=$(mktemp -t orphan-cleanup-mkdir-err.XXXXXX 2>/dev/null) || mkdir_err="/dev/null"
if ! mkdir -p "$LOG_DIR" 2>"$mkdir_err"; then
	if [ "$mkdir_err" != "/dev/null" ] && [ -s "$mkdir_err" ]; then
		echo "cleanup-orphan-poll-shells: WARN: mkdir $LOG_DIR failed: $(head -c 200 "$mkdir_err") — audit log writes will be dropped" >&2
	else
		echo "cleanup-orphan-poll-shells: WARN: mkdir $LOG_DIR failed — audit log writes will be dropped" >&2
	fi
fi
[ "$mkdir_err" != "/dev/null" ] && rm -f "$mkdir_err"

# Threshold in seconds: skip processes younger than this (in-flight legit waits).
# v4.28-W5 #861 CR-CLI fix: validate ORPHAN_CLEANUP_MIN_AGE_S as a non-negative
# integer (regex check); a non-numeric value would silently bypass the protect-
# young-orphans contract under `[ "$age_s" -lt "$MIN_AGE_S" ]` since `test`
# error-exits on non-numeric → `set -e` aborts → the protective comparison
# never runs. Fall back to 1800 (30 min default) + WARN on invalid input so
# operators can spot env-poisoning attempts or typos. Tests pass 0 explicitly
# to force-kill any age; non-numeric should reject + default-back.
_raw_min_age="${ORPHAN_CLEANUP_MIN_AGE_S:-1800}"
if [[ "$_raw_min_age" =~ ^[0-9]+$ ]]; then
	MIN_AGE_S="$_raw_min_age"
else
	echo "cleanup-orphan-poll-shells: WARN: ORPHAN_CLEANUP_MIN_AGE_S='$_raw_min_age' is not a non-negative integer — falling back to 1800s default" >&2
	MIN_AGE_S=1800
fi
unset _raw_min_age

# Pattern: orphan poll shapes we've observed. Substring matching via grep
# -E — anchoring inside the pattern at `until[[:space:]]+!` would be more
# precise but risks missing variants like `until!pgrep` or future shapes;
# substring is conservative + the negative test asserts non-orphan zsh
# processes are spared.
ORPHAN_PATTERN='until ! pgrep|until grep -q "completed"'

# Convert elapsed-time (ps -o etime: [[dd-]hh:]mm:ss) to seconds.
# This is more portable than relying on `ps -o etimes` which isn't on every BSD ps.
_etime_to_seconds() {
	local et=$1 days hours mins secs
	days=0
	hours=0
	# Split on `-` for days.
	if [[ "$et" == *-* ]]; then
		days=${et%%-*}
		et=${et#*-}
	fi
	# Now et is [hh:]mm:ss. Split on `:`.
	local IFS=':'
	read -r -a parts <<<"$et"
	if [ "${#parts[@]}" -eq 3 ]; then
		hours=${parts[0]}
		mins=${parts[1]}
		secs=${parts[2]}
	elif [ "${#parts[@]}" -eq 2 ]; then
		mins=${parts[0]}
		secs=${parts[1]}
	else
		# Unparseable etime — return -1 sentinel so caller WARNs + skips
		# instead of treating as 0 and silently sparing (which would
		# recreate the original "silent orphan accumulation" bug class).
		echo -1
		return
	fi
	# Strip leading zeros to avoid octal interpretation.
	days=$((10#${days:-0}))
	hours=$((10#${hours:-0}))
	mins=$((10#${mins:-0}))
	secs=$((10#${secs:-0}))
	echo $((days * 86400 + hours * 3600 + mins * 60 + secs))
}

killed=0
# `ps -u $USER -o pid=,etime=,command=` — strip column headers, get raw fields.
# `-u $USER` works on both macOS BSD ps + GNU coreutils ps (verified on
# Darwin 25.4). Surface ps failures as WARN since silent suppression would
# mask "no orphans found" vs "ps broken" — they look identical from the
# caller's perspective otherwise.
ps_err=$(mktemp -t orphan-cleanup-ps-err.XXXXXX 2>/dev/null) || ps_err="/dev/null"
ps_rc=0
ps_out=$(ps -u "$USER" -o pid=,etime=,command= 2>"$ps_err") || ps_rc=$?
if [ "$ps_rc" -ne 0 ]; then
	if [ "$ps_err" != "/dev/null" ] && [ -s "$ps_err" ]; then
		echo "cleanup-orphan-poll-shells: WARN: ps -u $USER failed (rc=$ps_rc): $(head -c 200 "$ps_err") — orphan scan skipped" >&2
	else
		echo "cleanup-orphan-poll-shells: WARN: ps -u $USER failed (rc=$ps_rc) — orphan scan skipped" >&2
	fi
	ps_out=""
fi
[ "$ps_err" != "/dev/null" ] && rm -f "$ps_err"

# grep -E returns rc=1 on no-match (legit empty — no orphans to clean),
# rc>1 on real error (read failure, invalid regex). Discriminate: rc=1
# is silent (empty filtered output); rc>1 surfaces a WARN.
filtered=""
if [ -n "$ps_out" ]; then
	grep_rc=0
	filtered=$(printf '%s\n' "$ps_out" | grep -E "$ORPHAN_PATTERN") || grep_rc=$?
	if [ "$grep_rc" -gt 1 ]; then
		echo "cleanup-orphan-poll-shells: WARN: grep filter failed (rc=$grep_rc) — orphan scan skipped" >&2
		filtered=""
	fi
fi

while IFS= read -r line; do
	[ -n "$line" ] || continue
	# `read` collapses internal whitespace in `cmd` — acceptable because the
	# audit-log truncates cmd_prefix to 200 chars anyway (whitespace fidelity
	# does not matter for orphan identification or operator triage).
	read -r pid etime cmd <<<"$line"
	[ -n "$pid" ] && [ -n "$etime" ] || continue
	age_s=$(_etime_to_seconds "$etime")
	if [ "$age_s" -lt 0 ]; then
		# Sentinel from _etime_to_seconds: unparseable etime. WARN +
		# skip rather than treat as age=0 and silently spare — silent
		# skip is the original bug class this hook prevents.
		echo "cleanup-orphan-poll-shells: WARN: unparseable etime '$etime' for pid=$pid — skipping" >&2
		continue
	fi
	if [ "$age_s" -lt "$MIN_AGE_S" ]; then
		continue
	fi
	# v4.28-W5 #861 Phase 1 r1 security-review fix: re-verify cmdline
	# matches the orphan pattern immediately before SIGKILL. Closes the
	# PID-recycling TOCTOU window between `ps -u $USER` (line ~115) and
	# `kill -9` here: if the orphan exited and the kernel recycled the
	# PID to a different user-owned process (editor, build job), the
	# original cmdline no longer matches the orphan pattern → skip
	# rather than SIGKILL the wrong process. Cheap: one extra `ps`.
	# v4.28-W5 #861 CR-CLI fix: capture ps rc instead of `|| true` swallow,
	# so a real ps failure (binary missing, perms revoked, OOM) surfaces as
	# WARN with pid+rc rather than masquerading as "PID already exited"
	# (the benign race case). Both branches continue without killing, but
	# the WARN gives operators the discriminator. ESRCH-class (PID gone)
	# is the typical case — rc=1 + empty stdout, no stderr — handled by
	# the `grep -Eq` falling through to no-match.
	ps_recheck_rc=0
	current_cmd=$(ps -o command= -p "$pid" 2>/dev/null) || ps_recheck_rc=$?
	if [ "$ps_recheck_rc" -ne 0 ] && [ "$ps_recheck_rc" -ne 1 ]; then
		# rc=1 from ps -p is "no such process" (PID gone) — benign race,
		# silent skip. rc>1 is a real failure — surface with WARN so
		# operators can distinguish.
		echo "cleanup-orphan-poll-shells: WARN: ps -p $pid re-verify failed (rc=$ps_recheck_rc) — skipping kill" >&2
		continue
	fi
	if ! printf '%s\n' "$current_cmd" | grep -Eq "$ORPHAN_PATTERN"; then
		# Either the PID already exited (ps empty) OR was recycled to
		# a non-orphan-shape process. Either way: don't kill, don't
		# audit-row (no kill happened, so no row).
		continue
	fi
	# v4.28-W5 #861 Phase 1 r1 silent-failure-hunter F2/F3 fix: kill
	# FIRST + capture stderr, audit row records the OUTCOME. Prior
	# (log-first-then-kill) left the audit log lying when kill failed —
	# operator post-mortem'ing `orphan-cleanup.jsonl` would see "pid X
	# cleaned" for a process still alive. New shape: kill_ok:bool in
	# the row + kernel stderr discriminator (ESRCH=already-exited race
	# vs EPERM=perms-revoked → operator-actionable).
	kill_err=$(mktemp -t orphan-cleanup-kill-err.XXXXXX 2>/dev/null) || kill_err="/dev/null"
	kill_rc=0
	kill -9 "$pid" 2>"$kill_err" || kill_rc=$?
	kill_stderr=""
	if [ "$kill_err" != "/dev/null" ] && [ -s "$kill_err" ]; then
		kill_stderr=$(head -c 200 "$kill_err")
	fi
	[ "$kill_err" != "/dev/null" ] && rm -f "$kill_err"
	kill_ok=true
	if [ "$kill_rc" -ne 0 ]; then
		kill_ok=false
		if [ -n "$kill_stderr" ]; then
			echo "cleanup-orphan-poll-shells: WARN: kill -9 $pid failed (rc=$kill_rc, age=${age_s}s): $kill_stderr" >&2
		else
			echo "cleanup-orphan-poll-shells: WARN: kill -9 $pid failed (rc=$kill_rc, age=${age_s}s)" >&2
		fi
	fi
	cmd_prefix=$(printf '%s' "$cmd" | head -c 200)
	jq_err=$(mktemp -t orphan-cleanup-jq-err.XXXXXX 2>/dev/null) || jq_err="/dev/null"
	jq_rc=0
	jq -nc \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson pid "$pid" \
		--argjson age_s "$age_s" \
		--arg cmd_prefix "$cmd_prefix" \
		--argjson kill_ok "$kill_ok" \
		--argjson kill_rc "$kill_rc" \
		'{ts:$ts, pid:$pid, age_s:$age_s, cmd_prefix:$cmd_prefix, kill_ok:$kill_ok, kill_rc:$kill_rc}' \
		>>"$LOG_FILE" 2>"$jq_err" || jq_rc=$?
	if [ "$jq_rc" -ne 0 ]; then
		if [ "$jq_err" != "/dev/null" ] && [ -s "$jq_err" ]; then
			echo "cleanup-orphan-poll-shells: WARN: audit log write failed (rc=$jq_rc): $(head -c 200 "$jq_err")" >&2
		else
			echo "cleanup-orphan-poll-shells: WARN: audit log write failed (rc=$jq_rc)" >&2
		fi
	fi
	[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
	[ "$kill_ok" = "true" ] && killed=$((killed + 1))
done <<<"$filtered"

if [ "$killed" -gt 0 ]; then
	echo "cleanup-orphan-poll-shells: killed $killed orphan poll shell(s) older than ${MIN_AGE_S}s — see $LOG_FILE" >&2
fi

exit 0
