#!/usr/bin/env bats
# covers: scripts/install-hooks.sh
#
# Bats tests for scripts/install-hooks.sh. v0.9.3 (#47 sub-3) — initial
# bats coverage to satisfy bats-gate.sh + lift the PIPELINE_GATE_SKIP=1
# bootstrap need from #47 sub-1 / #49.
#
# These tests verify the script's public contract: existence + executable,
# --help/-h output structure, unknown-arg rejection, the non-git-repo
# precondition, and shellcheck cleanliness. Heavier integration tests
# (install → inspect → drift-detect → reinstall) land in a follow-up.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/install-hooks.sh"
}

@test "install-hooks.sh exists and is executable" {
	# Fail loud rather than skip-on-missing — a missing/non-executable
	# script is an infrastructure bug, not a "test environment without
	# the feature" skip. bats-gate counts skip() as silent regression rot.
	[ -x "$SCRIPT" ]
}

@test "--help shows structured usage with all 5 exit codes" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	# Exit code documentation must list 0/1/2/3/4 with distinct semantics.
	[[ $output == *"0  Install/check"* ]]
	[[ $output == *"1  --check detected DRIFT"* ]]
	[[ $output == *"2  Usage error"* ]]
	[[ $output == *"3  Required dependency missing"* ]]
	[[ $output == *"4  --check detected ABSENT"* ]]
}

@test "-h is an alias for --help" {
	run "$SCRIPT" -h
	[ "$status" -eq 0 ]
	[[ $output == *"Usage:"* ]]
}

@test "unknown arg exits 2 with usage" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg: --bogus"* ]]
	[[ $output == *"Usage:"* ]]
}

@test "script relocated outside a git repo exits 2 with layout-error message" {
	# Script derives REPO_ROOT from BASH_SOURCE/.. and verifies it's a
	# git repo. Running this repo's install-hooks.sh by absolute path
	# still resolves to THIS repo, so the test invokes a COPY in a
	# bats-managed tmpdir whose parent is NOT a git repo. bats auto-
	# cleans $BATS_TEST_TMPDIR per-test, so no manual rm needed.
	cp "$SCRIPT" "$BATS_TEST_TMPDIR/install-hooks.sh"
	chmod +x "$BATS_TEST_TMPDIR/install-hooks.sh"
	run "$BATS_TEST_TMPDIR/install-hooks.sh" --check
	[ "$status" -eq 2 ]
	[[ $output == *"not a git repo"* ]]
}

@test "--check on clean repo with no install reports ABSENT (rc=4)" {
	# Exercise the rc=4 ABSENT path — the most-hit error code for a new
	# contributor's first --check run. Spins up a fresh git repo in
	# BATS_TEST_TMPDIR (bats auto-cleans) and runs --check before install.
	repo="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$repo/scripts"
	(cd "$repo" && git init -q)
	cp "$SCRIPT" "$repo/scripts/install-hooks.sh"
	chmod +x "$repo/scripts/install-hooks.sh"
	run "$repo/scripts/install-hooks.sh" --check
	[ "$status" -eq 4 ]
	[[ $output == *"ABSENT"* ]]
}

@test "shellcheck clean (shellcheck assumed present in dev/CI env)" {
	# Don't skip-on-missing — pre-commit's shellcheck hook already runs
	# globally + would catch this. If a dev runs bats without shellcheck
	# installed, that's a setup issue worth surfacing, not silently skipping.
	# Explicit fail-with-diagnostic if missing so the cause is obvious.
	command -v shellcheck >/dev/null 2>&1 || {
		echo "shellcheck not found in PATH — required in dev/CI environment"
		return 1
	}
	run shellcheck "$SCRIPT"
	[ "$status" -eq 0 ]
}
