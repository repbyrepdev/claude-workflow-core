#!/bin/bash
set -euo pipefail
# auto-register: false
# (Invoked by scripts/ship-pr-cycle.sh + standalone via the
#  mirror-report subcommand.)
#
# #131: mirror coverage telemetry helpers.
#
# Two responsibilities:
#  1. `log_mirror_event` — append a JSONL row when a local mirror runs.
#     Intended caller: ship-pr-cycle.sh push/pr-create phase wire-in,
#     tracked as follow-up under #124 (no in-repo caller yet; the helper
#     is exposed for the future orchestrator wire-in).
#     Schema: {ts, sha, mirror, phase, local_fired, local_rc, refuse_on_fail}.
#  2. `mirror_report` — aggregate the JSONL log into a per-mirror summary
#     (fire counts, fail rates, latest event per mirror). Output is
#     plain-text by default; --json emits machine-readable.
#
# Gap detection (server-fired-but-no-local) is deferred to a follow-up
# under #124 — needs post-merge GitHub workflow state inspection. v1
# here emits the local side of the data so the operator can manually
# correlate today + the auto-detector can read the same JSONL later.

# Compute paths inside each function so sourced consumers pick up
# their own repo root at call time (the load-time value would be wrong
# when sourced from a non-repo cwd / different worktree / inside a
# git hook).
_resolve_paths() {
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [ -z "$root" ]; then
		_log "WARN: not in a git working tree — telemetry disabled"
		return 1
	fi
	LOG_FILE="${root}/.claude/logs/ship-pr-mirror-coverage.jsonl"
	MAP_FILE="${root}/.github/ship-pr-cycle-mirror-map.yml"
	return 0
}

_log() { echo "[mirror-coverage] $*" >&2; }

# Append one event to the mirror-coverage log. Fail-soft (best-effort);
# logging never blocks the orchestrator.
# Args: --mirror NAME --phase PHASE --rc N [--sha SHA] [--refuse-on-fail BOOL]
log_mirror_event() {
	local mirror="" phase="" rc="" sha="" refuse_on_fail=""
	# Arity guard: under `set -u`, a bare `$2` read when only `$1` exists
	# aborts the script — breaking the fail-soft "logging never blocks the
	# orchestrator" contract. Guard each value-bearing flag.
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--mirror)
			[ "$#" -ge 2 ] || {
				_log "WARN: --mirror requires a value (skipping)"
				return 0
			}
			mirror=$2
			shift 2
			;;
		--phase)
			[ "$#" -ge 2 ] || {
				_log "WARN: --phase requires a value (skipping)"
				return 0
			}
			phase=$2
			shift 2
			;;
		--rc)
			[ "$#" -ge 2 ] || {
				_log "WARN: --rc requires a value (skipping)"
				return 0
			}
			rc=$2
			shift 2
			;;
		--sha)
			[ "$#" -ge 2 ] || {
				_log "WARN: --sha requires a value (skipping)"
				return 0
			}
			sha=$2
			shift 2
			;;
		--refuse-on-fail)
			[ "$#" -ge 2 ] || {
				_log "WARN: --refuse-on-fail requires a value (skipping)"
				return 0
			}
			refuse_on_fail=$2
			shift 2
			;;
		*)
			# Consume both flag + value when the unknown arg looks like
			# `--flag value`; otherwise just shift 1 (lone bare arg).
			# Single-shift on `--unknown VALUE` would leave VALUE as
			# next $1 and corrupt subsequent parsing.
			_log "WARN: unknown log_mirror_event arg: $1"
			if [ "$#" -ge 2 ] && [[ $1 == --* ]] && [[ $2 != -* ]]; then
				shift 2
			else
				shift
			fi
			;;
		esac
	done
	if [ -z "$mirror" ] || [ -z "$phase" ] || [ -z "$rc" ]; then
		_log "WARN: log_mirror_event requires --mirror, --phase, --rc (skipping)"
		return 0
	fi
	# `--rc` must be a parseable integer or jq aborts (we then drop the
	# row silently — operator never learns the wire-in bug). Validate
	# explicitly at parse-time.
	if ! [[ $rc =~ ^-?[0-9]+$ ]]; then
		_log "WARN: --rc must be an integer (got '$rc'); skipping"
		return 0
	fi
	# Use `if` form (not `[ -z "$sha" ] && cmd`) so the statement is
	# always 0-exit under set -e — the `&&` form aborts when LHS is
	# false (i.e. when --sha IS supplied) and breaks fail-soft.
	if [ -z "$sha" ]; then
		sha=$(git rev-parse HEAD 2>/dev/null || echo "")
	fi
	_resolve_paths || return 0
	mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || {
		_log "WARN: cannot create log dir $(dirname "$LOG_FILE") — telemetry skipped"
		return 0
	}
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
	_resolve_paths || return 1
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
	# Filter malformed JSONL lines BEFORE slurp. Read raw lines (-R) and
	# attempt fromjson? — parse errors yield `empty` and continue, so a
	# single truncated row no longer aborts jq mid-file. The previous
	# `jq -c 'select(...)' "$LOG_FILE"` form parsed the whole file and
	# bailed at the first bad line, causing the `|| echo []` fallback
	# to silently wipe the report (CR-caught silent-failure class).
	local total_rows valid_rows
	total_rows=$(wc -l <"$LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)
	valid_rows=$(jq -R -c 'fromjson? | select(type=="object" and has("mirror"))' "$LOG_FILE" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
	if [ "$total_rows" -gt 0 ] && [ "$valid_rows" -ne "$total_rows" ]; then
		_log "WARN: $((total_rows - valid_rows)) malformed JSONL row(s) in $LOG_FILE skipped"
	fi
	# Per-mirror aggregate: count, fail-count, latest ts. Stream valid
	# rows through jq -R fromjson? first, then slurp the cleaned set.
	local agg
	agg=$(jq -R -c 'fromjson? | select(type=="object" and has("mirror"))' "$LOG_FILE" 2>/dev/null |
		jq -s '
		group_by(.mirror) | map({
			mirror: .[0].mirror,
			fires: length,
			fails: ([.[] | select(.local_rc != 0)] | length),
			latest_ts: ([.[].ts] | max),
			latest_sha: (sort_by(.ts) | last | .sha)
		})
	' 2>/dev/null || echo "[]")
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
			# `-F` fixed-string (no regex) — mirror names like
			# `pr-lint.yml` contain regex metachars (the dot).
			echo "$observed" | grep -Fqx "$m" || never+=("$m")
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
