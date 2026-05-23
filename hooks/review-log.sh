#!/bin/bash
# auto-register: false
# v4.3.D (#360): append a line to `.claude/review-log/<sha>.jsonl` for
# the current HEAD, recording one Phase 1 / Phase 2 event from the local
# review pipeline. Used by v4.3.F's pre-push-pipeline-gate to verify the
# PR actually converged locally before allowing push.
set -euo pipefail

# Usage:
#   .claude/hooks/review-log.sh phase1 <round> <agent> <findings_count> <status>
#   .claude/hooks/review-log.sh phase2 <findings_count> <status>
#   .claude/hooks/review-log.sh accept-with-reason <reason>
#
# Examples:
#   .claude/hooks/review-log.sh phase1 1 code-reviewer 3 ok
#   .claude/hooks/review-log.sh phase1 2 silent-failure-hunter 0 ok
#   .claude/hooks/review-log.sh phase1 1 comment-analyzer 0 errored
#   .claude/hooks/review-log.sh phase2 0 clean
#   .claude/hooks/review-log.sh accept-with-reason "round-3: simplifier vs comment-analyzer disagreed on verbose comments; CLAUDE.md prefers explanatory"
#
# Status vocabulary:
#   ok       — agent ran successfully, findings_count is the real count
#   errored  — agent crashed / timed-out / unparseable; count is ignored
#   clean    — for Phase 2, equivalent to ok+0-findings

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })
LOG_DIR="$REPO_ROOT/.claude/review-log"
mkdir -p "$LOG_DIR"

SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
if [ -z "$SHA" ]; then
	# Fresh repo with no commits — log filename would be "unknown.jsonl"
	# and pre-push-pipeline-gate.sh would never find it by sha. Fail
	# loud instead of silently accumulating orphan logs.
	echo "ERROR: review-log.sh requires at least one commit on HEAD" >&2
	exit 2
fi
LOG="$LOG_DIR/${SHA}.jsonl"

ACTION="${1:-}"
if [ -z "$ACTION" ]; then
	echo "Usage: $0 <phase1|phase2|accept-with-reason> <args...>" >&2
	exit 2
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case "$ACTION" in
phase1)
	# v4.23-U (#589): strict 5-arg validation. Prior form defaulted missing
	# findings=0 + status=ok, letting `review-log.sh phase1 1 code-reviewer`
	# succeed silently — which would log a fake-clean round. All real callers
	# (phase1-launcher, session-start-report, phase1-post-agent-nudge) already
	# pass all 5; tightening is additive — rejects only invocations nothing
	# uses correctly.
	ROUND="${2:-}"
	AGENT="${3:-}"
	FINDINGS="${4:-}"
	STATUS="${5:-}"
	if [ -z "$ROUND" ] || [ -z "$AGENT" ] || [ -z "$FINDINGS" ] || [ -z "$STATUS" ]; then
		echo "Usage: $0 phase1 <round> <agent> <findings_count> <status>" >&2
		# Build Missing: list without a trailing space.
		missing=""
		for pair in "ROUND:round" "AGENT:agent" "FINDINGS:findings" "STATUS:status"; do
			var="${pair%%:*}"
			label="${pair##*:}"
			if [ -z "${!var}" ]; then
				missing="${missing:+$missing }$label"
			fi
		done
		echo "  All 4 args required. Missing: $missing" >&2
		exit 2
	fi
	# Findings must be a non-negative integer (jq would error on non-numeric
	# later anyway, but catch early with a clear message).
	if ! [[ $FINDINGS =~ ^[0-9]+$ ]]; then
		echo "ERROR: findings_count must be a non-negative integer (got: $FINDINGS)" >&2
		exit 2
	fi
	# Round must be a positive integer.
	if ! [[ $ROUND =~ ^[1-9][0-9]*$ ]]; then
		echo "ERROR: round must be a positive integer (got: $ROUND)" >&2
		exit 2
	fi
	# v4.15.B #490: validate agent name against list-phase1-agents.sh output.
	# Prevents fabricating a clean round by logging a single fake agent
	# entry. Fallback: if list-phase1-agents.sh is missing/errors, skip the
	# check (don't block legitimate logging during bootstrap).
	LIST_SCRIPT="$(dirname "$0")/list-phase1-agents.sh"
	if [ -x "$LIST_SCRIPT" ]; then
		# v4.15.U: fail-closed on SSOT errors. Prior fail-open swallowed
		# list-phase1-agents.sh errors, reopening the fabrication vector
		# that v4.15.B exists to close.
		# v4.28-W5 (#816): validate against the FULL agent list (--all),
		# not the diff-filtered subset. The not-applicable logging path
		# (added v4.28-W5 #772) logs filtered-OUT agents — which by
		# definition aren't in the filtered list — and `main` mode would
		# reject them. The fabrication-prevention contract still holds:
		# every name in --all output is a real configured agent in
		# review-config.yml.
		if ! expected=$("$LIST_SCRIPT" --all); then
			echo "ERROR: list-phase1-agents.sh --all failed — cannot validate agent name" >&2
			exit 2
		fi
		if [ -z "$expected" ]; then
			echo "ERROR: list-phase1-agents.sh returned empty — SSOT broken" >&2
			exit 2
		fi
		if ! echo "$expected" | grep -qx "$AGENT"; then
			echo "ERROR: unknown Phase 1 agent '$AGENT'. Expected one of:" >&2
			echo "$expected" | sed 's/^/  - /' >&2
			echo "(Source: $LIST_SCRIPT / .claude/review-config.yml)" >&2
			exit 2
		fi
	fi
	# v4.15.B #490: warn on duplicate agent within a round — a re-run after
	# a fix should use round+1, not append to the same round. Double-logging
	# same agent in same round skews the "expected ∩ actual" check elsewhere.
	if [ -f "$LOG" ] && jq -e --arg r "$ROUND" --arg a "$AGENT" \
		'select(.phase==1 and (.round|tostring)==$r and .agent==$a)' \
		"$LOG" >/dev/null 2>&1; then
		echo "WARN: $AGENT already logged for round $ROUND — consider next round" >&2
	fi
	# v4.23-G (#553): record diff_hash at log-write time so the launcher
	# can detect "this exact diff was already reviewed by this agent" and
	# skip re-running. Hash is sha256 of `git diff main..$SHA` content.
	# Helper defined inline to avoid sourcing complications in hook.
	DIFF_HASH=""
	if git -C "$REPO_ROOT" rev-parse --verify main >/dev/null 2>&1; then
		if command -v sha256sum >/dev/null 2>&1; then
			DIFF_HASH=$(git -C "$REPO_ROOT" diff "main..${SHA}" 2>/dev/null | sha256sum | awk '{print $1}')
		elif command -v shasum >/dev/null 2>&1; then
			DIFF_HASH=$(git -C "$REPO_ROOT" diff "main..${SHA}" 2>/dev/null | shasum -a 256 | awk '{print $1}')
		fi
	fi
	jq -nc \
		--arg ts "$TS" --arg sha "$SHA" \
		--argjson round "$ROUND" \
		--arg agent "$AGENT" \
		--argjson findings "$FINDINGS" \
		--arg status "$STATUS" \
		--arg diff_hash "$DIFF_HASH" \
		'{ts: $ts, sha: $sha, phase: 1, round: $round, agent: $agent, findings: $findings, status: $status, diff_hash: $diff_hash}' \
		>>"$LOG"
	# v4.28-W4 (#721) + r1 CR #1 fix: clear pending files so
	# phase1-log-pending-gate.sh stops blocking. Schema is now
	# `${AGENT}-${SHA}.txt` (round dropped — see nudge for rationale).
	# r1 SFH #6 fix: capture rm stderr on failure so the gate doesn't
	# silently keep blocking after a successful log.
	#
	# v4.29 #778-followup (FIX): clear ALL ${AGENT}-*.txt regardless of
	# SHA. The agent reviewed a working state; once we log THIS agent at
	# any SHA, every prior pending sentinel for the same agent is moot
	# (one agent has one in-flight review at a time). Previously we only
	# cleared the current-HEAD sentinel — when a commit landed between
	# agent-return and log-call (the normal "log findings + commit fix
	# in next round" flow), the old-SHA sentinels orphaned and blocked
	# every subsequent tool call until manual `rm`.
	PENDING_DIR="$REPO_ROOT/.claude/.session-state/phase1-log-pending"
	if [ -d "$PENDING_DIR" ]; then
		rm_err=$(mktemp)
		# Glob `${AGENT}-*` catches both schemas (with/without round)
		# AND every SHA — the "one agent, one in-flight" invariant
		# makes broader clearing safe + prevents orphan-sentinel
		# deadlocks.
		for f in "$PENDING_DIR/${AGENT}"-*.txt; do
			[ -f "$f" ] || continue
			if ! rm -f "$f" 2>>"$rm_err"; then
				echo "review-log: WARN: failed to clear pending file $f — gate may keep blocking" >&2
			fi
		done
		[ -s "$rm_err" ] && cat "$rm_err" >&2
		rm -f "$rm_err"
	fi
	# v4.28-W3-C (#671): also record per-file cache entries via the
	# unified content-hash cache when agent finished clean. The
	# launcher's cache_lookup uses these to skip re-invocation when
	# the file's blob-sha hasn't changed since this clean entry.
	# Only record on findings=0 + status=ok — partial successes or
	# errored runs aren't proof the file is clean.
	CACHE_LIB="$(dirname "$0")/../_lib/content-hash-cache.sh"
	LIST_FILES_SCRIPT="$(dirname "$0")/list-agent-files.sh"
	if [ "$FINDINGS" = "0" ] && [ "$STATUS" = "ok" ] &&
		[ -f "$CACHE_LIB" ] && [ -x "$LIST_FILES_SCRIPT" ]; then
		# shellcheck source=/dev/null
		source "$CACHE_LIB"
		# r2 sfh #2: prior `2>/dev/null` swallowed list-agent-files.sh's
		# explicit ERROR diagnostics (yq missing, base ref missing, agent
		# unknown, config corrupt). Empty result = no cache entries
		# recorded for the agent's clean run, and next launcher invocation
		# re-runs the agent indefinitely with no operator signal that
		# scoping is broken. Now: capture stderr to a temp + surface it
		# on non-zero rc.
		lf_err=$(mktemp)
		lf_rc=0
		agent_files=$("$LIST_FILES_SCRIPT" "$AGENT" main 2>"$lf_err") || lf_rc=$?
		if [ "$lf_rc" -ne 0 ]; then
			echo "review-log: WARN: list-agent-files.sh failed for $AGENT (rc=$lf_rc):" >&2
			cat "$lf_err" >&2
			agent_files=""
		fi
		rm -f "$lf_err"
		# r2 sfh #4: per-record cache_record swallow → tally + WARN.
		cr_diag=$(mktemp)
		cr_fail=0
		while IFS= read -r f; do
			[ -z "$f" ] && continue
			if ! cache_record "phase1-$AGENT" "$f" ok 2>>"$cr_diag"; then
				cr_fail=$((cr_fail + 1))
			fi
		done <<<"$agent_files"
		if [ "$cr_fail" -gt 0 ]; then
			echo "review-log: WARN: $cr_fail cache_record write(s) failed for $AGENT (see $cr_diag)" >&2
		else
			rm -f "$cr_diag"
		fi
	fi
	# v4.15.F: round-complete continuation nudge. If this log write brings
	# the round to full expected-agent-set, emit a next-step directive to
	# stderr so Claude doesn't stall after the last agent of the round
	# returns (observed 2026-04-20 pattern: agents complete, Claude stops
	# and waits for user prompt instead of applying fixes + launching
	# round N+1). The reminder is the hook that closes "6 of 7 returned"
	# or "all 7 returned" → "now what" loop.
	# v4.15.V: fail-closed on SSOT error in F-block. Prior `2>/dev/null`
	# let round-complete directive emit "CONVERGED" when SSOT was broken,
	# reopening the fabrication vector v4.15.U closed at log-write time.
	if [ -x "$LIST_SCRIPT" ]; then
		if EXPECTED=$("$LIST_SCRIPT" main | sort -u) && [ -n "$EXPECTED" ]; then
			LOGGED=$(jq -r --arg r "$ROUND" 'select(.phase==1 and (.round|tostring)==$r) | .agent' "$LOG" | sort -u)
			MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$LOGGED"))
			if [ -z "$MISSING" ]; then
				TOTAL_FIND=$(jq -r --arg r "$ROUND" 'select(.phase==1 and (.round|tostring)==$r and (.findings // null) != null) | .findings' "$LOG" | awk '{s+=$1} END {print s+0}')
				ANY_ERR=$(jq -r --arg r "$ROUND" 'select(.phase==1 and (.round|tostring)==$r) | .status' "$LOG" | awk '/errored/{c++} END{print c+0}')
				# v4.15.N #498: render pre-designed dashboard (per-agent
				# table + convergence progress) BEFORE the next-step
				# directive. Avoids ad-hoc status summaries.
				DASHBOARD_SCRIPT="$(dirname "$0")/phase1-dashboard.sh"
				if [ -x "$DASHBOARD_SCRIPT" ]; then
					"$DASHBOARD_SCRIPT" round-complete "$LOG" "$ROUND" >&2 || true
					echo "" >&2
				fi
				NEXT_ROUND=$((ROUND + 1))
				MIN_ROUNDS="${PHASE1_MIN_ROUNDS:-5}"
				echo "" >&2
				echo "=== Phase 1 Round $ROUND COMPLETE — all expected agents logged ===" >&2
				echo "  Total findings this round: $TOTAL_FIND  (errored: $ANY_ERR)" >&2
				if [ "$TOTAL_FIND" -gt 0 ] || [ "$ANY_ERR" -gt 0 ]; then
					echo "  → NEXT STEPS (do all three, in order — do NOT stop here):" >&2
					echo "    1. Apply ALL actionable findings to the source files NOW." >&2
					echo "    2. Re-commit the fixes (changes the HEAD sha — new review-log)." >&2
					echo "    3. Launch Round $NEXT_ROUND: ALL expected agents in ONE parallel Agent block" >&2
					echo "       scoped to the whole \`git diff main..HEAD\` — NOT just fixed files." >&2
					echo "       Helper: .claude/hooks/phase1-launcher.sh $NEXT_ROUND" >&2
				else
					# v4.29 #792: graduation — first clean Phase 1 round means
					# Phase 0.5/1 are done for this branch. Pre-push gate
					# consults the marker and skips the per-SHA Phase 1 walk;
					# further commits advance only through Phase 2 + Phase 3.
					# Marker written eagerly on first-clean (one-round-clean
					# policy per user directive 2026-05-11 #792); the legacy
					# streak check below is kept for telemetry.
					GRAD_LIB="$(dirname "$0")/../_lib/phase-graduation.sh"
					if [ -r "$GRAD_LIB" ]; then
						# shellcheck source=/dev/null
						. "$GRAD_LIB"
						# CR PR #793 MAJOR: fail-closed git rev-parse (was || echo "unknown").
						_branch=""
						if ! _branch=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>&1); then
							echo "  WARN: graduation branch resolution failed ($_branch) — marker NOT written" >&2
							_branch=""
						fi
						if [ -n "$_branch" ]; then
							# Surface graduation_mark errors (silent-failure-hunter
							# conf 9) — swallowing stderr hides cannot-create-dir,
							# missing-jq, write-failed cases.
							if graduation_mark "$_branch" "$SHA" "$ROUND"; then
								echo "  → GRADUATED. Phase 0.5/1 marker written for branch $_branch (sha ${SHA:0:8}, round $ROUND)." >&2
								echo "    Future commits on this branch skip Phase 0.5/1; only Phase 2 + Phase 3 re-run." >&2
							else
								_grad_rc=$?
								echo "  WARN: graduation_mark failed (rc=$_grad_rc) — marker NOT written; future commits will re-run Phase 0.5/1." >&2
							fi
						fi
					fi
					# Clean round. Check streak against convergence target —
					# v4.15.Y: aggregate across all branch commits, not just
					# current SHA's log. Rounds persist as (sha, round) tuples
					# so commits-between-rounds don't reset convergence.
					COLLECT="$(dirname "$0")/_phase1-collect-logs.sh"
					COMBINED=""
					if [ -x "$COLLECT" ]; then
						# v4.15.DD: don't swallow collector failure — emit NOT YET
						# CONVERGED + exit the F-block cleanly rather than
						# fabricating an "empty COMBINED" clean state.
						if ! COMBINED=$(cd "$REPO_ROOT" && "$COLLECT" main); then
							echo "review-log: collector failed — convergence undetermined, NOT emitting directive" >&2
							echo "" >&2
							exit 0
						fi
					fi
					TUPLES=$(printf '%s\n' "$COMBINED" | jq -r 'select(.phase==1 and .round!=null) | "\(.sha)|\(.round)"' | awk '!seen[$0]++')
					CLEAN_STREAK=0
					for tuple in $(printf '%s\n' "$TUPLES" | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'); do
						tsha="${tuple%%|*}"
						tround="${tuple##*|}"
						R_RE=$(printf '%s\n' "$COMBINED" | jq -c --arg s "$tsha" --arg r "$tround" 'select(.phase==1 and .sha==$s and (.round|tostring)==$r)')
						R_LOGGED=$(printf '%s\n' "$R_RE" | jq -r '.agent' | sort -u)
						R_MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$R_LOGGED"))
						if [ -n "$R_MISSING" ]; then break; fi
						RF=$(printf '%s\n' "$R_RE" | jq -r '(.findings // 0)' | awk '{s+=$1} END {print s+0}')
						R_ERR=$(printf '%s\n' "$R_RE" | jq -r '.status' | awk '/errored/{c++} END{print c+0}')
						if [ "$RF" = "0" ] && [ "$R_ERR" = "0" ]; then
							CLEAN_STREAK=$((CLEAN_STREAK + 1))
						else
							break
						fi
					done
					# v4.29 #792: default streak target = 1 (was 2). One clean
					# round on the current code IS convergence; the prior 2-streak
					# requirement was the engine of the PR #790 treadmill.
					STREAK_TARGET="${PHASE1_MIN_CLEAN_STREAK:-1}"
					ROUND_COUNT=0
					[ -n "$TUPLES" ] && ROUND_COUNT=$(printf '%s\n' "$TUPLES" | wc -l | tr -d ' ')
					echo "  → CLEAN ROUND. Streak: $CLEAN_STREAK / $STREAK_TARGET   Total rounds: $ROUND_COUNT / $MIN_ROUNDS" >&2
					if [ "$CLEAN_STREAK" -ge "$STREAK_TARGET" ] && [ "$ROUND_COUNT" -ge "$MIN_ROUNDS" ]; then
						echo "    → CONVERGED. Next step: run Phase 2 — coderabbit review --agent -t committed --base main" >&2
					else
						echo "    → NOT YET CONVERGED. Launch Round $NEXT_ROUND: ALL expected agents parallel, whole diff." >&2
						echo "       Helper: .claude/hooks/phase1-launcher.sh $NEXT_ROUND" >&2
					fi
				fi
				echo "" >&2
			fi
		fi
	fi
	;;
phase2)
	FINDINGS="${2:-0}"
	STATUS="${3:-clean}"
	jq -nc \
		--arg ts "$TS" --arg sha "$SHA" \
		--argjson findings "$FINDINGS" \
		--arg status "$STATUS" \
		'{ts: $ts, sha: $sha, phase: 2, findings: $findings, status: $status}' \
		>>"$LOG"
	;;
accept-with-reason)
	REASON="${2:-}"
	if [ -z "$REASON" ]; then
		echo "Usage: $0 accept-with-reason <reason>" >&2
		exit 2
	fi
	jq -nc \
		--arg ts "$TS" --arg sha "$SHA" \
		--arg reason "$REASON" \
		'{ts: $ts, sha: $sha, phase: 1, kind: "accept-with-reason", reason: $reason}' \
		>>"$LOG"
	;;
*)
	echo "Unknown action: $ACTION" >&2
	exit 2
	;;
esac
