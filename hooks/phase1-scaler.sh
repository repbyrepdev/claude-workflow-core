#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.24-R (#605) — smart scaler for Phase 1 Claude round count.
#
# Reads upstream phase signals (Phase 0.5 prefilter findings — copilot/
# codex/gemini — + CR CLI findings) + diff sensitivity + optional
# override, emits a ROUNDS=<N> decision on stdout.
#
# Tier table:
#   Phase 0.5 + CR both clean (pre-filter RAN)  → 1 round (streak confirmation)
#   Zero findings but pre-filter never ran      → 2 rounds (no-prefilter-signal)
#   Either has <3 findings total                → 2 rounds (minimal)
#   3-10 findings total                         → 3 rounds
#   11+ findings total                          → 5 rounds
# Sensitive-path floor: compose/crypto/auth touched → min 2 rounds.
# Override: PHASE1_ROUNDS=<N> env var wins always.
#
# Usage:
#   .claude/hooks/phase1-scaler.sh [--base main] [--explain]
# Output (stdout): integer (no trailing newline) OR "ROUNDS=<N>\nREASON=..."
# when --explain is set.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT" || exit 2

BASE="main"
EXPLAIN=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		[ "$#" -ge 2 ] || {
			echo "phase1-scaler: --base requires value" >&2
			exit 2
		}
		BASE="$2"
		shift 2
		;;
	--explain)
		EXPLAIN=1
		shift
		;;
	-h | --help)
		sed -n '4,22p' "$0"
		exit 0
		;;
	*)
		echo "phase1-scaler: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# Override wins.
if [ -n "${PHASE1_ROUNDS:-}" ] && [[ $PHASE1_ROUNDS =~ ^[1-9][0-9]*$ ]]; then
	if [ "$EXPLAIN" = "1" ]; then
		echo "ROUNDS=$PHASE1_ROUNDS"
		echo "REASON=PHASE1_ROUNDS env override"
	else
		printf '%s' "$PHASE1_ROUNDS"
	fi
	exit 0
fi

# Count Phase 0.5 findings for the CURRENT HEAD. p05_ran distinguishes
# "pre-filter RAN and found N" from "pre-filter was SKIPPED" (#2259): a
# skipped-* status entry (e.g. skipped-no-copilot-helper) used to yield
# p05_count=0, indistinguishable from a clean run, letting the skip lower
# the Claude round count as if the pre-filter had vouched for the diff.
# Observed incident: a consumer-repo skip scaled a branch to 1 round; that
# single round then surfaced 20 findings.
#
# Scoped to HEAD (not the log's last-line sha): entries logged for an
# OLDER commit must not vouch for THIS one (stale-sha vouching). Every jq
# pipeline is rc-guarded — a corrupt/truncated log degrades to the
# no-prefilter-signal floor with a loud WARN instead of a silent set -e
# abort that masquerades as an arg error.
p05_count=0
p05_ran=0
p05_log="$REPO_ROOT/.claude/logs/phase0.5-run.jsonl"
if [ -f "$p05_log" ] && command -v jq >/dev/null 2>&1; then
	_scaler_sha=$(git rev-parse HEAD 2>/dev/null) || _scaler_sha=""
	if [ -n "$_scaler_sha" ]; then
		if ! p05_ran=$(jq -rs --arg s "$_scaler_sha" '[.[] | select(.sha==$s and .status=="ok")] | length' "$p05_log" 2>/dev/null); then
			echo "phase1-scaler: WARN — jq failed reading $p05_log (corrupt log?); treating as no pre-filter signal" >&2
			p05_ran=0
		fi
		[[ $p05_ran =~ ^[0-9]+$ ]] || p05_ran=0
		if [ "$p05_ran" -gt 0 ]; then
			# Latest run PER CLI, summed across CLIs (CR-in-CI #2524
			# Major): each prefilter (copilot/codex/gemini) appends its
			# own ok batch — one entry PER AGENT sharing one ts, copilot
			# rows carry no cli field (defaulted). A single global
			# max_by(.ts) took only the NEWEST batch, so a later
			# 0-finding CLI hid an earlier CLI's findings (under-scale);
			# per-cli latest still keeps a re-run of one CLI from
			# double-counting its earlier batch. Non-numeric findings
			# values are dropped defensively; the bash guard below
			# catches the rest. Fail CLOSED: a count we cannot read must
			# also clear the ran-signal, else corrupt data lands in the
			# 1-round all-clean tier (count=0 with p05_ran>0 reads as
			# vouched).
			_p05_pair=""
			if ! _p05_pair=$(jq -rs --arg s "$_scaler_sha" '[.[] | select(.sha==$s and .status=="ok")] | group_by(.cli // "copilot") | map(group_by(.ts) | max_by(.[0].ts) | map(.findings) | map(select(type=="number"))) | flatten | "\(add // 0) \(length)"' "$p05_log" 2>/dev/null); then
				echo "phase1-scaler: WARN — jq failed summing findings in $p05_log (corrupt log?); treating as no pre-filter signal" >&2
				_p05_pair="0 0"
			fi
			p05_count=${_p05_pair% *}
			_p05_valid=${_p05_pair#* }
			[[ $p05_count =~ ^[0-9]+$ ]] || {
				p05_count=0
				_p05_valid=0
			}
			[[ $_p05_valid =~ ^[0-9]+$ ]] || _p05_valid=0
			# CR r8 Major: an ok batch whose findings values are ALL
			# malformed (every one dropped by the type filter) must not
			# vouch — count=0 with the ran-signal intact reads as
			# all-clean. A sum built from ZERO numeric values clears the
			# signal; mixed batches still sum their readable values.
			if [ "$_p05_valid" -eq 0 ]; then
				echo "phase1-scaler: WARN — latest ok batch in $p05_log has no numeric findings values (malformed); treating as no pre-filter signal" >&2
				p05_count=0
				p05_ran=0
			fi
		fi
	fi
fi

# Count CR CLI findings (latest run). Fail CLOSED like the p05 pipelines:
# an unreadable/non-numeric CR log must not read as "clean" — force at
# least the minimal tier instead of silently vouching 0.
cr_count=0
cr_log="$REPO_ROOT/.claude/logs/cr-local-review.jsonl"
if [ -f "$cr_log" ] && command -v jq >/dev/null 2>&1; then
	# (#2523) Scope the lookup to THIS branch. The log is append-only and shared
	# across branches, so a bare `tail -1` can read a sibling branch's entry —
	# over-escalating the tier (wasteful) or, after log rotation, failing to
	# escalate a legitimate re-walk. A commit on an unmerged sibling branch is
	# NOT an ancestor of HEAD, so ancestry is the branch-scope test. Walk the
	# recent window forward and keep the LAST ancestor match (newest wins).
	_cr_rows=""
	# An entry with NO usable .sha cannot be branch-attributed. Emit it as "-"
	# and treat it as IN-SCOPE below: dropping it would lower cr_count, which
	# lowers the round cap — the UNSAFE direction (less review). Every entry the
	# current writer produces carries .sha; "-" covers legacy/rotated rows only.
	# `length > 0` matters: an EMPTY-STRING sha would emit a leading blank, and
	# `read -r _e_sha _e_find` strips leading whitespace — shifting the findings
	# count into _e_sha and silently DROPPING the row (CR silent-failure-hunter).
	if ! _cr_rows=$(jq -r '"\(if (.sha | type) == "string" and (.sha | length) > 0 then .sha else "-" end) \(.findings // 0)"' "$cr_log" 2>/dev/null | tail -50); then
		echo "phase1-scaler: WARN — jq failed reading $cr_log (corrupt log?); forcing minimal tier" >&2
		cr_count=1
	elif [ -s "$cr_log" ] && [ -z "$_cr_rows" ]; then
		# jq exited 0 but produced NOTHING from a NON-EMPTY log — the file is
		# unreadable/corrupt in a way that does not raise a jq error (binary
		# content, a truncated write). Fail CLOSED to the minimal tier rather
		# than vouching clean. A MISSING log is a different case entirely and is
		# handled by the `[ -f "$cr_log" ]` guard above, which correctly leaves
		# cr_count at 0 (a first run legitimately has no CR signal). (CR)
		echo "phase1-scaler: WARN — $cr_log is non-empty but yielded no readable rows (corrupt?); forcing minimal tier" >&2
		cr_count=1
	else
		# Tracked SEPARATELY (CR): sharing one accumulator let a later low
		# ancestor row overwrite a higher unattributable one downward — the very
		# lowering those rows are admitted to prevent. _cr_anc keeps the LATEST
		# numeric ancestor value (newest wins for this branch); _cr_unattr keeps
		# the MAX numeric unattributable value (it cannot be ordered). They are
		# combined below by taking the greater, so unattributable rows act as a
		# FLOOR on the tier and can never pull it down.
		_cr_anc=""
		_cr_unattr=""
		_cr_scoped=""
		_cr_any=0
		while read -r _e_sha _e_find; do
			[ -n "$_e_sha" ] || continue
			_cr_any=1
			_anc_rc=0
			[ "$_e_sha" = "-" ] || git -C "$REPO_ROOT" merge-base --is-ancestor "$_e_sha" HEAD 2>/dev/null || _anc_rc=$?
			# Validate ONCE, before either accumulator is touched: a non-numeric
			# findings value must not land in the tier input by any path.
			[[ $_e_find =~ ^[0-9]+$ ]] || continue
			if [ "$_e_sha" = "-" ] || [ "$_anc_rc" -ge 2 ]; then
				# Unattributable row: no .sha, or git could not decide (rc>=2 —
				# unknown/GC'd object, the normal state after a rebase or
				# force-push, both of which this workflow uses). rc=1 alone means
				# genuinely not on this branch. Such a row cannot be ordered
				# against branch rows, so take the MAX rather than overwrite:
				# admitting it must never LOWER cr_count, which is the entire
				# justification for admitting it (CR silent-failure-hunter).
				if [ -z "$_cr_unattr" ] || [ "$_e_find" -gt "$_cr_unattr" ]; then
					_cr_unattr=$_e_find
				fi
			elif [ "$_anc_rc" -eq 0 ]; then
				# Genuine ancestor — newest wins (forward walk, last assignment).
				_cr_anc=$_e_find
			fi
		done <<EOF
$_cr_rows
EOF
		# Combine: this branch's own latest count, FLOORED by the highest
		# unattributable count. Taking the greater is what makes admitting
		# unattributable rows strictly non-lowering.
		if [ -n "$_cr_anc" ] && [ -n "$_cr_unattr" ]; then
			if [ "$_cr_unattr" -gt "$_cr_anc" ]; then
				_cr_scoped=$_cr_unattr
			else
				_cr_scoped=$_cr_anc
			fi
		elif [ -n "$_cr_anc" ]; then
			_cr_scoped=$_cr_anc
		elif [ -n "$_cr_unattr" ]; then
			_cr_scoped=$_cr_unattr
		fi
		if [ -n "$_cr_scoped" ]; then
			cr_count=$_cr_scoped
		elif [ "$_cr_any" -eq 1 ] && [ -f "$REPO_ROOT/.claude/review-log/$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null).jsonl" ]; then
			# Entries exist but none belong to this branch's lineage. On a FRESH
			# branch that is simply correct (cr=0, no escalation) and must stay
			# silent — after a squash-merge no prior sha is an ancestor, so an
			# unconditional warning would fire on every new branch. Warn only
			# when this sha has ALREADY had phase-1 rounds (a review-log exists),
			# which is the re-walk case the entries should have covered: they
			# likely rotated out of the window (#2523).
			echo "phase1-scaler: WARN — $cr_log has entries but none on this branch's lineage, yet this sha already has phase-1 rounds; treating as no CR signal (cr=0). Prior CR entries for this branch may have rotated out of the retained window." >&2
		fi
		[[ $cr_count =~ ^[0-9]+$ ]] || cr_count=1
	fi
fi

total=$((p05_count + cr_count))

# Tier decision. The 1-round all-clean tier requires the pre-filter to have
# ACTUALLY RUN (#2259): with no pre-filter signal (skipped or never logged
# for THIS sha), zero findings proves nothing — floor at 2 rounds instead.
if [ "$total" -eq 0 ] && [ "$p05_ran" -eq 0 ]; then
	rounds=2
	tier="no-prefilter-signal"
elif [ "$total" -eq 0 ]; then
	rounds=1
	tier="all-clean"
elif [ "$total" -lt 3 ]; then
	rounds=2
	tier="minimal"
elif [ "$total" -le 10 ]; then
	rounds=3
	tier="moderate"
else
	rounds=5
	tier="high"
fi

# Sensitive-path floor — compose/crypto/auth edits force min 2 rounds.
sensitive=0
changed_files=$(git diff --name-only "${BASE}..HEAD" 2>/dev/null || echo "")
case "$changed_files" in
*"stacks/"*compose.yaml* | *"config/"*.enc* | *"authelia/"* | *"swag/"* | *".gitleaks"*)
	sensitive=1
	;;
esac
if [ "$sensitive" = "1" ] && [ "$rounds" -lt 2 ]; then
	rounds=2
	tier="${tier}+sensitive-floor"
fi

# PHASE1_MIN_ROUNDS (CLAUDE.md legacy env var) is also honored — if set,
# round count never drops below it. Defaults to 0 so the scaler tier
# decision is authoritative when the env var is unset.
min_rounds="${PHASE1_MIN_ROUNDS:-0}"
if [[ $min_rounds =~ ^[0-9]+$ ]] && [ "$rounds" -lt "$min_rounds" ]; then
	rounds="$min_rounds"
	tier="${tier}+min=$min_rounds"
fi

if [ "$EXPLAIN" = "1" ]; then
	echo "ROUNDS=$rounds"
	echo "REASON=tier=$tier phase0.5=$p05_count p05_ran=$p05_ran cr=$cr_count sensitive=$sensitive"
else
	printf '%s' "$rounds"
fi
