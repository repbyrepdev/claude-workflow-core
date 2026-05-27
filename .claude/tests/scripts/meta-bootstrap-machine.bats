#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh scripts/meta-bootstrap-manifest.yml

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
	MANIFEST="${REPO_ROOT}/scripts/meta-bootstrap-manifest.yml"
	TEST_TMP=$(mktemp -d -t meta-bootstrap-machine.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */meta-bootstrap-machine.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--target machine with positional arg exits 2" {
	run "$SCRIPT" --target machine -- /tmp/stray
	[ "$status" -eq 2 ]
	[[ $output == *"accepts no positional arguments"* ]]
}

@test "--target machine --verify-only against this machine passes the manifest" {
	# This machine ran bootstrap-machine.sh historically; the brew + commands
	# rules in the manifest should already be satisfied. If they aren't,
	# the manifest itself drifted vs reality — that's a real failure.
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	[[ $output == *"all manifest rules pass"* ]]
}

@test "--target machine --verify-only emits a remediation line per failure" {
	# Stash a temp manifest with a guaranteed-missing brew package + command.
	# Override the manifest path by symlinking a temp copy in place.
	cp "$MANIFEST" "$TEST_TMP/orig-manifest.yml"
	cat >"$TEST_TMP/test-manifest.yml" <<'YAML'
schema_version: 1
targets:
  machine:
    brew_packages:
      - definitely-not-a-real-package-xyz789
    commands:
      - definitely-not-a-real-command-abc456
YAML
	cp "$TEST_TMP/test-manifest.yml" "$MANIFEST"
	run "$SCRIPT" --target machine --verify-only
	# Restore manifest BEFORE assertions so a failure can't poison other tests.
	cp "$TEST_TMP/orig-manifest.yml" "$MANIFEST"
	[ "$status" -eq 1 ]
	[[ $output == *"brew package missing: definitely-not-a-real-package-xyz789"* ]]
	[[ $output == *"command not on PATH: definitely-not-a-real-command-abc456"* ]]
}

@test "--target machine --verify-only is idempotent (re-run is a no-op)" {
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	first_output=$output
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	# Output text is identical (modulo timestamps — none in our log format).
	[ "$output" = "$first_output" ]
}

@test "manifest missing → verify-only fails with a clear error" {
	# Temporarily move the manifest aside.
	mv "$MANIFEST" "$TEST_TMP/manifest-backup.yml"
	run "$SCRIPT" --target machine --verify-only
	mv "$TEST_TMP/manifest-backup.yml" "$MANIFEST"
	[ "$status" -eq 1 ]
	[[ $output == *"manifest not found"* ]]
}
