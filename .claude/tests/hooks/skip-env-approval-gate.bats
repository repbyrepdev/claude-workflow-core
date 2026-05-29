#!/usr/bin/env bats
# covers: hooks/skip-env-approval-gate.sh
#
# v0.30.0 (#180): regression locks for the v0.28.0 (#178) per-call skip-approval
# gate. These pin the CR fixes baked into #178 (quote-aware detection, full-CMD
# hash, jq fail-closed, recursion guard) so a future refactor can't silently
# re-open the fail-open holes. Covers the highest-priority gaps T1/T2/T3/T5/T16.
#
# The hook is a PreToolUse Bash gate: it reads a JSON payload on stdin, extracts
# .tool_input.command, and refuses (rc 2) when the command LEADS with a
# `*_SKIP=` / `*_BYPASS=` / HOOK_ACK_CLEAR= env prefix lacking a per-call
# approval file. REPO_ROOT is resolved from cwd via git.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/skip-env-approval-gate.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t skip-gate.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
	# The recursion guard is operator-set ONLY; make sure it isn't leaking in
	# from the parent process (T3) and silently disabling the gate.
	unset SKIP_APPROVAL_GATE_RECURSED
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */skip-gate.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Feed a PreToolUse payload (JSON via stdin) to the hook with cwd = the tmp repo
# so its `git rev-parse` resolves REPO_ROOT there. The command is written to a
# file (not interpolated) to avoid quoting hazards.
_run_hook() {
	jq -nc --arg c "$1" '{tool_input:{command:$c}}' >"$TEST_TMP/payload.json"
	run bash -c "cd '$TEST_TMP' && bash '$HOOK' < '$TEST_TMP/payload.json'"
}

@test "quoted-whitespace env prefix does not break skip detection — refused (T1)" {
	# CR fix #7: a preceding `FOO='bar baz'` must NOT word-split and hide the
	# trailing skip var. The quote-aware regex still detects MEMORY_DRIFT_GATE_SKIP.
	_run_hook "FOO='bar baz' MEMORY_DRIFT_GATE_SKIP=1 echo hi"
	[ "$status" -eq 2 ]
	[[ $output == *"MEMORY_DRIFT_GATE_SKIP"* ]]
}

@test "SKIP_APPROVAL_GATE_RECURSED=1 lets a skip command through (T3 recursion guard)" {
	jq -nc --arg c "LINT_GATE_SKIP=1 echo hi" '{tool_input:{command:$c}}' >"$TEST_TMP/payload.json"
	run bash -c "cd '$TEST_TMP' && SKIP_APPROVAL_GATE_RECURSED=1 bash '$HOOK' < '$TEST_TMP/payload.json'"
	[ "$status" -eq 0 ]
}

@test "approval is per-exact-command — same >50-char prefix does NOT collide (T2)" {
	# CR fix #4: hash the FULL command, not a 50-char preview. Two commands that
	# share a >50-char prefix but differ in the tail must get DISTINCT approval
	# files, so approving one never grants the other.
	local pfx="LINT_GATE_SKIP=1 echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	# A is refused; grab its approval-file path from the deny message.
	_run_hook "$pfx ONE"
	[ "$status" -eq 2 ]
	local fileA
	fileA=$(printf '%s\n' "$output" | grep -oE '/[^ ]*/skip-approvals/[0-9a-f]+\.txt' | head -1)
	[ -n "$fileA" ]
	# Grant approval for A, then A is consumed (rc 0).
	touch "$fileA"
	_run_hook "$pfx ONE"
	[ "$status" -eq 0 ]
	# B shares the >50-char prefix but differs in the tail → distinct hash →
	# still refused (no collision with A's approval).
	_run_hook "$pfx TWO"
	[ "$status" -eq 2 ]
}

@test "jq missing → fail-closed (refuse skip), not fail-open (T5)" {
	# CR fix #2: when jq can't be found the gate cannot read the payload, so it
	# must REFUSE (rc 2), never let the skip through. Build a PATH with the
	# hook's other tools symlinked but jq deliberately absent.
	local nojq="$TEST_TMP/nojq" t src
	mkdir -p "$nojq"
	for t in bash git sha256sum shasum mktemp cat mv rm mkdir date head awk sed grep dirname; do
		src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$nojq/$t"
	done
	jq -nc --arg c "LINT_GATE_SKIP=1 echo hi" '{tool_input:{command:$c}}' >"$TEST_TMP/payload.json"
	run env -i PATH="$nojq" HOME="$HOME" bash -c "cd '$TEST_TMP' && bash '$HOOK' < '$TEST_TMP/payload.json'"
	[ "$status" -eq 2 ]
	[[ $output == *"jq missing"* ]]
}

@test "skip var embedded mid-command (not a leading prefix) is not gated (T16)" {
	# security-review (#178 r1) confirmed the anchored `^` regex only matches
	# LEADING skip-env prefixes; a skip token embedded inside a quoted string or
	# a command-substitution is out of scope (not a top-level env assignment).
	# This documents that analysis so it isn't re-litigated.
	_run_hook 'echo "$(date): LINT_GATE_SKIP=1 is just text here"'
	[ "$status" -eq 0 ]
}
