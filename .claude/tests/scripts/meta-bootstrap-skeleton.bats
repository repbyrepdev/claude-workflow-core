#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
}

@test "script is executable" {
	[ -x "$SCRIPT" ]
}

@test "shebang is bash" {
	run head -1 "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == "#!/bin/bash" ]] || [[ $output == "#!/usr/bin/env bash" ]]
}

@test "--help prints usage with all 4 targets + exits 0" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"machine"* ]]
	[[ $output == *"repo"* ]]
	[[ $output == *"plugin"* ]]
	[[ $output == *"feature-branch"* ]]
}

@test "-h short form is supported" {
	run "$SCRIPT" -h
	[ "$status" -eq 0 ]
	[[ $output == *"usage:"* ]]
}

@test "missing --target exits 2 with usage" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"--target is required"* ]]
}

@test "--target with no value exits 2" {
	run "$SCRIPT" --target
	[ "$status" -eq 2 ]
	[[ $output == *"requires a value"* ]]
}

@test "--target bogus exits 2 with vocab" {
	run "$SCRIPT" --target bogus
	[ "$status" -eq 2 ]
	[[ $output == *"invalid --target"* ]]
}

@test "--target machine returns rc=69 (unimplemented)" {
	run "$SCRIPT" --target machine
	[ "$status" -eq 69 ]
	[[ $output == *"not yet implemented"* ]]
	[[ $output == *"#78"* ]]
}

@test "--target repo returns rc=69 with tracking pointer" {
	run "$SCRIPT" --target repo
	[ "$status" -eq 69 ]
	[[ $output == *"repo flow"* ]]
}

@test "--target plugin returns rc=69 with tracking pointer" {
	run "$SCRIPT" --target plugin
	[ "$status" -eq 69 ]
	[[ $output == *"plugin flow"* ]]
}

@test "--target feature-branch returns rc=69 with tracking pointer" {
	run "$SCRIPT" --target feature-branch
	[ "$status" -eq 69 ]
	[[ $output == *"feature-branch flow"* ]]
}

@test "--verify-only refuses with rc=69 (not silently dispatched)" {
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 69 ]
	[[ $output == *"--verify-only not yet wired"* ]]
	# Must NOT have logged "running target" — that's the mutating path.
	[[ $output != *"running target"* ]]
}

@test "--verify-only --target X order accepted (flag order independence)" {
	run "$SCRIPT" --verify-only --target machine
	[ "$status" -eq 69 ]
	[[ $output == *"--verify-only not yet wired"* ]]
}

@test "unknown flag exits 2" {
	run "$SCRIPT" --target machine --bogus-flag
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}

@test "args after -- are forwarded into EXTRA_ARGS (verified via dispatch reach)" {
	# The skeleton dispatchers ignore EXTRA_ARGS but must still reach
	# dispatch (not exit at argparse). Pass --foo bar after `--` and
	# assert we hit the rc=69 unimplemented branch (not rc=2 unknown
	# flag).
	run "$SCRIPT" --target machine -- --foo bar
	[ "$status" -eq 69 ]
	[[ $output == *"running target: machine"* ]]
}

@test "bare positional before --target is forwarded into EXTRA_ARGS" {
	# Lenient parsing: positional args without `--` separator also go
	# into EXTRA_ARGS. Documented in script header.
	run "$SCRIPT" stray --target machine
	[ "$status" -eq 69 ]
}
