#!/usr/bin/env bats
# covers: hooks/ship-cycle-director-gate.sh
#
# Tests for _cmd_starts_with regex (v0.27.0 #173 Layer 4).
# Exercises the bash-regex helper directly via a local copy of the
# function definition.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/ship-cycle-director-gate.sh"
	[ -f "$HOOK" ]
}

_cmd_starts_with() {
	local cmd=$1 needle=$2
	[[ $cmd =~ ^([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*$needle ]]
}

@test "matches bare needle at command start" {
	run _cmd_starts_with "gh pr merge 164" "gh pr merge"
	[ "$status" -eq 0 ]
}

@test "matches with env-var prefix" {
	run _cmd_starts_with "APPROVE=1 gh pr merge 164" "gh pr merge"
	[ "$status" -eq 0 ]
}

@test "REGRESSION: heredoc with interior needle does NOT match" {
	# v0.27.1 #173 Phase 1 r1 caught this: grep -qE ^ matches start-of-LINE,
	# letting `cat <<EOF...gh pr merge...EOF` trip the gate as a false
	# positive. Bash [[ =~ ]] uses string-anchor and rejects the case.
	cmd=$'cat <<EOF\ngh pr merge 164\nEOF'
	run _cmd_starts_with "$cmd" "gh pr merge"
	[ "$status" -ne 0 ]
}

@test "echo-content does NOT match" {
	run _cmd_starts_with "echo 'gh pr merge 164'" "gh pr merge"
	[ "$status" -ne 0 ]
}

@test "grep alternation does NOT match" {
	run _cmd_starts_with "grep -E 'X|gh pr merge' somefile" "gh pr merge"
	[ "$status" -ne 0 ]
}

@test "different command does NOT match" {
	run _cmd_starts_with "git push origin main" "gh pr merge"
	[ "$status" -ne 0 ]
}
