#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh scripts/meta-bootstrap-manifest.yml
#
# Idempotency contract: every target's --verify-only path must be
# byte-identical across runs (no timestamps, no random IDs, no
# accumulating state). Each target also has its own per-flow bats
# (meta-bootstrap-{machine,repo,plugin,feature-branch}.bats); this
# file is the cross-target SSOT for the no-side-effects invariant.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
	TEST_TMP=$(mktemp -d -t meta-bootstrap-idem.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */meta-bootstrap-idem.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "machine --verify-only is identical across two consecutive runs" {
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	first=$output
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	[ "$output" = "$first" ]
}

@test "plugin --verify-only is identical across two consecutive runs" {
	cd "$REPO_ROOT" || return 1
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	first=$output
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	[ "$output" = "$first" ]
}

@test "repo full bootstrap → re-bootstrap is identical (no diff in target tree)" {
	mkdir -p "$TEST_TMP/target"
	run "$SCRIPT" --target repo -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	first_snapshot=$(cd "$TEST_TMP/target" && find . -type f \! -path './.git/*' -exec shasum {} \; | sort)
	run "$SCRIPT" --target repo -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	second_snapshot=$(cd "$TEST_TMP/target" && find . -type f \! -path './.git/*' -exec shasum {} \; | sort)
	[ "$first_snapshot" = "$second_snapshot" ]
}

@test "repo --verify-only on bootstrapped tree is identical across runs" {
	mkdir -p "$TEST_TMP/target"
	"$SCRIPT" --target repo -- "$TEST_TMP/target" >/dev/null 2>&1
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	first=$output
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	[ "$output" = "$first" ]
}

@test "repo: re-bootstrap after deleting a single file restores it (recovery path)" {
	mkdir -p "$TEST_TMP/target"
	"$SCRIPT" --target repo -- "$TEST_TMP/target" >/dev/null 2>&1
	rm "$TEST_TMP/target/.pre-commit-config.yaml"
	run "$SCRIPT" --target repo -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	[ -f "$TEST_TMP/target/.pre-commit-config.yaml" ]
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
}
