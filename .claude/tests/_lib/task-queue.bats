#!/usr/bin/env bats
# covers: _lib/task-queue.sh hooks/task-queue-track.sh
#
# (#2554) The SSOT the #2555 nudge hooks read: what is open, which item is
# next, and how many tool calls have passed since the operator last said
# anything about the queue.
#
# The property that matters most here is the THREE-state classification.
# "No todo tool was ever used" and "the list exists and is empty" look
# identical to a boolean and mean opposite things to a nudge — firing on a
# conversational turn is the failure the issue explicitly bounds against, and
# it is the one a two-state answer produces.
#
# State is redirected via TASK_QUEUE_STATE_DIR, a plain env override, and
# NOT via bats-variable detection. #2544 shipped that pattern and it was
# wrong twice: BATS_RUN_TMPDIR is per-RUN so state leaked between tests in
# one file, and the branch was unnecessary anyway because a fixture that cds
# into its own scratch repo already has REPO_ROOT pointed there.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	LIB="$REPO_ROOT/_lib/task-queue.sh"
	HOOK="$REPO_ROOT/hooks/task-queue-track.sh"
	[ -r "$LIB" ]
	[ -x "$HOOK" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t taskqueue.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	STATE_DIR="$TEST_TMP/state"
	# shellcheck source=../../../_lib/task-queue.sh
	source "$LIB"
}

teardown() {
	case "${TEST_TMP:-}" in
	*/taskqueue.*)
		chmod -R u+w "$TEST_TMP" 2>/dev/null || true
		rm -rf "$TEST_TMP"
		;;
	esac
	return 0
}

_items_from() { # $1 = tool_input JSON
	task_queue_from_tool_input "$1"
}

# One TodoWrite-shaped payload.
_todo_input() { # $@ = "content:status" pairs
	local out="[" first=1 pair c s
	for pair in "$@"; do
		c=${pair%%:*}
		s=${pair##*:}
		[ "$first" = "1" ] || out="$out,"
		first=0
		out="$out{\"content\":\"$c\",\"status\":\"$s\"}"
	done
	printf '{"todos":%s]}' "$out"
}

_track() { # $1 = tool_name, $2 = tool_input JSON, $3 = session id
	run bash -c "printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'" _ \
		"$(jq -nc --arg t "$1" --arg s "${3:-sess-1}" --argjson i "$2" \
			'{tool_name:$t, session_id:$s, tool_input:$i}')"
}

_state_json() { # $1 = session id
	local p
	p=$(find "$STATE_DIR" -name '*.json' -type f 2>/dev/null | head -1)
	[ -n "$p" ] || return 1
	cat "$p"
}

# ---- classification: three states, not two -------------------------------

@test "task-queue: NO todo tool ever seen is 'absent', never 'empty'" {
	# The bound the issue states: never fire on a conversational turn. A
	# two-state answer collapses this into "empty" and every such turn gets a
	# nudge, which is how a reminder becomes noise and gets switched off.
	[ "$(task_queue_classify "")" = "absent" ]
}

@test "task-queue: an all-completed list is 'empty', not 'open'" {
	local items
	items=$(_items_from "$(_todo_input "one:completed" "two:completed")")
	[ "$(task_queue_classify "$items")" = "empty" ] || {
		echo "an all-completed list did not read as empty: $items"
		return 1
	}
}

@test "task-queue: a pending item makes the queue 'open'" {
	local items
	items=$(_items_from "$(_todo_input "one:completed" "two:pending")")
	[ "$(task_queue_classify "$items")" = "open" ]
}

@test "task-queue: UNPARSEABLE input is 'absent' — detection fails open" {
	# Not "empty" and not an error. The caller must not nudge on data it could
	# not read, and must not crash the operator's tool call either.
	[ "$(task_queue_classify "not json at all")" = "absent" ] || {
		echo "unreadable items did not fail open to absent"
		return 1
	}
}

@test "task-queue: an item with NO status counts as open, not done" {
	# Defaulting a missing status to completed would silently retire real
	# work. The default is pending for the same reason every other gate in
	# this repo fails toward more attention, not less.
	local items
	items=$(task_queue_from_tool_input '{"todos":[{"content":"nostatus"}]}')
	[ "$(task_queue_classify "$items")" = "open" ] || {
		echo "a status-less item was not treated as open: $items"
		return 1
	}
}

# ---- selection -----------------------------------------------------------

@test "task-queue: RESUMES the in_progress item before starting a pending one" {
	# Pointing at fresh work while something sits half-done is how a queue
	# grows a tail of started-but-abandoned entries.
	local items
	items=$(_items_from "$(_todo_input "first:pending" "second:in_progress")")
	[ "$(task_queue_next_actionable "$items")" = "second" ] || {
		echo "did not prefer the in_progress item: $items"
		return 1
	}
}

@test "task-queue: otherwise takes the FIRST pending in array order" {
	# Array order is the order the operator wrote, which carries their intent
	# about sequence. Nothing here is entitled to re-rank it.
	local items
	items=$(_items_from "$(_todo_input "alpha:pending" "beta:pending")")
	[ "$(task_queue_next_actionable "$items")" = "alpha" ]
}

@test "task-queue: a BLOCKED item is skipped" {
	# Nudging toward work that cannot proceed trains the operator to dismiss
	# the nudge, which costs more than the silence would have.
	local items
	items=$(task_queue_from_tool_input '{"todos":[{"content":"stuck","status":"pending","blocked":true},{"content":"doable","status":"pending"}]}')
	[ "$(task_queue_next_actionable "$items")" = "doable" ] || {
		echo "a blocked item was selected: $items"
		return 1
	}
}

@test "task-queue: no candidate returns non-zero rather than empty success" {
	local items
	items=$(_items_from "$(_todo_input "done:completed")")
	run task_queue_next_actionable "$items"
	[ "$status" -ne 0 ] || {
		echo "an all-completed list yielded a 'next' item: $output"
		return 1
	}
}

# ---- transcript parsing --------------------------------------------------

@test "task-queue: the LAST todo call in a transcript wins" {
	# The list is running state, not an append log: an earlier call's items
	# are superseded. Merging them would resurrect completed work.
	local t="$TEST_TMP/transcript.jsonl"
	jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"TodoWrite",input:{todos:[{content:"old",status:"pending"}]}}]}}' >"$t"
	jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"TodoWrite",input:{todos:[{content:"new",status:"pending"}]}}]}}' >>"$t"
	local items
	items=$(task_queue_from_transcript "$t") || {
		echo "transcript parse failed"
		return 1
	}
	[ "$(task_queue_next_actionable "$items")" = "new" ] || {
		echo "an earlier todo call won: $items"
		return 1
	}
}

@test "task-queue: TaskCreate/TaskUpdate are recognised, not just TodoWrite" {
	# A consumer that knew only the legacy name would report 'absent' on a
	# real queue — which reads exactly like a conversational turn and
	# suppresses every nudge silently.
	local t="$TEST_TMP/transcript.jsonl"
	jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"TaskUpdate",input:{tasks:[{description:"via TaskUpdate",state:"pending"}]}}]}}' >"$t"
	local items
	items=$(task_queue_from_transcript "$t") || {
		echo "TaskUpdate was not parsed"
		return 1
	}
	[ "$(task_queue_classify "$items")" = "open" ] || {
		echo "TaskUpdate items did not register as open: $items"
		return 1
	}
}

@test "task-queue: a transcript with no todo tool is ABSENT, not empty" {
	local t="$TEST_TMP/transcript.jsonl"
	jq -nc '{type:"assistant",message:{content:[{type:"text",text:"just talking"}]}}' >"$t"
	local items rc=0
	items=$(task_queue_from_transcript "$t") || rc=$?
	# Either a hard rc or an empty array — both must classify as absent, and
	# neither may classify as empty.
	[ "$rc" -ne 0 ] || [ "$(task_queue_classify "$items")" != "open" ] || {
		echo "a conversational transcript produced an open queue: $items"
		return 1
	}
}

@test "task-queue: an unreadable transcript returns non-zero, not an empty list" {
	run task_queue_from_transcript "$TEST_TMP/does-not-exist.jsonl"
	[ "$status" -ne 0 ] || {
		echo "a missing transcript reported success: $output"
		return 1
	}
}

# ---- session state -------------------------------------------------------

@test "task-queue: colliding session ids do NOT share a state file" {
	# The slug is many-to-one, which put two branches on one pin file in
	# #2544. Session ids come from a hook payload, so the same hazard applies.
	local a b
	a=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_path "sess/one")
	b=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_path "sess_one")
	[ "$a" != "$b" ] || {
		echo "two distinct session ids mapped to one state file: $a"
		return 1
	}
}

@test "task-queue: a MISSING state file reads as {} — a first call is not an error" {
	[ "$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_read "never-seen")" = "{}" ]
}

@test "task-queue: a CORRUPT state file reads as {} rather than propagating" {
	local p
	p=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_path "sess-x")
	mkdir -p "$(dirname "$p")"
	printf 'not json\n' >"$p"
	[ "$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_read "sess-x")" = "{}" ] || {
		echo "a corrupt state file was not recovered from"
		return 1
	}
}

@test "task-queue: state is written via jq, so a crafted value cannot inject a key" {
	# #2544 shipped a printf-templated JSON state file whose unescaped
	# interpolation let a crafted value add a second key that jq resolved
	# last-wins. Session ids and item text come from tool payloads — the same
	# trust level.
	local evil state
	evil='x","calls_since_update":999,"junk":"'
	state=$(jq -nc --arg ids "$evil" '{open_ids:$ids, calls_since_update:0}')
	TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_write "sess-inj" "$state" || {
		echo "write failed"
		return 1
	}
	local got
	got=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_read "sess-inj")
	[ "$(printf '%s' "$got" | jq -r '.calls_since_update')" = "0" ] || {
		echo "a crafted value overrode the counter: $got"
		return 1
	}
	[ "$(printf '%s' "$got" | jq -r '.open_ids')" = "$evil" ] || {
		echo "the crafted value was not stored verbatim as data: $got"
		return 1
	}
}

@test "task-queue: a non-JSON state body is REFUSED, not written" {
	run bash -c "TASK_QUEUE_STATE_DIR='$STATE_DIR' bash -c 'source \"$LIB\"; task_queue_state_write sess-bad \"not json\"'"
	[ "$status" -ne 0 ] || {
		echo "a non-JSON state body was accepted"
		return 1
	}
}

# ---- the tracking hook ---------------------------------------------------

@test "track: a todo call snapshots the queue and ZEROES the clock" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"a",status:"pending"}]}')"
	[ "$status" -eq 0 ]
	local s
	s=$(_state_json) || {
		echo "no state written"
		return 1
	}
	[ "$(printf '%s' "$s" | jq -r '.calls_since_update')" = "0" ] || {
		echo "the clock was not reset by a todo call: $s"
		return 1
	}
	[ "$(printf '%s' "$s" | jq -r '.items | length')" = "1" ] || {
		echo "the item snapshot is missing: $s"
		return 1
	}
}

@test "track: other tools TICK the clock" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"a",status:"pending"}]}')"
	local n=0
	while [ "$n" -lt 3 ]; do
		_track Bash '{}'
		[ "$status" -eq 0 ]
		n=$((n + 1))
	done
	local s
	s=$(_state_json) || return 1
	[ "$(printf '%s' "$s" | jq -r '.calls_since_update')" = "3" ] || {
		echo "the clock did not advance once per tool call: $s"
		return 1
	}
}

@test "track: a later todo call RE-zeroes the clock" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"a",status:"pending"}]}')"
	_track Bash '{}'
	_track Bash '{}'
	_track TodoWrite "$(jq -nc '{todos:[{content:"a",status:"in_progress"}]}')"
	local s
	s=$(_state_json) || return 1
	[ "$(printf '%s' "$s" | jq -r '.calls_since_update')" = "0" ] || {
		echo "a status update did not reset the staleness clock: $s"
		return 1
	}
}

@test "track: NO state is created before a queue has ever been seen" {
	# A counter with no queue behind it would make the first todo call look
	# instantly stale.
	_track Bash '{}'
	[ "$status" -eq 0 ]
	run _state_json
	[ "$status" -ne 0 ] || {
		echo "a bare tool call created queue state: $output"
		return 1
	}
}

@test "track: TASK_NUDGE_SKIP=1 disables it entirely" {
	run bash -c "printf '%s' \"\$1\" | TASK_NUDGE_SKIP=1 TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'" _ \
		"$(jq -nc '{tool_name:"TodoWrite",session_id:"s",tool_input:{todos:[{content:"a",status:"pending"}]}}')"
	[ "$status" -eq 0 ]
	run _state_json
	[ "$status" -ne 0 ] || {
		echo "the toggle did not prevent state writes: $output"
		return 1
	}
}

@test "track: a malformed payload FAILS OPEN and blocks nothing" {
	# This runs after EVERY tool call. A fault here would be a fault in every
	# action the operator takes, and what it protects is a reminder.
	run bash -c "printf 'not json' | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'"
	[ "$status" -eq 0 ] || {
		echo "a malformed payload made the hook fail: $output"
		return 1
	}
	run bash -c "printf '' | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'"
	[ "$status" -eq 0 ]
}

@test "track: a payload with NO session_id is ignored, not guessed at" {
	run bash -c "printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'" _ \
		"$(jq -nc '{tool_name:"TodoWrite",tool_input:{todos:[{content:"a",status:"pending"}]}}')"
	[ "$status" -eq 0 ]
	run _state_json
	[ "$status" -ne 0 ] || {
		echo "state was written under a guessed session: $output"
		return 1
	}
}

@test "track: two sessions keep SEPARATE clocks" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"a",status:"pending"}]}')" "sess-A"
	_track TodoWrite "$(jq -nc '{todos:[{content:"b",status:"pending"}]}')" "sess-B"
	_track Bash '{}' "sess-A"
	_track Bash '{}' "sess-A"
	local pa pb
	pa=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_path "sess-A")
	pb=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_path "sess-B")
	[ "$(jq -r '.calls_since_update' "$pa")" = "2" ] || {
		echo "session A clock wrong: $(cat "$pa")"
		return 1
	}
	[ "$(jq -r '.calls_since_update' "$pb")" = "0" ] || {
		echo "session B inherited A's ticks: $(cat "$pb")"
		return 1
	}
}

@test "task-queue: stale session state is PRUNED, live state is not" {
	# Real data-loss risk with zero coverage: a prune whose -mtime predicate
	# is lost or inverted deletes every session's state, silently resetting
	# every staleness clock — strictly worse than not pruning at all.
	TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_write "keeper" '{"open_ids":"x"}' || return 1
	mkdir -p "$STATE_DIR"
	local old="$STATE_DIR/dead_session-123456.json"
	printf '{"open_ids":"gone"}\n' >"$old"
	touch -t "$(date -u -v-14d +%Y%m%d0000 2>/dev/null || date -u -d '14 days ago' +%Y%m%d0000)" "$old"
	# A second write is what triggers the prune.
	TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_write "keeper" '{"open_ids":"y"}' || return 1
	[ ! -f "$old" ] || {
		echo "a 14-day-old session file survived the prune"
		return 1
	}
	local keep
	keep=$(TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_path "keeper")
	[ -f "$keep" ] || {
		echo "the prune deleted LIVE session state"
		return 1
	}
}

@test "task-queue: the prune only matches this tool own filenames" {
	# TASK_QUEUE_STATE_DIR is operator-settable and the write path runs a
	# find -delete. Harvesting every old .json from a relocated directory is
	# a destructive default.
	mkdir -p "$STATE_DIR"
	local bystander="$STATE_DIR/notes.json"
	printf '{"not":"session state"}\n' >"$bystander"
	touch -t "$(date -u -v-14d +%Y%m%d0000 2>/dev/null || date -u -d '14 days ago' +%Y%m%d0000)" "$bystander"
	TASK_QUEUE_STATE_DIR="$STATE_DIR" task_queue_state_write "sess-p" '{"open_ids":"z"}' || return 1
	[ -f "$bystander" ] || {
		echo "the prune deleted a file that is not session state"
		return 1
	}
}

@test "task-queue: with NO override the state dir is repo-scoped" {
	# Every other test sets TASK_QUEUE_STATE_DIR, so the default branch — the
	# one that actually runs in production — was never exercised. The #2637
	# lesson: a fixture that reproduces the inputs but not the real
	# configuration certifies a path nothing takes.
	local got
	got=$(
		cd "$TEST_TMP" && git init -q -b main 2>/dev/null
		cd "$TEST_TMP" && TASK_QUEUE_STATE_DIR="" bash -c "source '$LIB'; _task_queue_state_dir"
	)
	case "$got" in
	*/.claude/.session-state/task-queue) ;;
	*)
		echo "the default state dir is not repo-scoped: $got"
		return 1
		;;
	esac
}

@test "task-queue: alternative content field names are read" {
	# The normaliser falls through .content / .description / .title / .prompt
	# because Task* carries different keys by version. An unread key means an
	# item with empty content, which the selector then cannot name.
	local items
	items=$(task_queue_from_tool_input '{"tasks":[{"description":"via description","state":"pending"}]}')
	[ "$(task_queue_next_actionable "$items")" = "via description" ] || {
		echo ".description was not read: $items"
		return 1
	}
	items=$(task_queue_from_tool_input '{"items":[{"title":"via title","status":"pending"}]}')
	[ "$(task_queue_next_actionable "$items")" = "via title" ] || {
		echo ".title was not read: $items"
		return 1
	}
}

@test "task-queue: a BLOCKED item does not count toward the open-id hash" {
	# open_ids and next_actionable must agree on what 'open' means. They did
	# not: a blocked item counted toward the hash while being unselectable, so
	# a queue whose only remaining work was blocked reported movement that
	# could never happen.
	local all_blocked only_completed
	all_blocked=$(task_queue_from_tool_input '{"todos":[{"content":"stuck","status":"pending","blocked":true}]}')
	only_completed=$(task_queue_from_tool_input '{"todos":[{"content":"done","status":"completed"}]}')
	[ "$(task_queue_open_ids "$all_blocked")" = "$(task_queue_open_ids "$only_completed")" ] || {
		echo "a blocked-only queue hashed differently from an empty one"
		return 1
	}
}
