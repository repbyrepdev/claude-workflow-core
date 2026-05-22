#!/bin/bash
set -euo pipefail
# v4.24-R (#605) — smart scaler for Phase 1 Claude round count.
#
# Reads upstream phase signals (Phase 0.5 Copilot findings + CR CLI
# findings) + diff sensitivity + optional override, emits a ROUNDS=<N>
# decision on stdout.
#
# Tier table:
#   Phase 0.5 + CR both clean          → 1 round (streak confirmation)
#   Either has <3 findings total       → 2 rounds (minimal)
#   3-10 findings total                → 3 rounds
#   10+ findings total                 → 5 rounds (today's default)
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
		sed -n '4,20p' "$0"
		exit 0
		;;
	*)
		echo "phase1-scaler: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# Override wins.
if [ -n "${PHASE1_ROUNDS:-}" ] && [[ "$PHASE1_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
	if [ "$EXPLAIN" = "1" ]; then
		echo "ROUNDS=$PHASE1_ROUNDS"
		echo "REASON=PHASE1_ROUNDS env override"
	else
		printf '%s' "$PHASE1_ROUNDS"
	fi
	exit 0
fi

# Count Phase 0.5 findings (latest run only, not aggregated across reruns).
p05_count=0
p05_log="$REPO_ROOT/.claude/logs/phase0.5-run.jsonl"
if [ -f "$p05_log" ] && command -v jq >/dev/null 2>&1; then
	# Pull findings from the most recent entry for the current SHA.
	# Use slurp + max_by(.ts) to avoid double-counting reruns.
	latest_sha=$(jq -r '.sha' "$p05_log" 2>/dev/null | tail -1)
	if [ -n "$latest_sha" ]; then
		p05_count=$(jq -rs --arg s "$latest_sha" '[.[] | select(.sha==$s and .status=="ok")] | if length > 0 then max_by(.ts).findings else 0 end' "$p05_log" 2>/dev/null || echo 0)
	fi
fi

# Count CR CLI findings (latest run).
cr_count=0
cr_log="$REPO_ROOT/.claude/logs/cr-local-review.jsonl"
if [ -f "$cr_log" ] && command -v jq >/dev/null 2>&1; then
	cr_count=$(jq -r '.findings // 0' "$cr_log" 2>/dev/null | tail -1)
	[[ "$cr_count" =~ ^[0-9]+$ ]] || cr_count=0
fi

total=$((p05_count + cr_count))

# Tier decision.
if [ "$total" -eq 0 ]; then
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
if [[ "$min_rounds" =~ ^[0-9]+$ ]] && [ "$rounds" -lt "$min_rounds" ]; then
	rounds="$min_rounds"
	tier="${tier}+min=$min_rounds"
fi

if [ "$EXPLAIN" = "1" ]; then
	echo "ROUNDS=$rounds"
	echo "REASON=tier=$tier phase0.5=$p05_count cr=$cr_count sensitive=$sensitive"
else
	printf '%s' "$rounds"
fi
