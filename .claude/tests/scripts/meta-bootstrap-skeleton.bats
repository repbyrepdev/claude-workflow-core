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
	[[ $output == *"machine"* ]] || return 1
	[[ $output == *"repo"* ]] || return 1
	[[ $output == *"plugin"* ]] || return 1
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

@test "--target machine is implemented (rc=0 on verify-only)" {
	# As of #110 machine is wired. Detailed coverage lives in
	# meta-bootstrap-machine.bats. Use --verify-only so the test doesn't
	# trigger an actual brew install.
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	[[ $output != *"not yet implemented"* ]] || return 1
	[[ $output != *"not yet wired"* ]] || return 1
	[[ $output == *"running target: machine"* ]]
}

@test "--target machine reaches the manifest-driven verify path (rc=0)" {
	# Marker log line emitted only by the new dispatcher; absence would
	# mean either the skeleton stub came back or argparse short-circuited.
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	[[ $output == *"machine manifest"* ]]
}

@test "--target plugin reaches the manifest+files verify path (rc=0)" {
	# Plugin dispatcher emits both the manifest-fields log and the
	# bootstrap-repo.sh delegation log. Asserting both pins the
	# two-step verify shape against silent collapse to one step.
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	[[ $output == *"plugin manifest fields"* ]] || return 1
	[[ $output == *"bootstrap-manifest.yml"* ]]
}

@test "--verify-only is accepted for every target with the right concrete exit code" {
	# machine + plugin: rc=0 (verify pass — both work against the tracked
	# manifest with no host coupling beyond yq).
	for t in machine plugin; do
		run "$SCRIPT" --target "$t" --verify-only
		[ "$status" -eq 0 ]
		[[ $output != *"not yet wired"* ]] || return 1
	done
	# feature-branch: env-coupled (git state, gh labels) — pin wiring
	# only, not the success rc. Detailed coverage in feature-branch.bats.
	run "$SCRIPT" --target feature-branch --verify-only
	[ "$status" -ne 69 ]
	[[ $output != *"not yet wired"* ]] || return 1
	# repo: --verify-only without target-dir is rc=2 (argparse), NOT 69.
	run "$SCRIPT" --target repo --verify-only
	[ "$status" -eq 2 ]
	[[ $output != *"not yet wired"* ]]
}

@test "--target repo is implemented (rc=2 without target-dir, not rc=69)" {
	# As of #111 repo is wired. Detailed coverage in meta-bootstrap-repo.bats.
	# Without a target-dir, rc=2 (argparse) — not rc=69 (unimplemented).
	run "$SCRIPT" --target repo
	[ "$status" -eq 2 ]
	[[ $output != *"not yet implemented"* ]]
}

@test "--target plugin is implemented (rc=0 on verify-only)" {
	# As of #112 plugin is wired. Detailed coverage in meta-bootstrap-plugin.bats.
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	[[ $output != *"not yet implemented"* ]]
}

@test "--target feature-branch is implemented (no rc=69 / not-yet-wired)" {
	# feature-branch was wired as of #113. Detailed coverage lives in
	# meta-bootstrap-feature-branch.bats. Skeleton coverage validates
	# WIRING (no rc=69, no stub strings) — not repo-specific success,
	# which would couple to current git state (detached HEAD, missing
	# hook, unlabeled issue would all flip rc to 1 even though the
	# dispatcher is wired correctly).
	run "$SCRIPT" --target feature-branch
	[ "$status" -ne 69 ]
	[[ $output != *"not yet implemented"* ]] || return 1
	[[ $output != *"not yet wired"* ]]
}

@test "--verify-only --target X order accepted (flag order independence)" {
	# Flag order should not affect parsing; --verify-only before --target
	# must still set VERIFY_ONLY=1 before dispatch. plugin --verify-only
	# returns rc=0 when the plugin manifest + files verify clean.
	run "$SCRIPT" --verify-only --target plugin
	[ "$status" -eq 0 ]
	[[ $output == *"manifest + files verified"* ]]
}

@test "unknown flag exits 2" {
	run "$SCRIPT" --target machine --bogus-flag
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}

@test "args after -- are forwarded into EXTRA_ARGS (verified via dispatch reach)" {
	# Dispatchers reject extra positional args (rc=2 with the per-target
	# error message). Pass --foo bar after `--` and assert we hit dispatch
	# (not argparse), which is signalled by "running target: machine".
	run "$SCRIPT" --target machine -- --foo bar
	[ "$status" -eq 2 ]
	[[ $output == *"running target: machine"* ]] || return 1
	[[ $output == *"accepts no positional arguments"* ]]
}

@test "bare positional before --target is forwarded into EXTRA_ARGS" {
	# Lenient parsing: positional args without `--` separator also go
	# into EXTRA_ARGS. machine rejects them via its arg-count guard.
	run "$SCRIPT" stray --target machine
	[ "$status" -eq 2 ]
	[[ $output == *"accepts no positional arguments"* ]]
}
