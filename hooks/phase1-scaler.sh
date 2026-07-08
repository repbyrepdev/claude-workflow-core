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
			# Latest RUN = the ok-entry group sharing the newest timestamp
			# (one prefilter run logs one entry PER AGENT, all with one
			# ts). SUM that group's findings: a single max_by(.ts) returned
			# only the last-logged agent's count — frequently 0 — which
			# could land a diff with real Phase 0.5 findings in the
			# 1-round all-clean tier. Non-numeric findings values are
			# dropped defensively; the bash guard below catches the rest.
			# Fail CLOSED: a count we cannot read must also clear the
			# ran-signal, else corrupt data lands in the 1-round
			# all-clean tier (count=0 with p05_ran>0 reads as vouched).
			if ! p05_count=$(jq -rs --arg s "$_scaler_sha" '[.[] | select(.sha==$s and .status=="ok")] | group_by(.ts) | max_by(.[0].ts) | map(.findings) | map(select(type=="number")) | add // 0' "$p05_log" 2>/dev/null); then
				echo "phase1-scaler: WARN — jq failed summing findings in $p05_log (corrupt log?); treating as no pre-filter signal" >&2
				p05_count=0
				p05_ran=0
			fi
			[[ $p05_count =~ ^[0-9]+$ ]] || {
				p05_count=0
				p05_ran=0
			}
		fi
	fi
fi

# Count CR CLI findings (latest run). Fail CLOSED like the p05 pipelines:
# an unreadable/non-numeric CR log must not read as "clean" — force at
# least the minimal tier instead of silently vouching 0.
cr_count=0
cr_log="$REPO_ROOT/.claude/logs/cr-local-review.jsonl"
if [ -f "$cr_log" ] && command -v jq >/dev/null 2>&1; then
	if ! cr_count=$(jq -r '.findings // 0' "$cr_log" 2>/dev/null | tail -1); then
		echo "phase1-scaler: WARN — jq failed reading $cr_log (corrupt log?); forcing minimal tier" >&2
		cr_count=1
	fi
	[[ $cr_count =~ ^[0-9]+$ ]] || cr_count=1
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
