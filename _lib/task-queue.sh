#!/bin/bash
set -u
# NB: `set -u` here is NOT private to this file. A `set` at the top level of a
# sourced script runs in the CALLER's shell and persists after the source
# returns — so this turns nounset on for every hook that sources it. Harmless
# today, because all three already set it themselves, but stated correctly
# because an earlier version of this line said the opposite ("sourcing scripts
# keep their own option discipline"), which is the sort of assertion the next
# author relies on.
#
# The related and separately-true fact, learned in #2544: a sourced FUNCTION
# runs under the caller's options regardless of what this file sets. So the
# command substitutions below that matter — every one whose command can
# realistically fail — capture their own rc rather than assuming a bare
# `set -e` will not fire mid-pipeline. (Not literally every one: a few `tr`
# and `dirname` calls are left bare, because a failure there is not a case
# worth branching on.)
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
	# `last` with NO default, and an explicit rc when there was no todo call at
	# all. `last // []` collapsed "no todo tool was ever used" into "the list
	# is empty" — so a conversational transcript returned [] and classified as
	# `empty`, not `absent`, and the documented three-state distinction was
	# two states wearing three names. The bound still held (both exit), but
	# the absent branch was unreachable in production and the tests asserting
	# it passed only because their assertion had been weakened.
	out=$(jq -cs --arg re "$TASK_QUEUE_TOOL_RE" '
	    [ .[]
	      | .message.content[]?
	      | select(.type == "tool_use")
	      | select(.name | test($re))
	      # `.input` is GUARDED to objects first. jq raises "Cannot index
	      # array/string with todos" on a scalar or array .input and aborts
	      # the whole slurp — so one malformed tool_use anywhere in a long
	      # transcript would take out the parse for every well-formed one
	      # before AND after it, and the caller would read that as "no queue".
	      # Detection is supposed to fail open per item, not per transcript.
	      #
	      # DROPPED, not mapped to []. The first cut of this guard emitted []
	      # for a malformed input, which then joined the candidate list — and
	      # `last` below picks the final candidate, so a valid TodoWrite
	      # followed by a malformed TaskUpdate classified as `empty` and
	      # suppressed the nudge with work still open. Failing open per item
	      # means the item leaves the list, not that it becomes an empty queue
	      # that outvotes the good ones.
	      | select((.input | type) == "object")
	      | (.input.todos // .input.tasks // .input.items // [])
	      | select(type == "array")
	    ] | if length == 0 then "__TQ_ABSENT__"
	        else (last | '"$TASK_QUEUE_NORMALISE_JQ"') end' "$transcript" 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	[ -n "$out" ] || return 1
	# rc 1 means ABSENT, which the caller must not treat as empty.
	[ "$out" = '"__TQ_ABSENT__"' ] && return 1
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
	# Derived from task_queue_open_count, so classify cannot disagree with the
	# selector about what "open" means. It had its own inline filter that
	# counted BLOCKED items — a third definition alongside the two already
	# reconciled, which is why the previous fix's claim of "one definition,
	# used by every consumer" was only two-thirds true.
	local n rc=0
	n=$(task_queue_open_count "$items") || rc=$?
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
	# wrong decision.
	#
	# The GLOB IS NOT THE OWNERSHIP TEST, and an earlier comment here claimed
	# it was. `*-[0-9]*.json` is the shape of `<slug>-<cksum>.json`, but it is
	# also the shape of `tsconfig-1.json`, `report-2023-final.json` and
	# `credentials-2.json` — and TASK_QUEUE_STATE_DIR is operator-relocatable,
	# so "the dir only ever holds our files" is an assumption about someone
	# else's directory. `-delete` on that assumption is the whole finding.
	#
	# So the glob only NARROWS the candidates and every one of them must then
	# prove it is ours by CONTENT: a JSON object carrying the two keys this
	# library writes. A file that fails the check is left alone, including a
	# file we cannot read or parse — unreadable is not the same as foreign,
	# and the safe response to both is identical.
	# prune_err MUST be initialised, not merely declared: it is appended to
	# below, and `local prune_err` leaves it UNSET, which is a hard error
	# under the `set -u` a caller may have in force.
	local prune_err="" prune_rc=0 _cand
	while IFS= read -r _cand; do
		[ -n "$_cand" ] || continue
		jq -e 'type == "object" and has("open_ids") and has("calls_since_update")' \
			<"$_cand" >/dev/null 2>&1 || continue
		prune_err="$prune_err$(rm -f "$_cand" 2>&1 >/dev/null)" || prune_rc=$?
	done < <(find "$dir" -maxdepth 1 -name '*-[0-9]*.json' -type f -mtime +7 2>/dev/null)
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
	# DELIMITED with a unit separator, not a bare concatenation. Joining
	# bare contents is ambiguous: ["ab","c"] and ["a","bc"] both render "abc",
	# so two genuinely different open sets hash identically and the reconcile
	# hook's "did the set move" test silently answers no. U+001F cannot appear
	# in task prose.
	out=$(printf '%s' "$items" | jq -r '
	    [ .[]? | select(.blocked | not)
	           | select(.status == "pending" or .status == "in_progress") | .content ]
	    | sort | join("\u001f")' 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	printf '%s' "$out" | cksum | cut -d' ' -f1
}

# THE definition of "how many items are open", so consumers do not each write
# their own. next-task-stop-nudge.sh counted with its own jq that included
# BLOCKED items while naming an unblocked one — announcing "3 open task(s)"
# and then pointing at the only reachable one. That is the two-definitions
# drift this file exists to prevent, in a consumer rather than in the library.
task_queue_open_count() { # $1 = items JSON array
	local items=${1:-}
	[ -n "$items" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	local out rc=0
	out=$(printf '%s' "$items" | jq -r '
	    [ .[]? | select(.blocked | not)
	           | select(.status == "pending" or .status == "in_progress") ] | length' 2>/dev/null) || rc=$?
	[ "$rc" -eq 0 ] || return 1
	[[ $out =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$out"
}

# ONE engine for tool-name matching. The regex was exported raw and fed to
# jq's test() by this library and to `grep -qE` by the tracking hook — one
# constant contracted to two engines, so a future pattern the two read
# differently would silently desynchronise the recorder from the parser.
# …and that is exactly what this function then did anyway. It carried its own
# `case TodoWrite | TaskCreate | TaskUpdate`, a SECOND copy of the list two
# hundred lines below TASK_QUEUE_TOOL_RE, under a comment claiming there was
# one. Adding a tool name to the regex — the obvious place — would have left
# this predicate answering no for it, so the parser would see the queue and
# the recorder would not. Now there is genuinely one list.
task_queue_is_task_tool() { # $1 = tool name
	[[ ${1:-} =~ $TASK_QUEUE_TOOL_RE ]]
}

# --- state accessors ------------------------------------------------------
#
# The reconcile hook read `.open_ids` and `.ids_at_last_commit` with its own
# ad hoc jq, which put the state SCHEMA in two files — exactly the drift this
# library exists to prevent, reintroduced one field at a time. Consumers go
# through these.
task_queue_state_open_ids() { # $1 = state JSON
	printf '%s' "${1:-}" | jq -r '.open_ids // ""' 2>/dev/null || return 1
}

task_queue_state_ids_at_last_commit() { # $1 = state JSON
	printf '%s' "${1:-}" | jq -r '.ids_at_last_commit // ""' 2>/dev/null || return 1
}

task_queue_state_set_ids_at_last_commit() { # $1 = state JSON, $2 = ids
	printf '%s' "${1:-}" | jq -c --arg ids "${2:-}" '.ids_at_last_commit = $ids' 2>/dev/null || return 1
}

# The remaining three fields. These were still being read with inline jq by
# the two hooks — `.items` in task-issue-reconcile.sh, `.calls_since_update`
# and `.nudged_for` in task-queue-track.sh — which is the same schema-in-two-
# files drift the comment above describes, just in the fields that had not
# been noticed yet. Every field of the state object now has exactly one
# reader.
task_queue_state_items() { # $1 = state JSON
	printf '%s' "${1:-}" | jq -c '.items // []' 2>/dev/null || return 1
}

task_queue_state_calls_since_update() { # $1 = state JSON
	printf '%s' "${1:-}" | jq -r '.calls_since_update // 0' 2>/dev/null || return 1
}

task_queue_state_nudged_for() { # $1 = state JSON
	printf '%s' "${1:-}" | jq -r '.nudged_for // ""' 2>/dev/null || return 1
}

# --- per-session lock -----------------------------------------------------
#
# THE RACE: matching PostToolUse hooks run in PARALLEL. task-queue-track.sh
# and task-issue-reconcile.sh both fire on the same `git commit` Bash call,
# both do read → modify → atomic-replace on the SAME state file, and they
# modify DIFFERENT fields — the tracker writes calls_since_update, the
# reconciler writes ids_at_last_commit. The `mv` is atomic, so the file is
# never torn; but the loser's read happened before the winner's write, so
# whichever lands second writes back a whole object built from stale data and
# silently drops the other's field. Losing ids_at_last_commit costs the
# reconciler a commit's baseline — the exact bookkeeping the hook exists for.
#
# mkdir is the atomicity primitive, same as _lib/hook-ack.sh (CR PR #790) and
# the same ~2s budget. It is duplicated in shape rather than sourced because
# this library must not depend on hook-ack — hook-ack is about the sentinel,
# this is about session state, and one is not a layer over the other.
#
# FAILS OPEN: if the lock cannot be taken, the caller proceeds unlocked. A
# reminder mechanism must not be able to wedge a tool call, and an unlocked
# write is what every write did before this existed.
# OWNERSHIP IS TRACKED, and the first cut of this did not track it.
#
# `_task_queue_lock` returns non-zero after the budget and the caller proceeds
# unlocked — but the caller also arms `trap … EXIT` unconditionally, so the
# hook that NEVER ACQUIRED the lock went on to rmdir the lockdir the other
# hook was still holding. The holder then finished its read-modify-write
# outside the critical section and the lost-field race came back, in exactly
# the contention window this layer was added for. A lock that is released by
# whoever loses the race is worse than no lock: it looks like protection.
#
# _TQ_LOCKS_HELD records the paths this process actually owns, and unlock is a
# no-op for anything not in it.
_TQ_LOCKS_HELD="${_TQ_LOCKS_HELD:-}"

# STALE RECLAIM. A hook killed mid-critical-section (or one that hit an exit
# path before the trap was armed) leaves the directory forever, and every
# later hook in that session then pays the full budget and warns about a
# process that is long gone. A lockdir older than twice the budget cannot
# belong to a live holder — nothing here holds it for more than a few jq
# calls — so it is reclaimed rather than waited on.
_task_queue_lock() { # $1 = lock dir path
	local lockdir=${1:-} tries=0 reclaimed=0
	[ -n "$lockdir" ] || return 1
	while ! mkdir "$lockdir" 2>/dev/null; do
		tries=$((tries + 1))
		# Halfway through the budget, check for a corpse exactly once.
		if [ "$tries" -eq 100 ] && [ "$reclaimed" -eq 0 ]; then
			reclaimed=1
			if [ -n "$(find "$lockdir" -maxdepth 0 -type d -mmin +1 2>/dev/null)" ]; then
				echo "task-queue: WARN: reclaiming a stale state lock older than 1m ($lockdir) — a hook was probably killed while holding it" >&2
				rmdir "$lockdir" 2>/dev/null || true
			fi
		fi
		if [ "$tries" -ge 200 ]; then
			echo "task-queue: WARN: state lock not acquired after 2s ($lockdir) — proceeding unlocked; a concurrent hook may overwrite a field" >&2
			return 1
		fi
		sleep 0.01
	done
	_TQ_LOCKS_HELD="$_TQ_LOCKS_HELD:$lockdir"
	return 0
}

_task_queue_unlock() { # $1 = lock dir path
	local lockdir=${1:-}
	[ -n "$lockdir" ] || return 0
	# ONLY if this process owns it. Releasing a lock we never took is the
	# defect described above.
	case ":$_TQ_LOCKS_HELD:" in
	*":$lockdir:"*) ;;
	*) return 0 ;;
	esac
	rmdir "$lockdir" 2>/dev/null || true
	_TQ_LOCKS_HELD=${_TQ_LOCKS_HELD//":$lockdir"/}
	return 0
}

# The public pair. Callers wrap their WHOLE read-modify-write span, not just
# the write: locking inside task_queue_state_write alone would leave the read
# outside the critical section, which is where the stale data comes from.
#
# Callers must release on EVERY exit path. Both hooks use `trap … EXIT` for
# this — they are short-lived scripts with no other EXIT trap — because they
# are full of `|| exit 0` fail-open branches, and one of those exiting while
# holding the lock would make every later hook pay the full 2s timeout and
# print a warning about a process that is long gone.
task_queue_state_lock() { # $1 = session id
	local path
	path=$(task_queue_state_path "${1:-}") || return 1
	mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
	_task_queue_lock "${path}.lockdir"
}

task_queue_state_unlock() { # $1 = session id
	local path
	path=$(task_queue_state_path "${1:-}") || return 0
	_task_queue_unlock "${path}.lockdir"
}

# --- shared text sanitiser ------------------------------------------------
#
# One definition, used by all three hooks. It was `tr '\n\r\t' '   ' | tr -cd
# '[:print:]'` copied into each of them, and the second half was wrong twice
# over:
#
#   1. `tr -cd '[:print:]'` operates on BYTES. Every UTF-8 continuation byte
#      is outside [:print:] in the C locale, so an em dash, an accented word,
#      or any non-Latin script was mangled or deleted outright. A task item
#      written in Japanese reduced to nothing, and the nudge then quoted an
#      empty string back at the operator.
#   2. It was three copies of a security-relevant filter in a cohort where
#      every other shared definition already lives in this file.
#
# The injection defence is the CONTROL-CHARACTER removal, not the non-ASCII
# removal: what let a task item forge lines in a force-read diagnostic was
# \n, \r and escape sequences, and those are exactly what this deletes.
# Printable text in any language is content, not an attack.
#
# Truncation is by CHARACTER, not byte. `cut -b` was the first cut and it
# reintroduced the very problem the control-only filter had just fixed: byte
# 160 can land inside a multibyte sequence, so the result ended in a partial
# character — invalid UTF-8, emitted into both the diagnostic and the
# systemMessage. awk with a UTF-8 locale counts characters, so the cut always
# falls on a boundary.
task_queue_sanitise_line() { # $1 = text, $2 = max characters (default 160)
	local max=${2:-160} flat
	flat=$(printf '%s' "${1:-}" |
		tr '\n\r\t' '   ' |
		LC_ALL=C tr -d '\000-\010\013\014\016-\037\177') || return 1
	# Bash substring expansion, NOT `cut -b` and not awk substr. `cut -b`
	# counts bytes and splits multibyte characters. macOS ships BWK awk, whose
	# substr is also byte-oriented regardless of locale — verified, it
	# produced the same broken suffix. Bash indexes by CHARACTER whenever the
	# locale is multibyte-aware, and costs no fork.
	#
	# FORCED, not inherited. This was `${LC_ALL:-en_US.UTF-8}`, which PRESERVES
	# a caller's `LC_ALL=C` — and under C, bash indexes bytes, so the
	# expansion below splits multibyte sequences exactly as `cut -b` did. The
	# fix carried its own bug in the defaulting operator.
	local out
	local LC_ALL=C.UTF-8 LANG=C.UTF-8
	out=${flat:0:max}

	# AND THEN VERIFY, because forcing a locale is not the same as having it.
	# C.UTF-8 is absent on older macOS and bash silently falls back to byte
	# indexing when the requested locale does not exist — so the line above is
	# a preference, not a guarantee. Dropping trailing bytes until the result
	# is valid UTF-8 needs no locale at all and converges in at most three
	# steps, that being the longest incomplete prefix of a UTF-8 sequence.
	if [ -n "$out" ] && command -v iconv >/dev/null 2>&1; then
		local guard=0
		while [ -n "$out" ] && [ "$guard" -lt 3 ] &&
			! printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; do
			out=${out%?}
			guard=$((guard + 1))
		done
	fi
	printf '%s' "$out"
}

# --- superseded diagnostic cleanup ----------------------------------------
#
# hook_ack_append DEDUPES sentinel rows by (hook, reason) — a second nudge
# from the same hook for the same reason replaces the row rather than adding
# one. hook_ack_diagnostic_write, by contrast, mints a UNIQUE filename every
# call (timestamp + random suffix, added so rapid calls cannot clobber each
# other). So the row always points at the newest file and every earlier one is
# orphaned in .claude/.session-state/hook-ack/<hook>/ forever.
#
# ORDER MATTERS AND IS THE WHOLE SAFETY ARGUMENT: this must be called only
# AFTER a successful append, never before. Until the append lands, the old
# file is still the target of a LIVE pending row — and hook-ack-clear.sh
# cannot clear a row whose file is missing, so deleting it early would
# manufacture exactly the unclearable deadlock these hooks refuse to create
# with an empty file_path.
#
# Best-effort throughout: a failure here leaves files on disk, which is the
# status quo, and must never affect the caller.
task_queue_prune_superseded_diags() { # $1 = hook name, $2 = reason, $3 = path to KEEP
	local hook=${1:-} reason=${2:-} keep=${3:-}
	[ -n "$hook" ] && [ -n "$reason" ] && [ -n "$keep" ] || return 0
	local repo_root dir safe_hook safe_reason f
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	# Same sanitising hook_ack_diagnostic_write applies when it builds the
	# path, so this looks in the directory the files are actually in.
	safe_hook=$(printf '%s' "${hook##*/}" | tr -c '[:alnum:]_.-' '-')
	safe_reason=$(printf '%s' "$reason" | tr -c '[:alnum:]_.-' '-' | cut -c1-60)
	[ -n "$safe_hook" ] && [ -n "$safe_reason" ] || return 0
	dir="$repo_root/.claude/.session-state/hook-ack/$safe_hook"
	[ -d "$dir" ] || return 0
	# Compared by BASENAME, not by full path. `keep` and `dir` are derived
	# independently — `keep` from hook_ack_diagnostic_write's own
	# `git rev-parse --show-toplevel`, `dir` from this function's — and on
	# macOS $TMPDIR is /var/folders/… while git reports the resolved
	# /private/var/folders/…, so two strings naming the SAME file compared
	# unequal and the live diagnostic was deleted, leaving a pending row
	# pointing at nothing: the unclearable deadlock this code exists to avoid.
	# The basename carries a timestamp and a random suffix and is unique
	# within the directory, so it identifies the file without depending on
	# how either caller spells the path to it.
	local keep_base=${keep##*/}

	# TWO MORE GUARDS, because "after a successful append" is not enough on
	# its own. hook_ack_append serialises only the APPEND; this prune runs
	# after that lock is released, so with two overlapping registrations one
	# process can delete the diagnostic the other just recorded — the missing
	# path is then unclearable and blocks every later tool call. Rather than
	# reach for another interprocess lock (hook-ack's is not reentrant, so
	# taking it around append+prune would deadlock against append itself),
	# the prune is made SAFE UNDER ANY INTERLEAVING:
	#
	#   1. Never delete a file still REFERENCED by a row in the sentinel.
	#      That is precisely the "cannot be cleared" condition, read from the
	#      authority rather than assumed from ordering.
	#   2. Never delete a file younger than a minute. A concurrent process
	#      that has written its diagnostic but not yet appended its row has
	#      no sentinel reference to protect it, and this is what covers that
	#      window.
	#
	# Both are conservative in the same direction: the cost of skipping a file
	# is that it is collected on the next nudge; the cost of deleting a live
	# one is a wedged session.
	local referenced=""
	local sentinel="$repo_root/.claude/.session-state/hook-output-pending.txt"
	[ -r "$sentinel" ] && referenced=$(cut -f4 "$sentinel" 2>/dev/null)

	while IFS= read -r f; do
		[ -n "$f" ] || continue
		[ "${f##*/}" = "$keep_base" ] && continue
		case "$referenced" in
		*"${f##*/}"*) continue ;;
		esac
		[ -n "$(find "$f" -maxdepth 0 -mmin +1 2>/dev/null)" ] || continue
		rm -f "$f" 2>/dev/null || true
	done < <(find "$dir" -maxdepth 1 -type f -name "*-${safe_reason}-*.txt" 2>/dev/null)
	return 0
}

# The first in_progress item that is NOT blocked. The staleness check used a
# bare status filter, so an item marked blocked AND in_progress was reported
# as stale — nudging the operator about work they had already said cannot
# proceed, which is the fastest way to teach them to ignore the nudge.
task_queue_state_stale_candidate() { # $1 = state JSON
	printf '%s' "${1:-}" | jq -r '
	    [ .items[]? | select(.blocked | not) | select(.status == "in_progress") ]
	    | first | .content // ""' 2>/dev/null || return 1
}
