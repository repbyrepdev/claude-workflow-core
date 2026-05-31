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
	# rc 0 must come from the recursion guard, not a fail-open in the deny path.
	[[ $output != *"BLOCKED by skip-env-approval-gate"* ]]
}

@test "approval is per-exact-command — same >50-char prefix does NOT collide (T2)" {
	# CR fix #4: hash the FULL command, not a 50-char preview, so two commands
	# sharing a >50-char prefix get DISTINCT approval files. This test must
	# exercise the COLLISION directly: grant A, then fire B *while A's grant is
	# still present* — under the OLD 50-char-preview hash B would ride A's file
	# (rc 0); with the full-CMD hash B has a distinct hash so it stays refused
	# (rc 2). (Consuming A before firing B would make B fail on the empty dir
	# regardless of the hash — a false-green; silent-failure-hunter #180 r1.)
	local pfx="LINT_GATE_SKIP=1 echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	# A refused; grab its approval-file path from the labeled deny line (anchored
	# on the label, not a no-space glob, so a space in $TMPDIR can't truncate it).
	_run_hook "$pfx ONE"
	[ "$status" -eq 2 ]
	local fileA
	fileA=$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*approval-state path:[[:space:]]*//p' | head -1)
	[ -n "$fileA" ]
	# Grant A — but do NOT consume it yet.
	touch "$fileA"
	# B shares the >50-char prefix, differs in the tail → distinct full-CMD hash
	# → A's still-present grant must NOT let B through.
	_run_hook "$pfx TWO"
	[ "$status" -eq 2 ]
	local fileB
	fileB=$(printf '%s\n' "$output" | sed -nE 's/^[[:space:]]*approval-state path:[[:space:]]*//p' | head -1)
	# Pin hash-distinctness directly: A and B map to different approval files.
	[ -n "$fileB" ]
	[ "$(basename "$fileA")" != "$(basename "$fileB")" ]
	# A's grant is still present + is consumed-on-use (proves the grant was real).
	_run_hook "$pfx ONE"
	[ "$status" -eq 0 ]
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
	# Confirm it refused via the jq-missing branch, NOT the normal no-approval
	# deny — so rc 2 alone (shared by both) can't false-pass this test.
	[[ $output != *"BLOCKED by skip-env-approval-gate"* ]]
}

@test "skip var embedded mid-command (not a leading prefix) is not gated (T16)" {
	# security-review (#178 r1) confirmed the anchored `^` regex only matches
	# LEADING skip-env prefixes; a skip token embedded inside a quoted string or
	# a command-substitution is out of scope (not a top-level env assignment).
	# This documents that analysis so it isn't re-litigated.
	_run_hook 'echo "$(date): LINT_GATE_SKIP=1 is just text here"'
	[ "$status" -eq 0 ]
	# Plain quoted-string variant (no command-substitution) — also out of scope.
	_run_hook 'echo "this line merely mentions LINT_GATE_SKIP=1 in prose"'
	[ "$status" -eq 0 ]
}

@test "leading-whitespace skip prefix is detected — refused (T17, #224)" {
	# v0.31 #224: the old `^`-anchored SKIP_RE missed an indented prefix (heredoc
	# body, indented continuation, copy-paste). `^[[:space:]]*` now catches it so
	# it can't slip past the approval popup.
	_run_hook "  LINT_GATE_SKIP=1 echo hi"
	[ "$status" -eq 2 ]
	[[ $output == *"LINT_GATE_SKIP"* ]]
}

@test "export-prefixed skip is detected — refused (T18, #224)" {
	# v0.31 #224: `export LINT_GATE_SKIP=1; cmd` set the skip var for the gated
	# tool within the same Bash call while sailing past the popup.
	# `(export[[:space:]]+)?` now catches it; the skip var is BASH_REMATCH[4].
	_run_hook "export LINT_GATE_SKIP=1; echo hi"
	[ "$status" -eq 2 ]
	[[ $output == *"LINT_GATE_SKIP"* ]]
}

@test "export + benign env prefix before the skip is detected — refused (T19, #224 r2)" {
	# pr-test-analyzer r1: locks the BASH_REMATCH[4] capture on the combined
	# export + leading-assignment path (G1 export, G2 consumes FOO=1, G4 = skip).
	_run_hook "export FOO=1 LINT_GATE_SKIP=1 echo hi"
	[ "$status" -eq 2 ]
	[[ $output == *"LINT_GATE_SKIP"* ]]
}

@test "lowercase benign prefix before the skip is detected — refused (T20, #224 r2)" {
	# silent-failure-hunter r1: the old [A-Z_] leading-assignment class made a
	# lowercase benign prefix fail the WHOLE match → SKIP_VAR="" → silent exit-0
	# let-through. [A-Za-z_] closes that fail-open. This is the load-bearing case.
	_run_hook "foo=bar LINT_GATE_SKIP=1 echo hi"
	[ "$status" -eq 2 ]
	[[ $output == *"LINT_GATE_SKIP"* ]]
}

@test "indented BENIGN command (no skip var) is NOT gated (T21, #224 r2 negative)" {
	# pr-test-analyzer r1: prove the new `^[[:space:]]*` anchor did not over-broaden
	# — a leading-whitespace command with no top-level skip assignment stays allowed.
	_run_hook "  echo LINT_GATE_SKIP is only mentioned"
	[ "$status" -eq 0 ]
}
