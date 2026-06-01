#!/usr/bin/env bats
# covers: _lib/ship-cycle-directives.sh
#
# v0.32.12 (#283): the ship-pr-cycle next-step directive emitter. Locks:
# _emit_stage_directive prints the directive to stdout; CALLS hook_ack_append
# (the un-skippable, Read-to-clear ack-pending) when NOT in a resume auto-walk;
# SUPPRESSES that call under SHIP_PR_IN_RESUME=1 (stdout still prints); and
# no-ops safely on an unknown label (never aborts the orchestrator).
#
# The hook-ack primitives are STUBBED so this tests THIS lib's behavior in
# isolation — no real .claude sentinel pollution (hook-ack.sh has its own tests,
# and it resolves the sentinel via git-toplevel, not REPO_ROOT).

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/ship-cycle-directives.sh"
	[ -f "$LIB" ]
	TEST_TMP=$(mktemp -d -t shipdir.XXXXXX) || return 1
	CALLS="$TEST_TMP/append-calls.log"
	: >"$CALLS"
	# Stubs: command -v finds these, so _emit_stage_directive calls them.
	# shellcheck disable=SC2317,SC2329 # invoked indirectly by the sourced lib (command -v + call)
	hook_ack_diagnostic_write() { printf '%s/diag-%s.txt\n' "$TEST_TMP" "${2:-x}"; }
	# shellcheck disable=SC2317,SC2329 # invoked indirectly by the sourced lib
	hook_ack_append() { printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" >>"$CALLS"; }
	# shellcheck source=../../../_lib/ship-cycle-directives.sh
	. "$LIB"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */shipdir.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "two-step-phase1 directive prints to stdout (status 0)" {
	run _emit_stage_directive two-step-phase1
	[ "$status" -eq 0 ]
	[[ $output == *"do NOT skip"* ]]
	[[ $output == *"AGAIN"* ]]
	[[ $output == *"two-step"* ]]
}

@test "calls hook_ack_append with the label (not in resume)" {
	run _emit_stage_directive two-step-phase1
	[ "$status" -eq 0 ]
	grep -q 'ship-pr-cycle-next' "$CALLS"
	grep -q 'two-step-phase1' "$CALLS"
}

@test "SHIP_PR_IN_RESUME=1 suppresses the ack-pending (stdout still prints)" {
	export SHIP_PR_IN_RESUME=1
	run _emit_stage_directive two-step-phase1
	[ "$status" -eq 0 ]
	[[ $output == *"do NOT skip"* ]] # stdout still emitted during resume
	[ ! -s "$CALLS" ]                # hook_ack_append NOT called
}

@test "unknown label → warns, status 0, no ack-pending" {
	run _emit_stage_directive bogus-label
	[ "$status" -eq 0 ]
	[[ $output == *"unknown label"* ]]
	[ ! -s "$CALLS" ]
}
