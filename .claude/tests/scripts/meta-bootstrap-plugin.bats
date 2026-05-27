#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh scripts/meta-bootstrap-manifest.yml

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
	TEST_TMP=$(mktemp -d -t meta-bootstrap-plugin.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */meta-bootstrap-plugin.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--target plugin with positional arg exits 2" {
	run "$SCRIPT" --target plugin -- /tmp/stray
	[ "$status" -eq 2 ]
	[[ $output == *"accepts no positional arguments"* ]]
}

@test "--target plugin --verify-only against plugin's own repo passes" {
	# The plugin manifest declares a SemVer version field requirement;
	# the plugin's own checkout satisfies it.
	cd "$REPO_ROOT" || return 1
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	[[ $output == *"manifest + files verified"* ]]
}

@test "--target plugin --verify-only detects a malformed plugin.json version" {
	# Mutate plugin.json's version to something non-SemVer, verify-only
	# must fail with the json_fields finding, then restore.
	cd "$REPO_ROOT" || return 1
	cp .claude-plugin/plugin.json "$TEST_TMP/plugin.json.bak"
	jq '.version = "not-a-version"' .claude-plugin/plugin.json >"$TEST_TMP/mutated.json"
	cp "$TEST_TMP/mutated.json" .claude-plugin/plugin.json
	run "$SCRIPT" --target plugin --verify-only
	# Restore BEFORE assertions so a failure can't leave the repo dirty.
	cp "$TEST_TMP/plugin.json.bak" .claude-plugin/plugin.json
	[ "$status" -eq 1 ]
	[[ $output == *"does not match"* ]]
}

@test "--target plugin --verify-only is idempotent (re-run is a no-op)" {
	cd "$REPO_ROOT" || return 1
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	first_output=$output
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	[ "$output" = "$first_output" ]
}

@test "--target plugin (no --verify-only) is equivalent to verify-only (no mutation surface)" {
	cd "$REPO_ROOT" || return 1
	run "$SCRIPT" --target plugin
	[ "$status" -eq 0 ]
	[[ $output == *"manifest + files verified"* ]]
}
