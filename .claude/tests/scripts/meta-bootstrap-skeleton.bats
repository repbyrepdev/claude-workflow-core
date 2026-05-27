#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
}

@test "--help prints usage with all 4 targets + exits 0" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"machine"* ]]
	[[ $output == *"repo"* ]]
	[[ $output == *"plugin"* ]]
	[[ $output == *"feature-branch"* ]]
}

@test "missing --target exits 2 with usage" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"--target is required"* ]]
}

@test "--target bogus exits 2 with vocab" {
	run "$SCRIPT" --target bogus
	[ "$status" -eq 2 ]
	[[ $output == *"invalid --target"* ]]
}

@test "--target machine returns rc=3 (unimplemented) with sub-issue pointer" {
	run "$SCRIPT" --target machine
	[ "$status" -eq 3 ]
	[[ $output == *"not yet implemented"* ]]
	[[ $output == *"#110"* ]]
}

@test "--target repo returns rc=3 with sub-issue #111" {
	run "$SCRIPT" --target repo
	[ "$status" -eq 3 ]
	[[ $output == *"#111"* ]]
}

@test "--target plugin returns rc=3 with sub-issue #112" {
	run "$SCRIPT" --target plugin
	[ "$status" -eq 3 ]
	[[ $output == *"#112"* ]]
}

@test "--target feature-branch returns rc=3 with sub-issue #113" {
	run "$SCRIPT" --target feature-branch
	[ "$status" -eq 3 ]
	[[ $output == *"#113"* ]]
}

@test "--verify-only is accepted alongside --target" {
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 3 ]
	[[ $output == *"verify-only mode: machine"* ]]
}

@test "unknown flag exits 2" {
	run "$SCRIPT" --target machine --bogus-flag
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}
