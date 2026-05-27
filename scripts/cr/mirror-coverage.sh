#!/bin/bash
set -euo pipefail
# auto-register: false
# (Invoked by scripts/ship-pr-cycle.sh + standalone via the
#  mirror-report subcommand.)
#
# #131: mirror coverage telemetry helpers.
#
# Two responsibilities:
#  1. `log_mirror_event` — append a JSONL row when a local mirror runs
#     (called from ship-pr-cycle.sh push/pr-create phase wire-in).
#     Schema: {ts, sha, mirror, phase, local_fired, local_rc, refuse_on_fail}.
#  2. `mirror_report` — aggregate the JSONL log into a per-mirror summary
#     (fire counts, fail rates, latest event per mirror). Output is
#     plain-text by default; --json emits machine-readable.
#
# Gap detection (server-fired-but-no-local) is a v2 follow-up — needs
# post-merge GitHub workflow state inspection. v1 here emits the local
# side of the data so the operator can manually correlate today + the
# auto-detector can read the same JSONL later.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_FILE="${REPO_ROOT}/.claude/logs/ship-pr-mirror-coverage.jsonl"
MAP_FILE="${REPO_ROOT}/.github/ship-pr-cycle-mirror-map.yml"

_log() { echo "[mirror-coverage] $*" >&2; }

# Append one event to the mirror-coverage log. Fail-soft (best-effort);
# logging never blocks the orchestrator.
# Args: --mirror NAME --phase PHASE --rc N [--sha SHA] [--refuse-on-fail BOOL]
log_mirror_event() {
	local mirror="" phase="" rc="" sha="" refuse_on_fail=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--mirror)
			mirror=$2
			shift 2
			;;
		--phase)
			phase=$2
			shift 2
			;;
		--rc)
			rc=$2
			shift 2
			;;
		--sha)
			sha=$2
			shift 2
			;;
		--refuse-on-fail)
			refuse_on_fail=$2
			shift 2
			;;
		*)
			_log "WARN: unknown log_mirror_event arg: $1"
			shift
			;;
		esac
	done
	if [ -z "$mirror" ] || [ -z "$phase" ] || [ -z "$rc" ]; then
		_log "WARN: log_mirror_event requires --mirror, --phase, --rc (skipping)"
		return 0
	fi
	[ -z "$sha" ] && sha=$(git rev-parse HEAD 2>/dev/null || echo "")
	mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
	command -v jq >/dev/null 2>&1 || {
		_log "WARN: jq missing — skipping JSONL emit"
		return 0
	}
	jq -nc --arg ts "$(date -u +%FT%TZ)" \
		--arg sha "$sha" \
		--arg mirror "$mirror" \
		--arg phase "$phase" \
		--arg refuse "$refuse_on_fail" \
		--argjson rc "$rc" \
		'{ts:$ts, sha:$sha, mirror:$mirror, phase:$phase, local_fired:true,
		  local_rc:$rc, refuse_on_fail:(if $refuse=="true" then true elif $refuse=="false" then false else null end)}' \
		>>"$LOG_FILE" 2>/dev/null || true
}

# Aggregate the JSONL log into a per-mirror coverage summary.
# Args: [--json]
mirror_report() {
	local format=text
	if [ "${1:-}" = "--json" ]; then
		format=json
	fi
	if [ ! -f "$LOG_FILE" ]; then
		_log "no coverage events logged yet: $LOG_FILE missing"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_log "ERROR: jq required for mirror-report"
		return 1
	fi
	local declared_mirrors
	if [ -f "$MAP_FILE" ] && command -v yq >/dev/null 2>&1; then
		declared_mirrors=$(yq -r '.mirrors[].server_workflow' "$MAP_FILE" 2>/dev/null || echo "")
	else
		declared_mirrors=""
	fi
	# Per-mirror aggregate: count, fail-count, latest ts.
	local agg
	agg=$(jq -s '
		group_by(.mirror) | map({
			mirror: .[0].mirror,
			fires: length,
			fails: ([.[] | select(.local_rc != 0)] | length),
			latest_ts: ([.[].ts] | max),
			latest_sha: (sort_by(.ts) | last | .sha)
		})
	' "$LOG_FILE" 2>/dev/null || echo "[]")
	if [ "$format" = "json" ]; then
		printf '%s\n' "$agg"
		return 0
	fi
	# Text format — operator-readable table.
	echo "=== Mirror coverage report ==="
	echo "  Log:       $LOG_FILE"
	echo "  Manifest:  $MAP_FILE"
	echo
	echo "Mirror                              Fires  Fails  Latest"
	echo "----------------------------------- -----  -----  -----------------"
	printf '%s' "$agg" | jq -r '.[] | "\(.mirror) \(.fires) \(.fails) \(.latest_ts)"' |
		while IFS=' ' read -r mirror fires fails latest_ts; do
			printf '%-35s %5d  %5d  %s\n' "$mirror" "$fires" "$fails" "$latest_ts"
		done
	echo
	# Mirrors declared in the manifest but never observed firing.
	if [ -n "$declared_mirrors" ]; then
		local observed
		observed=$(printf '%s' "$agg" | jq -r '.[].mirror')
		local never=()
		while IFS= read -r m; do
			[ -z "$m" ] && continue
			echo "$observed" | grep -qx "$m" || never+=("$m")
		done <<<"$declared_mirrors"
		if [ "${#never[@]}" -gt 0 ]; then
			echo "Declared but never fired (potential gap or feature unused):"
			for m in "${never[@]}"; do echo "  - $m"; done
		else
			echo "All declared mirrors have at least one observed fire ✓"
		fi
	fi
}

# Standalone invocation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-report}" in
	report)
		shift 2>/dev/null || true
		mirror_report "$@"
		;;
	log)
		shift
		log_mirror_event "$@"
		;;
	*)
		echo "usage: $0 {report [--json] | log --mirror NAME --phase PHASE --rc N [...]}" >&2
		exit 2
		;;
	esac
fi
