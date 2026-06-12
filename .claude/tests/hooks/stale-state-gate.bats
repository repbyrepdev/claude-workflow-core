#!/usr/bin/env bats
# covers: hooks/stale-state-gate.sh
#
# #2292: PreToolUse ack gate (matcher Bash|Edit|Write|MultiEdit). Reads the
# unified sentinel .claude/.session-state/hook-output-pending.txt; a non-empty
# sentinel BLOCKS the next Bash/Edit/Write with a deny decision until the
# operator Reads each pending file. Read passes through (deadlock prevention).
# HOOK_ACK_CLEAR=1 wholesale-clears WITH an audit record, refusing the bypass
# if the audit cannot be written. Legacy sentinel filenames are migrated into
# the unified file. bash-3.2 compatible (no mapfile).
#
# Idiom (see ship-cycle-guard.bats): run the REAL script with cwd in a git
# sandbox so REPO_ROOT = git toplevel; payloads are JSON on stdin via jq -nc;
# the runner merges stderr into $output so deny/bypass messages are assertable.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/stale-state-gate.sh"
	[ -f "$SCRIPT" ]
	# pwd -P resolves macOS /var symlinks so git toplevel == TEST_TMP.
	TEST_TMP=$(cd "$(mktemp -d -t stale-state-gate.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m seed
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	SENTINEL="$TEST_TMP/.claude/.session-state/hook-output-pending.txt"
	mkdir -p "$(dirname "$SENTINEL")"
}

teardown() {
	# Restore perms a refuse-bypass test may have dropped, so rm -rf works.
	# Explicit if + `|| true` so a chmod failure can't abort teardown before the
	# rm below (an `&& ... || true` one-liner trips shellcheck SC2015).
	if [ -n "${TEST_TMP:-}" ]; then chmod -R u+rwx "$TEST_TMP" 2>/dev/null || true; fi
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */stale-state-gate.* ]] && rm -rf "$TEST_TMP"
}

# Append one tab-separated pending entry: ts \t hook \t reason \t file_path
_seed_entry() {
	printf '%s\t%s\t%s\t%s\n' \
		"2020-01-01T00:00:00Z" "${1:-myhook}" "${2:-some-reason}" "${3:-/x/diag.txt}" \
		>>"$SENTINEL"
}

# Build a PreToolUse payload: $1=tool_name, $2=command (optional).
_payload() {
	jq -nc --arg t "$1" --arg c "${2:-}" '{tool_name:$t,tool_input:{command:$c}}'
}

# Run the real gate with cwd in the sandbox. $1=payload, $2..=env assignments
# (e.g. HOOK_ACK_CLEAR=1). stderr merged into stdout for assertions.
_run_gate() {
	local payload=$1
	shift
	(cd "$TEST_TMP" && printf '%s' "$payload" | env "$@" bash "$SCRIPT" 2>&1)
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "no sentinel file → passes through (exit 0, no deny)" {
	run _run_gate "$(_payload Bash 'echo hi')"
	[ "$status" -eq 0 ]
	[[ $output != *deny* ]]
	[[ $output != *BLOCKED* ]]
}

@test "empty sentinel → passes through (exit 0, no deny)" {
	: >"$SENTINEL"
	run _run_gate "$(_payload Bash 'echo hi')"
	[ "$status" -eq 0 ]
	[[ $output != *BLOCKED* ]]
}

@test "not inside a git repo → passes through (exit 0)" {
	# Outside any git toplevel, `git rev-parse --show-toplevel` fails → exit 0
	# before the sentinel is ever consulted.
	local nogit
	nogit=$(cd "$(mktemp -d -t stale-nogit.XXXXXX)" && pwd -P)
	run bash -c "cd '$nogit' && printf '%s' '$(_payload Bash echo)' | '$SCRIPT' 2>&1"
	rm -rf "$nogit"
	[ "$status" -eq 0 ]
	[[ $output != *BLOCKED* ]]
}

@test "non-empty sentinel + Bash tool → DENY (surfaces the entry)" {
	_seed_entry "lint-shell" "shellcheck-warn" "/tmp/diag-42.txt"
	run _run_gate "$(_payload Bash 'rm -rf x')"
	# The deny decision goes to stdout as JSON (exit 0) and the human-readable
	# REASON to stderr; assert BOTH the decision and that the entry surfaced.
	[ "$status" -eq 0 ]
	[[ $output == *deny* ]]
	[[ $output == *BLOCKED* ]]
	[[ $output == *lint-shell* ]]
}

@test "Read tool with a pending sentinel → passes through (deadlock prevention)" {
	# Read is HOW the operator clears the gate, so it must never be blocked —
	# otherwise the gate deadlocks (refuses the Read that would clear it).
	_seed_entry "lint-shell" "shellcheck-warn" "/tmp/diag-42.txt"
	run _run_gate "$(_payload Read)"
	[ "$status" -eq 0 ]
	# Pure pass-through: no deny decision, no block reason.
	[ -z "$output" ]
}

@test "HOOK_ACK_CLEAR=1 env → wholesale-clears + writes audit log" {
	_seed_entry "lint-shell" "shellcheck-warn" "/tmp/diag-42.txt"
	_seed_entry "lint-yaml" "yamllint-warn" "/tmp/diag-43.txt"
	run _run_gate "$(_payload Bash 'echo hi')" HOOK_ACK_CLEAR=1
	[ "$status" -eq 0 ]
	[[ $output == *wholesale-clearing* ]]
	# Side effects: the sentinel is emptied AND the bypass is audit-logged.
	[ ! -s "$SENTINEL" ]
	[ -f "$TEST_TMP/.claude/logs/hook-ack-skip.jsonl" ]
}

@test "HOOK_ACK_CLEAR=1 in the command string → also bypasses" {
	_seed_entry "lint-shell" "shellcheck-warn" "/tmp/diag-42.txt"
	run _run_gate "$(_payload Bash 'HOOK_ACK_CLEAR=1 git commit')"
	[ "$status" -eq 0 ]
	[[ $output == *wholesale-clearing* ]]
	[ ! -s "$SENTINEL" ]
}

@test "HOOK_ACK_CLEAR=1 with an unwritable logs dir → refuses (exit 2)" {
	_seed_entry "lint-shell" "shellcheck-warn" "/tmp/diag-42.txt"
	mkdir -p "$TEST_TMP/.claude/logs"
	chmod 555 "$TEST_TMP/.claude/logs"
	run _run_gate "$(_payload Bash 'echo hi')" HOOK_ACK_CLEAR=1
	chmod 755 "$TEST_TMP/.claude/logs"
	# Key assertions last: the bypass is REFUSED (exit 2) so an unrecordable
	# clear cannot silently destroy the pending acks, AND the sentinel survived.
	[ "$status" -eq 2 ]
	[[ $output == *"audit FAILED"* ]]
	[ -s "$SENTINEL" ]
}

@test "legacy sentinel filename is migrated into the unified sentinel" {
	# Edge case from the hook's inline comments: a legacy plain-path file is
	# converted to the tab-separated format and removed; the migrated entry
	# then blocks like any other pending ack.
	local legacy="$TEST_TMP/.claude/.session-state/shfmt-stale.txt"
	printf '%s\n' "scripts/some-file.sh" >"$legacy"
	run _run_gate "$(_payload Bash 'echo hi')"
	[ ! -f "$legacy" ]
	[ -f "$SENTINEL" ]
	grep -q 'scripts/some-file.sh' "$SENTINEL"
	[[ $output == *BLOCKED* ]]
}

@test "jq unavailable → fails closed (exit 2, still BLOCKS)" {
	# The deny-JSON decision needs jq; without it the gate must STILL block
	# (exit 2 + reason) rather than silently allow the tool call. A regression
	# making this fail-open would disable the entire ack gate on any box
	# missing jq. PATH carries git + bash but not jq (sibling pattern from
	# check-ssot-drift.bats' yq-missing test).
	_seed_entry "lint-shell" "shellcheck-warn" "/tmp/diag-42.txt"
	local nobin="$TEST_TMP/nobin"
	mkdir -p "$nobin"
	ln -s "$(command -v git)" "$nobin/git"
	ln -s "$(command -v bash)" "$nobin/bash"
	run bash -c "cd '$TEST_TMP' && printf '%s' '$(_payload Bash echo)' | PATH='$nobin' '$SCRIPT' 2>&1"
	# Key assertions last: non-zero exit AND the block reason (fail-closed).
	[ "$status" -eq 2 ]
	[[ $output == *BLOCKED* ]]
}
