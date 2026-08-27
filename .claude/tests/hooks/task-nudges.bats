#!/usr/bin/env bats
# covers: hooks/next-task-stop-nudge.sh hooks/task-issue-reconcile.sh
# audits: hooks/task-queue-track.sh
#
# (#2555) The three mechanical nudges. Each writes a hook-ack diagnostic and
# registers a sentinel, so `stale-state-gate.sh` denies the next tool call
# until it is Read — the difference between documenting an intent and making
# it happen, which is what epic #2544 is about.
#
# `next-step-advisor.sh` already existed and was advisory-only: exit 0, output
# that scrolls past exactly like the lint failures #2547 fixed. So the
# property under test is not "did it print something" but "did it register a
# diagnostic", and the assertions are on the FILE, not on stdout.
#
# The other property that matters is the BOUNDS. A nudge that fires wrongly
# gets switched off and then protects nothing, so every negative case here —
# conversational turn, empty queue, loop guard, toggle — is as load-bearing as
# the positive one.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	STOP_HOOK="$REPO_ROOT/hooks/next-task-stop-nudge.sh"
	TRACK_HOOK="$REPO_ROOT/hooks/task-queue-track.sh"
	[ -x "$STOP_HOOK" ]
	[ -x "$TRACK_HOOK" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t tasknudge.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	STATE_DIR="$TEST_TMP/state"
	# hook_ack_diagnostic_write resolves its directory from the git toplevel,
	# so a scratch repo keeps every diagnostic out of the real tree. The suite
	# asserts on files, and writing them into the operator's own hook-ack dir
	# would block their next tool call for a test fixture.
	WORK="$TEST_TMP/work"
	mkdir -p "$WORK"
	(cd "$WORK" && git init -q -b main &&
		git config user.email t@t.t && git config user.name t) || {
		echo "FATAL: fixture repo init failed" >&2
		return 1
	}
	DIAG_ROOT="$WORK/.claude/.session-state/hook-ack"
}

teardown() {
	cd /tmp || return 0
	case "${TEST_TMP:-}" in
	*/tasknudge.*)
		chmod -R u+w "$TEST_TMP" 2>/dev/null || true
		rm -rf "$TEST_TMP"
		;;
	esac
	return 0
}

# A transcript whose last tool_use is a TodoWrite with the given items.
_transcript() { # $@ = "content:status" pairs
	local f="$TEST_TMP/transcript.jsonl" out="[" first=1 pair c s
	for pair in "$@"; do
		c=${pair%%:*}
		s=${pair##*:}
		[ "$first" = "1" ] || out="$out,"
		first=0
		out="$out{\"content\":\"$c\",\"status\":\"$s\"}"
	done
	out="$out]"
	jq -nc --argjson todos "$out" \
		'{type:"assistant",message:{content:[{type:"tool_use",name:"TodoWrite",input:{todos:$todos}}]}}' >"$f"
	printf '%s' "$f"
}

_conversational_transcript() {
	local f="$TEST_TMP/conv.jsonl"
	jq -nc '{type:"assistant",message:{content:[{type:"text",text:"just discussing"}]}}' >"$f"
	printf '%s' "$f"
}

_run_stop() { # $1 = transcript path, $2 = stop_hook_active (default false), $3 = extra env
	run bash -c "cd '$WORK' && printf '%s' \"\$1\" | ${3:-} bash '$STOP_HOOK'" _ \
		"$(jq -nc --arg t "$1" --argjson a "${2:-false}" \
			'{transcript_path:$t, stop_hook_active:$a, session_id:"sess-1"}')"
}

_diag_count() { # $1 = hook dir name
	find "$DIAG_ROOT/${1:-}" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

_diag_body() { # $1 = hook dir name
	local f
	f=$(find "$DIAG_ROOT/${1:-}" -type f -name '*.txt' 2>/dev/null | head -1)
	[ -n "$f" ] || return 1
	cat "$f"
}

# ---- the Stop nudge: positive case ---------------------------------------

@test "stop-nudge: open work REGISTERS a diagnostic, not just a message" {
	# The whole point. next-step-advisor.sh already printed advice that
	# scrolled past; what makes this mechanical is the hook-ack file.
	_run_stop "$(_transcript "write the thing:pending" "done bit:completed")"
	[ "$status" -eq 0 ]
	[ "$(_diag_count next-task-stop-nudge)" = "1" ] || {
		echo "no diagnostic registered: $output"
		return 1
	}
	local body
	body=$(_diag_body next-task-stop-nudge) || return 1
	case "$body" in
	*"write the thing"*) ;;
	*)
		echo "the diagnostic does not name the next item: $body"
		return 1
		;;
	esac
}

@test "stop-nudge: it also emits a systemMessage for immediate visibility" {
	_run_stop "$(_transcript "urgent item:pending")"
	[ "$status" -eq 0 ]
	[[ $output == *systemMessage* ]] || {
		echo "no systemMessage emitted: $output"
		return 1
	}
	[[ $output == *"urgent item"* ]]
}

@test "stop-nudge: it RESUMES in_progress rather than naming a pending item" {
	_run_stop "$(_transcript "not started:pending" "half done:in_progress")"
	local body
	body=$(_diag_body next-task-stop-nudge) || return 1
	case "$body" in
	*"half done"*) ;;
	*)
		echo "the nudge pointed past the in-progress item: $body"
		return 1
		;;
	esac
}

# ---- the Stop nudge: the bounds ------------------------------------------

@test "stop-nudge: a CONVERSATIONAL turn is silent" {
	# The bound the issue states outright. A queue that was never created is
	# 'absent', not 'empty' — collapsing those is what makes a reminder fire
	# on every chat turn and then get switched off.
	_run_stop "$(_conversational_transcript)"
	[ "$status" -eq 0 ]
	[ "$(_diag_count next-task-stop-nudge)" = "0" ] || {
		echo "a conversational turn was nudged"
		return 1
	}
	[ -z "$output" ] || {
		echo "a conversational turn produced output: $output"
		return 1
	}
}

@test "stop-nudge: an ALL-COMPLETED queue is silent" {
	_run_stop "$(_transcript "one:completed" "two:completed")"
	[ "$status" -eq 0 ]
	[ "$(_diag_count next-task-stop-nudge)" = "0" ] || {
		echo "a finished queue was nudged"
		return 1
	}
}

@test "stop-nudge: stop_hook_active TRUE exits before anything else" {
	# Loop guard. A Stop hook firing during its own Stop handling re-enters
	# forever and re-registers its block each time.
	_run_stop "$(_transcript "open item:pending")" true
	[ "$status" -eq 0 ]
	[ "$(_diag_count next-task-stop-nudge)" = "0" ] || {
		echo "the loop guard did not hold"
		return 1
	}
}

@test "stop-nudge: TASK_NUDGE_SKIP=1 disables it" {
	_run_stop "$(_transcript "open item:pending")" false "TASK_NUDGE_SKIP=1"
	[ "$status" -eq 0 ]
	[ "$(_diag_count next-task-stop-nudge)" = "0" ] || {
		echo "the operator toggle was ignored"
		return 1
	}
}

@test "stop-nudge: a missing transcript FAILS OPEN and blocks nothing" {
	_run_stop "$TEST_TMP/nope.jsonl"
	[ "$status" -eq 0 ] || {
		echo "an unreadable transcript made the Stop hook fail: $output"
		return 1
	}
	[ "$(_diag_count next-task-stop-nudge)" = "0" ]
}

@test "stop-nudge: a malformed payload FAILS OPEN" {
	run bash -c "cd '$WORK' && printf 'not json' | bash '$STOP_HOOK'"
	[ "$status" -eq 0 ] || {
		echo "a malformed Stop payload failed: $output"
		return 1
	}
}

@test "stop-nudge: a BLOCKED-only queue does not name an unreachable item" {
	# Nudging toward work that cannot proceed trains the operator to dismiss.
	local f="$TEST_TMP/blocked.jsonl"
	jq -nc '{type:"assistant",message:{content:[{type:"tool_use",name:"TodoWrite",input:{todos:[{content:"stuck",status:"pending",blocked:true}]}}]}}' >"$f"
	_run_stop "$f"
	[ "$status" -eq 0 ]
	[ "$(_diag_count next-task-stop-nudge)" = "0" ] || {
		echo "a blocked-only queue produced a nudge: $(_diag_body next-task-stop-nudge)"
		return 1
	}
}

# ---- the staleness nudge (in task-queue-track.sh) ------------------------

_track() { # $1 = tool_name, $2 = tool_input, $3 = extra env
	run bash -c "cd '$WORK' && printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' ${3:-} bash '$TRACK_HOOK'" _ \
		"$(jq -nc --arg t "$1" --argjson i "$2" '{tool_name:$t, session_id:"sess-1", tool_input:$i}')"
}

_tick() { # $1 = how many, $2 = threshold
	local n=0
	while [ "$n" -lt "${1:-1}" ]; do
		_track Bash '{}' "TASK_STALE_AFTER_CALLS=${2:-3}"
		n=$((n + 1))
	done
}

@test "stale-nudge: an in_progress item past the threshold registers ONCE" {
	# The re-arm guard is the difference between a mechanism that gets
	# noticed and one that gets dismissed: without it the sentinel thrashes
	# on every subsequent tool call.
	_track TodoWrite "$(jq -nc '{todos:[{content:"long one",status:"in_progress"}]}')"
	_tick 3 3
	[ "$(_diag_count task-queue-track)" = "1" ] || {
		echo "the staleness nudge did not fire at threshold"
		return 1
	}
	_tick 8 3
	[ "$(_diag_count task-queue-track)" = "1" ] || {
		echo "the nudge re-fired instead of arming once: $(_diag_count task-queue-track)"
		return 1
	}
}

@test "stale-nudge: it does NOT fire below the threshold" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"recent",status:"in_progress"}]}')"
	_tick 2 5
	[ "$(_diag_count task-queue-track)" = "0" ] || {
		echo "the nudge fired during ordinary work on the item"
		return 1
	}
}

@test "stale-nudge: a status update RE-ARMS it" {
	# Re-arming is what makes it a staleness detector rather than a one-shot.
	_track TodoWrite "$(jq -nc '{todos:[{content:"item A",status:"in_progress"}]}')"
	_tick 3 3
	[ "$(_diag_count task-queue-track)" = "1" ]
	# The operator reconciles, then goes quiet again on a NEW item.
	_track TodoWrite "$(jq -nc '{todos:[{content:"item B",status:"in_progress"}]}')"
	_tick 3 3
	[ "$(_diag_count task-queue-track)" = "2" ] || {
		echo "the nudge did not re-arm after a status update"
		return 1
	}
}

@test "stale-nudge: a PENDING-only queue is not stale" {
	# Staleness is about work claimed to be underway. A pending item nobody
	# started is the Stop nudge's business, not this one's.
	_track TodoWrite "$(jq -nc '{todos:[{content:"never started",status:"pending"}]}')"
	_tick 6 3
	[ "$(_diag_count task-queue-track)" = "0" ] || {
		echo "a pending item was reported as stale"
		return 1
	}
}

@test "stale-nudge: TASK_NUDGE_SKIP=1 disables it" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"x",status:"in_progress"}]}')"
	local n=0
	while [ "$n" -lt 5 ]; do
		_track Bash '{}' "TASK_STALE_AFTER_CALLS=2 TASK_NUDGE_SKIP=1"
		n=$((n + 1))
	done
	[ "$(_diag_count task-queue-track)" = "0" ] || {
		echo "the operator toggle was ignored by the staleness nudge"
		return 1
	}
}

@test "stale-nudge: a non-numeric threshold falls back, it does not crash" {
	_track TodoWrite "$(jq -nc '{todos:[{content:"y",status:"in_progress"}]}')"
	_track Bash '{}' "TASK_STALE_AFTER_CALLS=banana"
	[ "$status" -eq 0 ] || {
		echo "a junk threshold broke the hook: $output"
		return 1
	}
}
