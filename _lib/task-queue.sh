#!/bin/bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY. Sourcing scripts keep their own
# option discipline, and — learned the hard way in #2544 — a sourced function
# runs under the CALLER's options regardless of what this file sets. Every
# command substitution below therefore captures its own rc rather than
# assuming a bare `set -e` will not fire mid-pipeline.
#
# auto-register: false
# (#2554) SSOT for two questions the nudge hooks in #2555 both need answered:
#
#   WHAT IS OPEN?   the task list's items, and which one to do next
#   HOW STALE?      how many tool calls since the last status update
#
# Both are read from the SAME place by every consumer, for the reason
# _lib/cr-thread-state.sh exists: two hooks answering "is there open work"
# differently is a stall in one direction and a false nudge in the other, and
# the disagreement is silent.
#
# WHAT THIS FILE DOES NOT DO: decide whether to nudge. Detection lives here and
# is fail-OPEN — an unreadable transcript answers "no queue", never "stop the
# operator". Enforcement is the caller's, through hook-ack. Keeping the two
# apart is what lets a jq glitch cost nothing.

# --- tool names -----------------------------------------------------------
#
# TodoWrite is the legacy name; TaskCreate/TaskUpdate are current. Both shapes
# are matched because a transcript spans whatever the session used, and a
# consumer that recognised only one would report "no queue" on a real one —
# which reads exactly like an empty queue and suppresses every nudge.
TASK_QUEUE_TOOL_RE='^(TodoWrite|TaskCreate|TaskUpdate)$'

# jq fragment: normalise either tool's item array to {content,status}.
#
# TodoWrite carries `content`/`status`/`activeForm`. Task* carries the
# equivalent under different keys depending on version, so each is tried in
# turn and the first non-null wins. `status` defaults to "pending": an item
# with no status is OPEN work, and defaulting it to completed would silently
# retire it.
TASK_QUEUE_NORMALISE_JQ='
  [ .[]? | {
      content: ((.content // .description // .title // .prompt // "") | tostring),
      status:  ((.status // .state // "pending") | tostring | ascii_downcase),
      blocked: ((.blocked // false) == true)
    } ]'

# --- parse: from a transcript ---------------------------------------------
#
# Follows the `jq -s` slurp idiom from hooks/no-handoff-to-user.sh, but selects
# `tool_use` blocks rather than text. Slurp reads the file once; transcripts are
# session-scoped and bounded, so the memory cost is the same one that file
# already accepts.
#
# LAST matching call wins: the todo list is a running state, and an earlier
# call's items are superseded, not merged.
#
# Echoes a JSON array (possibly empty). rc 1 means "could not read", which the
# caller must treat as ABSENT and not as empty — see task_queue_classify.
task_queue_from_transcript() { # $1 = transcript path
	local transcript=${1:-}
	[ -n "$transcript" ] && [ -r "$transcript" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local out rc=0
	out=$(jq -rs --arg re "$TASK_QUEUE_TOOL_RE" '
	    [ .[]
	      | .message.content[]?
	      | select(.type == "tool_use")
	      | select(.name | test($re))
	      | (.input.todos // .input.tasks // .input.items // [])
	    ] | last // []
	    | '"$TASK_QUEUE_NORMALISE_JQ" "$transcript" 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	[ -n "$out" ] || return 1
	printf '%s' "$out"
}

# --- parse: from a PostToolUse tool_input ---------------------------------
#
# Same normalisation, no transcript needed. A PostToolUse hook already has the
# item array in its payload, and re-reading the transcript to find what it was
# just handed would be slower and could disagree with it.
task_queue_from_tool_input() { # $1 = tool_input JSON object
	local input=${1:-}
	[ -n "$input" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local out rc=0
	out=$(printf '%s' "$input" | jq -c '
	    (.todos // .tasks // .items // [])
	    | '"$TASK_QUEUE_NORMALISE_JQ" 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	[ -n "$out" ] || return 1
	printf '%s' "$out"
}

# --- classify -------------------------------------------------------------
#
# THREE states, not two, for the same reason the CR thread classifier needs
# three: "no queue" and "empty queue" look identical to a boolean and mean
# opposite things to a nudge. Firing on a conversational turn — where no todo
# tool was ever used — is the failure mode the issue explicitly bounds against.
#
#   absent  — no todo tool seen at all. NEVER nudge.
#   empty   — items exist but none are open. Nothing to nudge about.
#   open    — at least one pending/in_progress item.
task_queue_classify() { # $1 = items JSON array (or empty/absent)
	local items=${1:-}
	if [ -z "$items" ]; then
		printf 'absent'
		return 0
	fi
	command -v jq >/dev/null 2>&1 || {
		printf 'absent'
		return 0
	}
	local n rc=0
	n=$(printf '%s' "$items" | jq -r '
	    [ .[]? | select(.status == "pending" or .status == "in_progress") ] | length' 2>/dev/null) || rc=$?
	if [ "$rc" -ne 0 ] || ! [[ $n =~ ^[0-9]+$ ]]; then
		# Unparseable is ABSENT, not empty: detection fails open, and the
		# caller must not nudge on data it could not read.
		printf 'absent'
		return 0
	fi
	if [ "$n" -gt 0 ]; then printf 'open'; else printf 'empty'; fi
}

# --- select the next actionable item --------------------------------------
#
# RESUME BEFORE START: an in_progress item is work already begun, and pointing
# the operator at a fresh pending item while something sits half-done is how a
# queue grows a tail of started-but-abandoned entries. Otherwise the first
# pending item in ARRAY ORDER — the order the operator wrote, which carries
# their intent about sequence and which nothing here is entitled to re-rank.
#
# `blocked` is skipped when the tool provides it. Nudging toward an item that
# cannot proceed is worse than silence: it trains the operator to dismiss.
#
# Echoes the item's content string, or nothing when there is no candidate.
task_queue_next_actionable() { # $1 = items JSON array
	local items=${1:-}
	[ -n "$items" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local out rc=0
	out=$(printf '%s' "$items" | jq -r '
	    [ .[]? | select(.blocked | not) ] as $avail
	    | ( [ $avail[] | select(.status == "in_progress") ] | first )
	      // ( [ $avail[] | select(.status == "pending") ] | first )
	      | .content // ""' 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	[ -n "$out" ] && [ "$out" != "null" ] || return 1
	printf '%s' "$out"
}

# --- session state --------------------------------------------------------
#
# ONE injectable override, TASK_QUEUE_STATE_DIR, and deliberately NO bats
# variable detection.
#
# The plan called for the `BATS_TEST_NAME` + `BATS_RUN_TMPDIR` short-circuit
# that _lib/hook-ack.sh uses. #2544 showed why not: BATS_RUN_TMPDIR is
# per-RUN, so every test in a file shares one directory and the first to write
# state silently poisons the rest — and the branch was unnecessary anyway,
# because a fixture that `cd`s into its own scratch repo already has
# REPO_ROOT pointed there. The isolation exists before the special case is
# added to provide it, and the special case brings a bug of its own.
_task_queue_state_dir() {
	if [ -n "${TASK_QUEUE_STATE_DIR:-}" ]; then
		printf '%s' "$TASK_QUEUE_STATE_DIR"
		return 0
	fi
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null) || root=$PWD
	printf '%s/.claude/.session-state/task-queue' "$root"
}

# Session ids come from a hook payload, i.e. from outside. Slugged so one
# cannot escape the state directory, and suffixed with a checksum of the raw
# value because the slug is many-to-one — the exact collision that put two
# branches on one pin file in #2544.
_task_queue_session_slug() { # $1 = session id
	local raw=${1:-}
	[ -n "$raw" ] || return 1
	local slug sum
	slug=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9._-' '_')
	[ -n "$slug" ] || return 1
	sum=$(printf '%s' "$raw" | cksum | cut -d' ' -f1) || sum=""
	[ -n "$sum" ] && slug="${slug}-${sum}"
	printf '%s' "$slug"
}

task_queue_state_path() { # $1 = session id
	local slug dir
	slug=$(_task_queue_session_slug "${1:-}") || return 1
	dir=$(_task_queue_state_dir)
	printf '%s/%s.json' "$dir" "$slug"
}

# Echoes the state object, or `{}` when there is none. Never fails the caller:
# a missing or corrupt state file means "no history", which is the same thing
# a first call means, and both are safe.
task_queue_state_read() { # $1 = session id
	local path
	path=$(task_queue_state_path "${1:-}") || {
		printf '{}'
		return 0
	}
	[ -r "$path" ] || {
		printf '{}'
		return 0
	}
	command -v jq >/dev/null 2>&1 || {
		printf '{}'
		return 0
	}
	local out rc=0
	out=$(jq -c . "$path" 2>/dev/null) || rc=$?
	if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
		printf '{}'
		return 0
	fi
	printf '%s' "$out"
}

# $1 = session id, $2 = complete state JSON object.
#
# Built by jq, never printf: #2544 shipped a printf-templated JSON state file
# whose unescaped interpolation let a crafted value inject a second key that
# jq then resolved last-wins. Values here come from tool payloads, which is
# the same trust level.
#
# mktemp + mv, not a predictable name with a plain redirect — that shape
# follows a pre-planted symlink and truncates the target.
task_queue_state_write() { # $1 = session id, $2 = state JSON
	local sid=${1:-} state=${2:-}
	[ -n "$sid" ] && [ -n "$state" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	printf '%s' "$state" | jq -e . >/dev/null 2>&1 || return 1
	local path dir tmp
	path=$(task_queue_state_path "$sid") || return 1
	dir=$(dirname "$path")
	mkdir -p "$dir" 2>/dev/null || return 1
	# Prune on write so ended sessions do not accumulate. 7 days is well past
	# any live session; a wrongly-pruned file costs a reset counter, not a
	# wrong decision — and the glob matches only this tool's own shape, so a
	# relocated TASK_QUEUE_STATE_DIR holding something else is not harvested.
	local prune_err prune_rc=0
	prune_err=$(find "$dir" -maxdepth 1 -name '*-[0-9]*.json' -type f -mtime +7 -delete 2>&1 >/dev/null) || prune_rc=$?
	if [ "$prune_rc" -ne 0 ] || [ -n "$prune_err" ]; then
		echo "task-queue: WARN: could not prune stale session state in $dir (rc=$prune_rc${prune_err:+: $prune_err})" >&2
	fi
	tmp=$(mktemp "$dir/.tq.XXXXXX" 2>/dev/null) || return 1
	if printf '%s\n' "$state" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null; then
		return 0
	fi
	rm -f "$tmp" 2>/dev/null || true
	return 1
}

# Identifiers for the OPEN items, so a later call can tell "the same work is
# still sitting there" from "the list moved on". Content is hashed rather than
# stored: it is operator prose that can be long, and only equality matters.
task_queue_open_ids() { # $1 = items JSON array
	local items=${1:-}
	[ -n "$items" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local out rc=0
	out=$(printf '%s' "$items" | jq -r '
	    [ .[]? | select(.status == "pending" or .status == "in_progress") | .content ]
	    | sort | join("")' 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	printf '%s' "$out" | cksum | cut -d' ' -f1
}
