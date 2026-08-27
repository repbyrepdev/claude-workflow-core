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
# PINNED PER BRANCH (#2544): the tier is resolved ONCE per branch and held.
# The table above is a pure function of the current finding count, so
# recomputing it every call let the cap grow as the rounds found things —
# cap 3 became cap 5 because the round that hit 3/3 returned 13 findings. It
# only ever rose, cr_count being floored by ancestors. Both phases read this
# number, so the treadmill was never phase-2-specific. See the pin block for
# the full account. `--repin` re-resolves deliberately (audit-logged); floors
# still apply upward over a pin.
#
# Usage:
#   .claude/hooks/phase1-scaler.sh [--base main] [--explain] [--repin]
# Output (stdout): integer (no trailing newline) OR "ROUNDS=<N>\nREASON=..."
# when --explain is set.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT" || exit 2

BASE="main"
EXPLAIN=0
REPIN=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--repin)
		# Deliberately re-resolve a pinned branch. Audit-logged, same posture
		# as the other escapes — the pin exists to stop the cap drifting
		# upward on its own, not to stop an operator changing it on purpose.
		REPIN=1
		shift
		;;
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
		# Derived, not hardcoded. `sed -n '4,22p'` printed the header by
		# LINE NUMBER, so adding the pin paragraph pushed Usage/Output out of
		# range and --help silently stopped showing how to invoke the script.
		# Print the comment block from line 4 up to the first non-comment
		# line, which cannot drift as the header grows.
		awk 'NR>3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
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
	# `tail -50` runs BEFORE jq so a malformed record in the older history cannot
	# fail the parse of the whole file (the log is append-only and long-lived),
	# and jq only ever reads the recent window. `.findings` is emitted RAW — the
	# former `// 0` turned a MISSING/null field into a valid 0, vouching a clean
	# branch from a row that carried no count at all and defeating the
	# fail-closed path below. Absent now renders as "null", which the canonical-
	# decimal guard rejects, marking the row bad (CR).
	# The findings value is TYPE-CHECKED in jq, not just rendered: string
	# interpolation collapses the number 0 and the string "0" to the same text,
	# so a wrong-typed value would sail through the canonical-decimal guard below
	# as a valid 0 and vouch a clean branch. Anything that is not a JSON number
	# renders as an explicit sentinel the guard rejects (CR).
	if ! _cr_rows=$(tail -50 "$cr_log" 2>/dev/null | jq -r '"\(if (.sha | type) == "string" and (.sha | length) > 0 then .sha else "-" end) \(if (.findings | type) == "number" then .findings else "__invalid_findings__" end)"' 2>/dev/null); then
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
		_cr_bad=0
		while read -r _e_sha _e_find; do
			[ -n "$_e_sha" ] || continue
			_cr_any=1
			_anc_rc=0
			[ "$_e_sha" = "-" ] || git -C "$REPO_ROOT" merge-base --is-ancestor "$_e_sha" HEAD 2>/dev/null || _anc_rc=$?
			# Validate ONCE, before either accumulator is touched: a malformed
			# findings value must not land in the tier input by any path.
			# CANONICAL DECIMAL only — `^[0-9]+$` alone would admit "008", and
			# bash arithmetic reads a leading zero as OCTAL, so the later -gt
			# comparison aborts with "value too great for base" (CR). The length
			# bound keeps values inside the signed-64-bit range bash can compare.
			if ! [[ $_e_find =~ ^(0|[1-9][0-9]*)$ ]] || [ "${#_e_find}" -gt 18 ]; then
				# Remember that a row was REJECTED. Without this, a log whose
				# rows are ALL malformed leaves both accumulators empty and
				# cr_count vouching 0 — clean — from a log nothing could be read
				# from. Forced to the minimal tier below instead (CR).
				_cr_bad=1
				continue
			fi
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
			# A rejected row must FLOOR the tier even when another row produced a
			# usable value: an older clean ancestor yielding 0 would otherwise let
			# a malformed newer row vouch a clean branch, which is the same
			# fail-open in a different shape (CR).
			if [ "$_cr_bad" -eq 1 ] && [ "$cr_count" -eq 0 ]; then
				echo "phase1-scaler: WARN — $cr_log had a malformed row alongside a 0-finding one; flooring at the minimal tier rather than vouching clean" >&2
				cr_count=1
			fi
		elif [ "$_cr_bad" -eq 1 ]; then
			# Rows were present but NONE yielded a usable count. That is an
			# unreadable log, not a clean branch — fail CLOSED to the minimal
			# tier rather than vouching 0 findings (CR).
			echo "phase1-scaler: WARN — $cr_log rows had no usable findings values (malformed); forcing minimal tier" >&2
			cr_count=1
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

# --- PIN the tier for the branch (#2544) ----------------------------------
#
# THE CAP CHASED ITS OWN TAIL. Everything above is a pure function of the
# CURRENT finding count, recomputed on EVERY call. So the number that bounds
# how many review rounds a branch may spend grew as those rounds found things:
#
#   cap 3 (cr=10, moderate) → the round that hit 3/3 returned 13 findings
#   → next call: cr=13 → high → cap 5 → "3/3 ENFORCED" became "4/5"
#
# Observed live on branch fix/v0.34.184/2548-cr-thread-reply. And it only ever
# went up: cr_count is deliberately floored by ancestor rows and "must never
# LOWER" (see the _cr_anc combine above), so this is a ratchet. A branch whose
# rounds keep finding >= 11 things can never reach its own cap.
#
# Both phases read this one number — `_phase1_cap_gate` and the phase-2 cap
# both call this script — so the treadmill was never phase-2-specific.
#
# The SIZING RULE is sound: a messy diff deserves more review. The defect is
# WHEN it is evaluated. Resolving once per branch keeps the rule and makes the
# number reachable.
#
# Per BRANCH, not per SHA: a fix commit moves HEAD, and re-resolving there
# would reintroduce the treadmill one commit at a time. Same scoping decision
# `_phase2_branch_run_count` already makes (#2354).
#
# Floors are applied BELOW this block, so a pin can never hold the count under
# a sensitive-path or PHASE1_MIN_ROUNDS floor — the pin bounds growth, it does
# not grant permission to review less.
pinned=0
pin_ts=""
repinned=0
# ONE seam, and it is operator-facing rather than test-only: relocating pin
# state is a legitimate thing to want (a shared checkout, a read-only tree).
#
# No bats branch. Two earlier cuts had one, and both were wrong in a way worth
# recording: the first keyed on BATS_RUN_TMPDIR, which is per-RUN, so every
# test in a file shared one pin directory under one fixture branch name and
# the first test to resolve silently capped the next six — a pin leaking
# between tests being the same bug as a cap leaking between branches. The
# second keyed on BATS_TEST_TMPDIR, which is correct but put test-harness
# variables in the control flow of a production gate for no gain: PIN_DIR
# derives from REPO_ROOT, and a bats fixture that `cd`s into its own scratch
# repo ALREADY has REPO_ROOT pointed at that scratch repo. The isolation was
# there before the special case was.
PIN_DIR="${PHASE1_SCALER_PIN_DIR:-$REPO_ROOT/.claude/.session-state/phase1-scaler}"
branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch_name=""
# Slugged so a branch name with slashes cannot escape PIN_DIR.
branch_slug=$(printf '%s' "$branch_name" | tr -c 'A-Za-z0-9._-' '_')
# A detached HEAD or unreadable branch name yields an empty slug, and BOTH pin
# blocks below are then skipped — which silently restores the pre-#2544
# treadmill. Silent is the one thing this feature cannot be, so say it.
if [ -z "$branch_slug" ] || [ "$branch_name" = "HEAD" ]; then
	echo "phase1-scaler: WARN: no branch name (detached HEAD?) — the tier cannot be pinned, so the cap will be re-resolved on every call and can grow with the finding count (#2544)" >&2
	branch_slug=""
fi
# Same for a missing jq: the pin is JSON, so without it the cap is recomputed
# every call. The tier tables above degrade quietly by design; this must not.
if [ -n "$branch_slug" ] && ! command -v jq >/dev/null 2>&1; then
	echo "phase1-scaler: WARN: jq not found — the tier pin cannot be read or written, so the cap will be re-resolved on every call (#2544)" >&2
	branch_slug=""
fi
PIN_FILE="$PIN_DIR/${branch_slug}.json"

if [ "$REPIN" = "1" ] && [ -n "$branch_slug" ]; then
	# The audit row is written BEFORE the pin is dropped, and its failure is
	# LOUD. `--repin` is sold as audit-logged; a silent write failure makes
	# that sentence false exactly when someone is changing a cap on purpose.
	# Same posture as the symlink guard's bypass audit.
	_repin_log="$REPO_ROOT/.claude/logs/pipeline-skip.jsonl"
	if mkdir -p "$REPO_ROOT/.claude/logs" 2>/dev/null &&
		printf '{"ts":"%s","kind":"phase1-scaler-repin","branch":"%s","reason":"%s","new_rounds":%s}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch_slug" \
			"${PHASE1_REPIN_REASON:-unstated}" "$rounds" \
			>>"$_repin_log" 2>/dev/null; then
		:
	else
		echo "phase1-scaler: WARN: --repin audit row could NOT be written to $_repin_log; the re-pin still happened but is untracked" >&2
	fi
	rm -f "$PIN_FILE" 2>/dev/null ||
		echo "phase1-scaler: WARN: --repin could not remove the existing pin at $PIN_FILE; the re-resolved value may not take effect" >&2
	# Tracked SEPARATELY from `tier`. Appending "+repinned" to the tier string
	# meant the marker was persisted into the new pin file and every later read
	# reported `moderate+repinned` forever — a one-off event conflated with the
	# tier field, permanently.
	repinned=1
fi

if [ -n "$branch_slug" ] && [ -f "$PIN_FILE" ]; then
	_pin_rounds=$(jq -r '.rounds // empty' "$PIN_FILE" 2>/dev/null) || _pin_rounds=""
	_pin_tier=$(jq -r '.tier // empty' "$PIN_FILE" 2>/dev/null) || _pin_tier=""
	pin_ts=$(jq -r '.pinned_at // empty' "$PIN_FILE" 2>/dev/null) || pin_ts=""
	if [[ $_pin_rounds =~ ^[1-9][0-9]*$ ]]; then
		rounds="$_pin_rounds"
		# A distinguishable sentinel, not the bare word "unknown" — which
		# reads like a tier name in REASON output and could be mistaken for
		# one the table actually produces.
		tier="${_pin_tier:-<pin-tier-missing>}"
		pinned=1
	else
		# Corrupt or truncated pin: re-resolve rather than abort inside a hook,
		# and SAY so — a silently discarded pin looks identical to a first run.
		echo "phase1-scaler: WARN: pin file $PIN_FILE is unreadable or has no valid rounds; re-resolving from current signals" >&2
		rm -f "$PIN_FILE" 2>/dev/null || true
		pin_ts=""
	fi
fi

if [ "$pinned" = "0" ] && [ -n "$branch_slug" ]; then
	pin_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# Tracked explicitly rather than inferred from `[ -f "$PIN_FILE" ]`. The
	# existence test was WRONG when a stale pin from a prior run was already
	# there: a failed `mv` left the old file in place, the test passed, no
	# warning was printed, and the script went on serving a pin it had just
	# failed to update. That is the one outcome worse than not pinning.
	_pin_written=0
	if mkdir -p "$PIN_DIR" 2>/dev/null; then
		# Prune on write, so merged and deleted branches do not accumulate pins
		# forever. 30 days is well past any branch this cycle keeps open, and
		# a wrongly-pruned pin costs one re-resolve, not a wrong cap.
		# WARNs on failure like every other path in this block — a prune that
		# silently stops working just grows the directory forever.
		find "$PIN_DIR" -maxdepth 1 -name '*.json' -type f -mtime +30 -delete 2>/dev/null ||
			echo "phase1-scaler: WARN: could not prune stale pins in $PIN_DIR; old branch pins may accumulate" >&2
		_pin_tmp="$PIN_FILE.$$"
		if printf '{"rounds":%s,"tier":"%s","pinned_at":"%s","base":"%s","cr_at_pin":%s,"p05_at_pin":%s}\n' \
			"$rounds" "$tier" "$pin_ts" "$BASE" "$cr_count" "$p05_count" \
			>"$_pin_tmp" 2>/dev/null; then
			if mv -f "$_pin_tmp" "$PIN_FILE" 2>/dev/null; then
				_pin_written=1
			else
				rm -f "$_pin_tmp" 2>/dev/null || true
			fi
		else
			rm -f "$_pin_tmp" 2>/dev/null || true
		fi
	fi
	# An unwritable pin is not fatal: the tier just gets recomputed next call,
	# which is the old behaviour. Advisory, because the operator should know
	# the cap is not actually being held.
	if [ "$_pin_written" = "0" ]; then
		echo "phase1-scaler: WARN: could not write the tier pin to $PIN_FILE — the cap will be re-resolved on every call (the pre-#2544 treadmill)" >&2
		# A pin that could not be replaced must not be READ next call either:
		# it holds a number this run already decided was out of date.
		rm -f "$PIN_FILE" 2>/dev/null ||
			echo "phase1-scaler: WARN: a STALE pin remains at $PIN_FILE and could not be removed; the next call may read an out-of-date cap" >&2
	fi
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
	# `pinned` is reported so the operator can tell a held cap from a freshly
	# computed one — without it, a pin and a coincidentally-equal recompute
	# print identically, and the whole point is knowing the number is stable.
	# `repinned` is reported as its OWN field rather than appended to `tier`.
	# The first cut did `tier="${tier}+repinned"`, which then got persisted into
	# the new pin file — so every later read reported `moderate+repinned`
	# forever, conflating a one-off event with the tier field permanently.
	echo "REASON=tier=$tier phase0.5=$p05_count p05_ran=$p05_ran cr=$cr_count sensitive=$sensitive pinned=$pinned${pin_ts:+ pinned_at=$pin_ts}$([ "$repinned" = "1" ] && printf ' repinned=1')"
else
	printf '%s' "$rounds"
fi
