#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-epic.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164 # teardown best-effort; rm guarded below
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-epic.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "epic with no args exits 2 + writes usage to stderr" {
	run "$SCRIPT" epic
	[ "$status" -eq 2 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]]
	[[ $output == *"trigger <num>"* ]]
	[[ $output == *"parse <num>"* ]]
}

@test "epic --help exits 0 (convention) + writes usage to stdout" {
	run "$SCRIPT" epic --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]]
}

@test "epic -h exits 0 (alias for --help)" {
	run "$SCRIPT" epic -h
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: ship-pr-cycle.sh epic"* ]]
}

@test "epic help mentions PARALLEL workflow doctrine + APPROVE=1 gate" {
	run "$SCRIPT" epic --help
	[ "$status" -eq 0 ]
	# Workflow rooted in operator-driven brainstorm (not auto-fired into ship cycle)
	[[ $output == *"brainstorm.yml"* ]]
	# Gate matches cr-plan's APPROVE=1 requirement (parse step)
	[[ $output == *"APPROVE=1"* ]]
}

@test "epic dispatch references cr-plan as the underlying skill" {
	run "$SCRIPT" epic --help
	[ "$status" -eq 0 ]
	[[ $output == *"skills/cr-plan/run.sh"* ]]
}

@test "epic appears in top-level _usage subcommand listing" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"epic"* ]]
	[[ $output == *"cr-plan a brainstorm artifact"* ]]
}

@test "unknown subcommand error message lists epic" {
	run "$SCRIPT" not-a-real-subcommand
	[ "$status" -eq 2 ]
	[[ $output == *"epic"* ]]
}
