#!/usr/bin/env bats
# covers: hooks/task-issue-reconcile.sh
#
# (#2555) The third drift: a commit lands referencing an issue and the task
# list does not move. The work happened; the list still says pending, or still
# says in_progress, or never had an item for it.
#
# The hook compares the OPEN-ITEM SET across commits rather than watching for
# one specific transition, because an operator reconciles by completing an
# item, by adding the follow-up they found mid-flight, or by re-scoping — all
# three move the set, and only doing nothing leaves it identical.
#
# These drive the REAL hook against a scratch git repo with real commits, so
# `post_commit_detect_init` sees what it actually sees in production. The
# lesson from #2637: a fixture that reproduces the inputs but not the CALL
# SEQUENCE certifies behaviour the system never exhibits.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	HOOK="$REPO_ROOT/hooks/task-issue-reconcile.sh"
	TRACK="$REPO_ROOT/hooks/task-queue-track.sh"
	[ -x "$HOOK" ]
	[ -x "$TRACK" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t taskreconcile.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	STATE_DIR="$TEST_TMP/state"
	WORK="$TEST_TMP/work"
	mkdir -p "$WORK"
	(cd "$WORK" && git init -q -b main &&
		git config user.email t@t.t && git config user.name t &&
		printf 'seed\n' >f.txt && git add -A && git commit -qm "chore: seed") || {
		echo "FATAL: fixture repo init failed" >&2
		return 1
	}
	DIAG_ROOT="$WORK/.claude/.session-state/hook-ack"
}

teardown() {
	cd /tmp || return 0
	case "${TEST_TMP:-}" in
	*/taskreconcile.*)
		chmod -R u+w "$TEST_TMP" 2>/dev/null || true
		rm -rf "$TEST_TMP"
		;;
	esac
	return 0
}

# Seed the session queue through the REAL tracking hook, so the state shape is
# whatever that hook actually writes rather than something hand-built here.
_seed_queue() { # $@ = "content:status" pairs
	local out="[" first=1 pair c s
	for pair in "$@"; do
		c=${pair%%:*}
		s=${pair##*:}
		[ "$first" = "1" ] || out="$out,"
		first=0
		out="$out{\"content\":\"$c\",\"status\":\"$s\"}"
	done
	out="$out]"
	run bash -c "cd '$WORK' && printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$TRACK'" _ \
		"$(jq -nc --argjson todos "$out" \
			'{tool_name:"TodoWrite", session_id:"sess-1", tool_input:{todos:$todos}}')"
	[ "$status" -eq 0 ]
}

_commit() { # $1 = message
	(cd "$WORK" && printf '%s\n' "$RANDOM$RANDOM" >>f.txt && git add -A &&
		git commit -qm "$1") || return 1
}

_run_hook() { # $1 = extra env
	run bash -c "cd '$WORK' && printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' ${2:-} bash '$HOOK'" _ \
		"$(jq -nc '{tool_name:"Bash", session_id:"sess-1", tool_input:{command:"git commit -m x"}, tool_response:{exit_code:0}}')"
}

_diag_count() {
	find "$DIAG_ROOT/task-issue-reconcile" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '
}

_diag_body() {
	local f
	f=$(find "$DIAG_ROOT/task-issue-reconcile" -type f -name '*.txt' 2>/dev/null | head -1)
	[ -n "$f" ] || return 1
	cat "$f"
}

@test "reconcile: an unmoved list after an issue commit REGISTERS a directive" {
	# The case the hook exists for. Two commits referencing an issue with no
	# task movement between them.
	_seed_queue "build the thing:in_progress"
	_commit "feat(x): first part of #1234"
	_run_hook
	[ "$status" -eq 0 ]
	# First commit only establishes the baseline — nothing to compare against.
	[ "$(_diag_count)" = "0" ] || {
		echo "the first commit of a session claimed drift with nothing to compare"
		return 1
	}
	_commit "feat(x): second part of #1234"
	_run_hook
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "1" ] || {
		echo "an unmoved list after an issue commit was not flagged"
		return 1
	}
	local body
	body=$(_diag_body) || return 1
	case "$body" in
	*"#1234"*) ;;
	*)
		echo "the diagnostic does not name the referenced issue: $body"
		return 1
		;;
	esac
}

@test "reconcile: COMPLETING an item counts as reconciliation" {
	_seed_queue "build the thing:in_progress"
	_commit "feat(x): part one of #99"
	_run_hook
	# The operator reconciles before the next commit.
	_seed_queue "build the thing:completed" "next thing:pending"
	_commit "feat(x): part two of #99"
	_run_hook
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ] || {
		echo "a reconciled list was still flagged: $(_diag_body)"
		return 1
	}
}

@test "reconcile: ADDING an item also counts — it is not only about completion" {
	# Watching for a specific completed-transition would miss this. Discovering
	# follow-up work mid-flight and writing it down IS reconciling the list
	# with reality.
	_seed_queue "original:in_progress"
	_commit "fix(y): something for #77"
	_run_hook
	_seed_queue "original:in_progress" "discovered follow-up:pending"
	_commit "fix(y): more for #77"
	_run_hook
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ] || {
		echo "adding a discovered item was not accepted as reconciliation"
		return 1
	}
}

@test "reconcile: a commit with NO issue reference is silent" {
	_seed_queue "thing:in_progress"
	_commit "chore: tidy up"
	_run_hook
	_commit "chore: tidy up more"
	_run_hook
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ] || {
		echo "a commit with no issue reference was flagged"
		return 1
	}
}

@test "reconcile: a session with NO task queue is silent" {
	# Firing here would demand a task list from an operator who never made
	# one — the conversational-turn failure in a different costume.
	_commit "feat(z): work on #55"
	_run_hook
	_commit "feat(z): more on #55"
	_run_hook
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ] || {
		echo "a queue-less session was nudged"
		return 1
	}
}

@test "reconcile: an ordinary Bash call does NOT fire it" {
	# post_commit_detect_init gates on the INVOCATION — was this Bash call a
	# successful `git commit` — not on whether HEAD moved. So the real
	# "no commit landed" case is a command that is not a commit at all.
	# Without the gate this would fire after every `ls` and read whatever HEAD
	# happened to be.
	_seed_queue "thing:in_progress"
	_commit "feat(a): for #11"
	_run_hook
	local n=0
	while [ "$n" -lt 3 ]; do
		run bash -c "cd '$WORK' && printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'" _ \
			"$(jq -nc '{tool_name:"Bash", session_id:"sess-1", tool_input:{command:"ls -la"}, tool_response:{exit_code:0}}')"
		[ "$status" -eq 0 ]
		n=$((n + 1))
	done
	[ "$(_diag_count)" = "0" ] || {
		echo "a non-commit Bash call fired the hook: $(_diag_body)"
		return 1
	}
}

@test "reconcile: a FAILED commit does not fire it" {
	# exit_code != 0 means the commit did not land — the pre-commit gate will
	# have surfaced why, and there is nothing to reconcile against.
	_seed_queue "thing:in_progress"
	_commit "feat(b): for #12"
	_run_hook
	run bash -c "cd '$WORK' && printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'" _ \
		"$(jq -nc '{tool_name:"Bash", session_id:"sess-1", tool_input:{command:"git commit -m x"}, tool_response:{exit_code:1}}')"
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ] || {
		echo "a failed commit fired the hook: $(_diag_body)"
		return 1
	}
}

@test "reconcile: MULTIPLE issue references are all named" {
	# One commit can close several issues; reconciling only the first would
	# leave the rest silently unreconciled.
	_seed_queue "thing:in_progress"
	_commit "fix: touches #10 and #20"
	_run_hook
	_commit "fix: still touches #10 and #20"
	_run_hook
	local body
	body=$(_diag_body) || {
		echo "no diagnostic written"
		return 1
	}
	case "$body" in
	*"#10"*) ;;
	*)
		echo "the first issue was not named: $body"
		return 1
		;;
	esac
	case "$body" in
	*"#20"*) ;;
	*)
		echo "the second issue was not named: $body"
		return 1
		;;
	esac
}

@test "reconcile: TASK_NUDGE_SKIP=1 disables it" {
	_seed_queue "thing:in_progress"
	_commit "feat: for #42"
	_run_hook
	_commit "feat: more for #42"
	_run_hook "" "TASK_NUDGE_SKIP=1"
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ] || {
		echo "the operator toggle was ignored"
		return 1
	}
}

@test "reconcile: a malformed payload FAILS OPEN" {
	run bash -c "cd '$WORK' && printf 'not json' | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'"
	[ "$status" -eq 0 ] || {
		echo "a malformed payload made the hook fail: $output"
		return 1
	}
}

@test "reconcile: a payload with no session_id is ignored" {
	_seed_queue "thing:in_progress"
	_commit "feat: for #7"
	run bash -c "cd '$WORK' && printf '%s' \"\$1\" | TASK_QUEUE_STATE_DIR='$STATE_DIR' bash '$HOOK'" _ \
		"$(jq -nc '{tool_name:"Bash", tool_input:{command:"git commit -m x"}, tool_response:{exit_code:0}}')"
	[ "$status" -eq 0 ]
	[ "$(_diag_count)" = "0" ]
}
