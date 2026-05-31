#!/bin/bash
set -euo pipefail
# auto-register: false
# v0.30.F (#193) — Phase 1 subagent agentId registry + SendMessage-resume directive.
#
# WHY: today every Phase 1 round fires fresh `Agent` calls. Each subagent
# starts with zero context — re-Reads the same diff files round after round.
# When CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 is set, the spawn result of
# an Agent call carries an `agentId` that SendMessage can resume — the
# subagent's prior file Reads + understanding stay in its context, only
# the delta-diff is new input. Real token savings on long Phase 1 loops.
#
# This helper is the registry + decision point. The launcher delegates
# the per-agent directive line to `directive` here so the resume vs
# fresh-spawn logic is unit-testable in isolation (no git fixture needed).
#
# State dir (gitignored): .claude/.session-state/phase1-agent-ids/<agent>.json
#   { "agent": "code-reviewer", "agentId": "a8725...",
#     "sha": "<sha at first record>", "last_sha": "<sha of last review>",
#     "resume_count": 0, "first_recorded": 1748700000 }
#
# Staleness: in-process teammates do NOT survive a session per Claude Code
# docs ("No session resumption with in-process teammates: /resume and /rewind
# do not restore in-process teammates"). The companion hook
# phase1-agent-ids-session-clear.sh wipes this dir at SessionStart, so any
# record present in `directive` is necessarily from the current session.
# No fragile session-marker comparison needed.
#
# Resume cap: PHASE1_RESUME_CAP (default 3). After N consecutive resumes,
# `directive` returns empty → launcher falls back to fresh Agent. Bounds
# subagent context growth (#193 caveat: monotonic context could overflow).
#
# Flag-off behavior: when CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1, the
# `directive` subcommand ALWAYS returns empty → launcher falls through to
# its existing fresh-Agent line. Byte-identical to today.
#
# Usage:
#   phase1-agent-id.sh record <agent> <agentId> <sha>
#   phase1-agent-id.sh get <agent>                      # → agentId or empty
#   phase1-agent-id.sh directive <agent> <round> <base_ref> <head_sha>
#                                                       # → SendMessage line OR empty (READ-ONLY)
#   phase1-agent-id.sh resumed <agent> <head_sha>       # commit a resume event (bump+advance)
#   phase1-agent-id.sh clear [<agent>]                  # remove one or all
#   phase1-agent-id.sh list                             # debug dump
#
# Exit codes:
#   0 — success
#   2 — invalid arguments / validation failed
#   3 — state I/O error (mkdir/write failed — disk full, perms)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$REPO_ROOT/.claude/.session-state/phase1-agent-ids"

# v0.30.F #193: cap is the maximum NUMBER OF RESUMES (post-fresh) per agent.
# Default 3 → fresh spawn + 3 resumes = 4 reviews of that agent across rounds
# before forcing a fresh re-spawn to bound subagent context growth.
PHASE1_RESUME_CAP="${PHASE1_RESUME_CAP:-3}"

_usage() {
	cat <<'EOF' >&2
Usage: phase1-agent-id.sh <subcommand> [args]
  record <agent> <agentId> <sha>              record agentId after a fresh Agent spawn
  get <agent>                                 echo last recorded agentId (or empty)
  directive <agent> <round> <base> <head>     echo SendMessage line OR empty (READ-ONLY; = fall through)
  resumed <agent> <head>                      commit a resume event (bump resume_count + advance last_sha)
  clear [<agent>]                             remove one agent's record, or all
  list                                        debug — list all records
Env:
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1      required for `directive` to ever emit non-empty
  PHASE1_RESUME_CAP=3                         max consecutive resumes per agent
EOF
}

# Validate an agent name. Restricts to the character class used by
# pr-review-toolkit subagent_types (lowercase + digits + hyphen). Refuses
# anything that would let a caller path-traverse out of STATE_DIR or inject
# shell metacharacters into the SendMessage line that the launcher emits.
_valid_agent() {
	[[ $1 =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]
}

# Validate an agentId from an Agent spawn result. Per the live probe the
# format is `a<hex>` (e.g. a872508899e04c95a — 17 chars). Accept the broader
# `^[A-Za-z0-9_-]+$` shape so a future format change doesn't break us, but
# require at least 8 chars + the leading `a` so a stray empty / short value
# can't slip through. Same role as the agent-name validator: this string
# gets interpolated into the SendMessage directive line.
_valid_agent_id() {
	[[ $1 =~ ^a[A-Za-z0-9_-]{7,63}$ ]]
}

_valid_sha() {
	[[ $1 =~ ^[0-9a-f]{6,40}$ ]]
}

_record_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }

_ensure_state_dir() {
	if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
		echo "phase1-agent-id: ERROR: mkdir $STATE_DIR failed (disk? perms?)" >&2
		exit 3
	fi
}

cmd_record() {
	local agent=${1:-} agent_id=${2:-} sha=${3:-}
	_valid_agent "$agent" || {
		echo "phase1-agent-id: ERROR: invalid agent name '$agent' (must match [a-z0-9][a-z0-9-]*)" >&2
		exit 2
	}
	_valid_agent_id "$agent_id" || {
		echo "phase1-agent-id: ERROR: invalid agentId '$agent_id' (must match ^a[A-Za-z0-9_-]{7,63}$)" >&2
		exit 2
	}
	_valid_sha "$sha" || {
		echo "phase1-agent-id: ERROR: invalid sha '$sha'" >&2
		exit 2
	}
	_ensure_state_dir
	local rec
	rec=$(_record_file "$agent")
	local now
	now=$(date +%s)
	# Fresh-record contract: resume_count resets to 0. This is how the
	# launcher signals "the prior agentId expired or the cap forced a fresh
	# spawn — start the resume budget over".
	if ! printf '{"agent":"%s","agentId":"%s","sha":"%s","last_sha":"%s","resume_count":0,"first_recorded":%s}\n' \
		"$agent" "$agent_id" "$sha" "$sha" "$now" >"$rec.tmp"; then
		echo "phase1-agent-id: ERROR: write to $rec.tmp failed" >&2
		exit 3
	fi
	if ! mv -f "$rec.tmp" "$rec"; then
		echo "phase1-agent-id: ERROR: rename $rec.tmp → $rec failed" >&2
		exit 3
	fi
}

cmd_get() {
	local agent=${1:-}
	_valid_agent "$agent" || {
		echo "phase1-agent-id: ERROR: invalid agent name '$agent'" >&2
		exit 2
	}
	local rec
	rec=$(_record_file "$agent")
	[ -f "$rec" ] || return 0
	# jq -e exits 1 on null/false — distinct from rc=0 with empty stdout
	# (file-missing). Here we already gated on -f, so missing key = corrupt.
	if ! jq -re '.agentId // empty' "$rec" 2>/dev/null; then
		# Corrupt or schema-drift record — surface, don't silently no-op.
		echo "phase1-agent-id: WARN: record $rec missing .agentId (corrupt?)" >&2
		return 0
	fi
}

# Emit the per-agent line the launcher prints in its `*)` case. Either the
# SendMessage resume directive OR empty (caller treats empty as "fall through
# to today's fresh-Agent line"). Empty means one of: flag off, round 1, no
# prior record, cap reached, prior sha == head sha (nothing new to review).
cmd_directive() {
	local agent=${1:-} round=${2:-} base=${3:-} head=${4:-}
	_valid_agent "$agent" || {
		echo "phase1-agent-id: ERROR: invalid agent name '$agent'" >&2
		exit 2
	}
	[[ $round =~ ^[1-9][0-9]*$ ]] || {
		echo "phase1-agent-id: ERROR: round must be a positive integer, got '$round'" >&2
		exit 2
	}
	# base/head are NOT path-traversal vectors here (only echoed into the
	# SendMessage line, never path-joined) but we still validate to keep the
	# output deterministic. base may be a ref name like 'main' OR an abbrev
	# sha; accept either shape.
	[[ $base =~ ^[A-Za-z0-9_./-]{1,128}$ ]] || {
		echo "phase1-agent-id: ERROR: invalid base ref '$base'" >&2
		exit 2
	}
	_valid_sha "$head" || {
		echo "phase1-agent-id: ERROR: invalid head sha '$head'" >&2
		exit 2
	}

	# Flag-off short-circuit — byte-identical to pre-#193 launcher.
	[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-0}" = "1" ] || return 0
	# Round 1 always fresh (baseline review).
	[ "$round" -gt 1 ] || return 0

	local rec
	rec=$(_record_file "$agent")
	[ -f "$rec" ] || return 0

	local agent_id last_sha resume_count
	agent_id=$(jq -re '.agentId // empty' "$rec" 2>/dev/null) || return 0
	last_sha=$(jq -re '.last_sha // .sha // empty' "$rec" 2>/dev/null) || return 0
	resume_count=$(jq -re '.resume_count // 0' "$rec" 2>/dev/null) || resume_count=0

	# Cap check: after PHASE1_RESUME_CAP resumes, force a fresh spawn to
	# bound subagent context growth (#193 caveat).
	if [ "$resume_count" -ge "$PHASE1_RESUME_CAP" ]; then
		return 0
	fi

	# Nothing changed since last review → resume would have no delta.
	# Empty here matches the launcher's existing "streak confirmation"
	# semantics — caller still emits the fresh-Agent line, which is the
	# correct round to re-confirm with a fresh read.
	if [ "$last_sha" = "$head" ]; then
		return 0
	fi

	# READ-ONLY: this subcommand only PRINTS the decision. State (resume_count
	# bump + last_sha advance) is committed separately by `resumed`, which the
	# main loop runs AFTER actually firing the SendMessage — mirroring the
	# "launcher prints, operator commits via review-log.sh" pattern. Keeping
	# `directive` pure means the launcher (and phase1-launch-completeness-gate,
	# which re-invokes it) can run any number of times per round without
	# inflating resume_count or prematurely tripping the cap. The displayed
	# "resume N/cap" is the upcoming resume number (resume_count + 1).
	printf 'SendMessage to=%s — Phase 1 R%s DELTA-review (resume %s/%s); on resume failure fall back to fresh Agent subagent_type=pr-review-toolkit:%s + clear via phase1-agent-id.sh clear %s\n' \
		"$agent_id" "$round" "$((resume_count + 1))" "$PHASE1_RESUME_CAP" "$agent" "$agent"
}

# Commit a resume EVENT: bump resume_count + advance last_sha to the just-
# reviewed head. The main loop calls this AFTER a successful SendMessage
# resume (alongside review-log.sh), NOT the launcher. Separating the commit
# from `directive` keeps the launcher's print idempotent.
cmd_resumed() {
	local agent=${1:-} head=${2:-}
	_valid_agent "$agent" || {
		echo "phase1-agent-id: ERROR: invalid agent name '$agent'" >&2
		exit 2
	}
	_valid_sha "$head" || {
		echo "phase1-agent-id: ERROR: invalid head sha '$head'" >&2
		exit 2
	}
	local rec
	rec=$(_record_file "$agent")
	# No record → nothing to advance. Not an error: a `resumed` with no prior
	# `record` just means the caller never recorded a fresh spawn; the next
	# `directive` will return empty (no record) and the launcher spawns fresh.
	[ -f "$rec" ] || {
		echo "phase1-agent-id: WARN: resumed '$agent' but no record exists (skipped)" >&2
		return 0
	}
	local now
	now=$(date +%s)
	if ! jq --arg head "$head" --arg now "$now" '
		.last_sha = $head
		| .resume_count = (.resume_count // 0) + 1
		| .last_resumed = ($now | tonumber)
	' "$rec" >"$rec.tmp" 2>/dev/null; then
		echo "phase1-agent-id: ERROR: jq update of $rec failed" >&2
		rm -f "$rec.tmp"
		exit 3
	fi
	if ! mv -f "$rec.tmp" "$rec"; then
		echo "phase1-agent-id: ERROR: rename $rec.tmp → $rec failed" >&2
		exit 3
	fi
}

cmd_clear() {
	local agent=${1:-}
	if [ -z "$agent" ]; then
		# Clear all — used by session-start hook + by operator to force
		# fresh next round.
		[ -d "$STATE_DIR" ] || return 0
		# Refuse a clearly-wrong STATE_DIR. Defensive — should never trigger
		# since STATE_DIR is built from `git rev-parse --show-toplevel`, but
		# `rm -rf $STATE_DIR` deserves a guard regardless.
		case "$STATE_DIR" in
		*/.claude/.session-state/phase1-agent-ids) ;;
		*)
			echo "phase1-agent-id: ERROR: refusing to clear unexpected STATE_DIR=$STATE_DIR" >&2
			exit 3
			;;
		esac
		rm -rf "$STATE_DIR"
		return 0
	fi
	_valid_agent "$agent" || {
		echo "phase1-agent-id: ERROR: invalid agent name '$agent'" >&2
		exit 2
	}
	rm -f "$(_record_file "$agent")"
}

cmd_list() {
	[ -d "$STATE_DIR" ] || return 0
	local f
	for f in "$STATE_DIR"/*.json; do
		[ -f "$f" ] || continue
		# Compact per-record summary, one line — operator-readable.
		jq -rc '"\(.agent) agentId=\(.agentId) resume=\(.resume_count // 0)/\(env.PHASE1_RESUME_CAP // "3") last_sha=\(.last_sha[0:8] // .sha[0:8])"' "$f" 2>/dev/null ||
			echo "(corrupt record: $f)"
	done
}

sub=${1:-}
shift || true
case "$sub" in
record) cmd_record "$@" ;;
get) cmd_get "$@" ;;
directive) cmd_directive "$@" ;;
resumed) cmd_resumed "$@" ;;
clear) cmd_clear "$@" ;;
list) cmd_list "$@" ;;
-h | --help | "")
	_usage
	exit 2
	;;
*)
	echo "phase1-agent-id: ERROR: unknown subcommand '$sub'" >&2
	_usage
	exit 2
	;;
esac
