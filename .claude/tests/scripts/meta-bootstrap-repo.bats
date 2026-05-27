#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
	TEST_TMP=$(mktemp -d -t meta-bootstrap-repo.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */meta-bootstrap-repo.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--target repo without target-dir exits 2" {
	run "$SCRIPT" --target repo
	[ "$status" -eq 2 ]
	[[ $output == *"requires a target directory"* ]]
}

@test "--target repo --verify-only against plugin's own repo passes" {
	run "$SCRIPT" --target repo --verify-only -- "$REPO_ROOT"
	[ "$status" -eq 0 ]
	[[ $output == *"verify clean"* ]]
}

@test "--target repo --verify-only against empty dir fails (no manifest files)" {
	mkdir -p "$TEST_TMP/empty"
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/empty"
	[ "$status" -eq 1 ]
}

@test "--target repo bootstraps an empty dir then verifies clean (no gh remote = no label-remote check)" {
	mkdir -p "$TEST_TMP/target"
	run "$SCRIPT" --target repo -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	[[ $output == *"bootstrapped + verified"* ]]
	# Sanity: at least the pre-commit-config.yaml was written.
	[ -f "$TEST_TMP/target/.pre-commit-config.yaml" ]
}

@test "--target repo --verify-only without target-dir exits 2 (same arg requirement)" {
	run "$SCRIPT" --target repo --verify-only
	[ "$status" -eq 2 ]
}
