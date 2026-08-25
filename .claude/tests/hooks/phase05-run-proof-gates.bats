#!/usr/bin/env bats
# covers: hooks/phase0.5-before-cr.sh hooks/phase0.5-before-phase1.sh
#
# #2563 p1r1: phase0.5-run.jsonl doubles as the run-proof token for the
# CR-CLI and phase-1 launcher gates, and the new errored-emit row means
# "this round's findings were NOT emitted" — before this suite, ANY row
# for HEAD (including a pure failure marker) satisfied the gates, so a
# FAILED phase 0.5 unlocked downstream review for a sha whose prefilter
# produced nothing. Contract pinned here: errored-* rows never count as
# run-proof; ok and skipped-* rows do (a documented skip IS a completed
# run).

setup() {
	CR_HOOK="${BATS_TEST_DIRNAME}/../../../hooks/phase0.5-before-cr.sh"
	P1_HOOK="${BATS_TEST_DIRNAME}/../../../hooks/phase0.5-before-phase1.sh"
	[ -f "$CR_HOOK" ] && [ -f "$P1_HOOK" ]
	TEST_TMP=$(mktemp -d -t p05gates.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m seed
	) || return 1
	SHA=$(cd "$TEST_TMP" && git rev-parse HEAD)
	mkdir -p "$TEST_TMP/.claude/logs"
	LOG="$TEST_TMP/.claude/logs/phase0.5-run.jsonl"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

_row() { # $1=status  $2=agent
	printf '{"ts":"2026-01-01T00:00:00Z","sha":"%s","phase":"0.5","agent":"%s","findings":0,"status":"%s"}\n' \
		"$SHA" "${2:-<all>}" "$1" >>"$LOG"
}

_run_cr_gate() {
	run bash -c "cd '$TEST_TMP' && printf '%s' '{\"tool_input\":{\"command\":\"coderabbit review\"}}' | bash '$CR_HOOK'"
}

_run_p1_gate() {
	run bash -c "cd '$TEST_TMP' && printf '%s' '{\"tool_input\":{\"command\":\".claude/hooks/phase1-launcher.sh 1\"}}' | bash '$P1_HOOK'"
}

@test "before-cr: an errored-emit-ONLY log is NOT run-proof (deny)" {
	_row errored-emit
	_run_cr_gate
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	[[ $output == *"no run logged"* ]]
}

@test "before-cr: per-agent ok rows WITHOUT a terminal are NOT run-proof (p2r1 deny)" {
	# The p2r1 CR major: ok rows are written BEFORE emission, so a crashed
	# emit leaves them behind — they alone must never unlock downstream.
	_row ok code-reviewer
	_row ok silent-failure-hunter
	_run_cr_gate
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "before-cr: the TERMINAL emitted row IS run-proof (pass), even beside errored rows" {
	_row errored code-reviewer
	_row ok code-reviewer
	_row emitted
	_run_cr_gate
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "before-cr: a skipped-* row counts as a completed run (pass)" {
	_row skipped-no-copilot-helper
	_run_cr_gate
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "before-phase1: an errored-emit-ONLY log is NOT run-proof (deny)" {
	_row errored-emit
	_run_p1_gate
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "before-phase1: ok rows without a terminal are NOT run-proof (p2r1 deny)" {
	_row ok code-reviewer
	_run_p1_gate
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "before-phase1: the TERMINAL emitted row IS run-proof (pass)" {
	_row ok code-reviewer
	_row emitted
	_run_p1_gate
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}
