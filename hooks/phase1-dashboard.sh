#!/bin/bash
# v4.15.N #498 — pre-designed Phase 1 dashboards, emitted at round-
# complete + convergence boundaries. Called by review-log.sh's F
# block. Avoids ad-hoc "how should I format this round" decisions.
set -euo pipefail

# Usage:
#   phase1-dashboard.sh round-complete <log> <round>
#   phase1-dashboard.sh convergence <log>
#
# Writes the pretty markdown table to stdout (consumed by review-log.sh
# which prints it to stderr as part of the round-complete directive).

MODE="${1:-}"
LOG="${2:-}"
ROUND="${3:-}"

case "$MODE" in
-h | --help)
	grep '^#' "$0" | sed 's/^# \?//'
	exit 0
	;;
esac

if [ -z "$MODE" ] || [ -z "$LOG" ] || [ ! -f "$LOG" ]; then
	echo "Usage: $0 <round-complete|convergence> <log> [round]" >&2
	exit 2
fi

# shellcheck disable=SC2034  # REPO_ROOT may be referenced by sourced libs

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })
LIST_SCRIPT="$(dirname "$0")/list-phase1-agents.sh"
# v4.15.V: fail-closed on SSOT error. Prior `2>/dev/null || true` let dashboard
# render "all clean" tables when list-phase1-agents.sh was broken — hiding
# the gate fabrication vector.
if [ ! -x "$LIST_SCRIPT" ]; then
	echo "phase1-dashboard: $LIST_SCRIPT missing — cannot render" >&2
	exit 2
fi
if ! EXPECTED=$("$LIST_SCRIPT" main | sort -u); then
	echo "phase1-dashboard: list-phase1-agents.sh failed" >&2
	exit 2
fi
[ -z "$EXPECTED" ] && {
	echo "phase1-dashboard: SSOT returned no agents" >&2
	exit 2
}

# Round dashboard: per-agent findings for this round, +delta from prior.
render_round() {
	local round="$1"
	local prev=$((round - 1))
	echo "┌─ Phase 1 Round $round — Per-Agent Findings ─────────────────────────────┐"
	printf "│ %-24s │ %-8s │ %-7s │ %-10s │\n" "Agent" "Findings" "Status" "Δ vs R$prev"
	echo "├──────────────────────────┼──────────┼─────────┼────────────┤"
	local total=0 errored=0
	while IFS= read -r agent; do
		[ -z "$agent" ] && continue
		local cur prev_val delta status
		# v4.15.W: `.findings // 0` coerces null to 0 — prevents
		# arithmetic crashes on hand-edited/errored entries where
		# findings is unset. Mirrors the `(.findings // 0)` coercion
		# used in the tuple walk of phase1-before-cr.sh + pre-push-gate.
		cur=$(jq -r --arg r "$round" --arg a "$agent" \
			'select(.phase==1 and (.round|tostring)==$r and .agent==$a) | (.findings // 0)' \
			"$LOG" 2>/dev/null | head -1)
		status=$(jq -r --arg r "$round" --arg a "$agent" \
			'select(.phase==1 and (.round|tostring)==$r and .agent==$a) | .status' \
			"$LOG" 2>/dev/null | head -1)
		[ -z "$cur" ] && cur="-"
		[ -z "$status" ] && status="-"
		if [ "$prev" -gt 0 ]; then
			prev_val=$(jq -r --arg r "$prev" --arg a "$agent" \
				'select(.phase==1 and (.round|tostring)==$r and .agent==$a) | (.findings // 0)' \
				"$LOG" 2>/dev/null | head -1)
			# v4.15.GG: guard delta arithmetic with numeric-test on BOTH sides
			# (prior guard accepted cur="-"/non-numeric if prev_val was set).
			if [[ "$cur" =~ ^-?[0-9]+$ ]] && [[ "$prev_val" =~ ^-?[0-9]+$ ]]; then
				delta=$((cur - prev_val))
				if [ "$delta" -gt 0 ]; then delta="+$delta"; fi
			else
				delta="—"
			fi
		else
			delta="—"
		fi
		printf "│ %-24s │ %8s │ %-7s │ %10s │\n" "$agent" "$cur" "$status" "$delta"
		if [ "$cur" != "-" ] && [ "$status" = "ok" ]; then total=$((total + cur)); fi
		if [ "$status" = "errored" ]; then errored=$((errored + 1)); fi
	done <<<"$EXPECTED"
	echo "├──────────────────────────┼──────────┼─────────┼────────────┤"
	printf "│ %-24s │ %8d │ %-7s │            │\n" "TOTAL actionable" "$total" "err=$errored"
	echo "└──────────────────────────┴──────────┴─────────┴────────────┘"
}

# Convergence summary: multi-round progress + gate status.
render_convergence() {
	echo "┌─ Phase 1 Convergence Progress ───────────────────────────────────┐"
	printf "│ %-7s │ %-10s │ %-7s │ %-30s │\n" "Round" "Findings" "Errored" "Status"
	echo "├─────────┼────────────┼─────────┼────────────────────────────────┤"
	local rounds
	rounds=$(jq -r 'select(.phase==1 and .round!=null) | .round' "$LOG" 2>/dev/null | sort -un)
	for r in $rounds; do
		local tot err missing
		tot=$(jq -r --arg r "$r" 'select(.phase==1 and (.round|tostring)==$r) | .findings // 0' \
			"$LOG" 2>/dev/null | awk '{s+=$1} END {print s+0}')
		err=$(jq -r --arg r "$r" 'select(.phase==1 and (.round|tostring)==$r) | .status' \
			"$LOG" 2>/dev/null | awk '/errored/{c++} END{print c+0}')
		local logged
		logged=$(jq -r --arg r "$r" 'select(.phase==1 and (.round|tostring)==$r) | .agent' \
			"$LOG" 2>/dev/null | sort -u)
		if [ -n "$EXPECTED" ]; then
			missing=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$logged") | tr '\n' ',' | sed 's/,$//')
		else
			missing=""
		fi
		local verdict
		if [ -n "$missing" ]; then
			verdict="INCOMPLETE (missing: $missing)"
		elif [ "$tot" -eq 0 ] && [ "$err" -eq 0 ]; then
			verdict="CLEAN"
		else
			verdict="DIRTY"
		fi
		printf "│ %-7s │ %10d │ %7d │ %-30s │\n" "$r" "$tot" "$err" "${verdict:0:30}"
	done
	echo "└─────────┴────────────┴─────────┴────────────────────────────────┘"
}

case "$MODE" in
round-complete)
	[ -z "$ROUND" ] && {
		echo "round-complete requires <round> arg" >&2
		exit 2
	}
	render_round "$ROUND"
	echo ""
	render_convergence
	;;
convergence)
	render_convergence
	;;
*)
	echo "Unknown mode: $MODE" >&2
	exit 2
	;;
esac
