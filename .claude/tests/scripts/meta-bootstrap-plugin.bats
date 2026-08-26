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
	# Make sure no test left plugin.json mutated.
	if [ -n "${PLUGIN_JSON_BACKUP:-}" ] && [ -f "$PLUGIN_JSON_BACKUP" ]; then
		cp "$PLUGIN_JSON_BACKUP" "$REPO_ROOT/.claude-plugin/plugin.json"
		PLUGIN_JSON_BACKUP=""
	fi
}

@test "--target plugin with positional arg exits 2" {
	run "$SCRIPT" --target plugin -- /tmp/stray
	[ "$status" -eq 2 ]
	[[ $output == *"accepts no positional arguments"* ]]
}

@test "--target plugin --verify-only against plugin's own repo passes" {
	cd "$REPO_ROOT" || return 1
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
	[[ $output == *"manifest + files verified"* ]]
}

@test "--target plugin --verify-only detects a malformed plugin.json version" {
	# Belt-and-suspenders: stash plugin.json + register the path in
	# PLUGIN_JSON_BACKUP so teardown() restores even on bats interruption.
	cd "$REPO_ROOT" || return 1
	PLUGIN_JSON_BACKUP="$TEST_TMP/plugin.json.bak"
	cp .claude-plugin/plugin.json "$PLUGIN_JSON_BACKUP"
	jq '.version = "not-a-version"' .claude-plugin/plugin.json >"$TEST_TMP/mutated.json"
	cp "$TEST_TMP/mutated.json" .claude-plugin/plugin.json
	run "$SCRIPT" --target plugin --verify-only
	cp "$PLUGIN_JSON_BACKUP" .claude-plugin/plugin.json
	PLUGIN_JSON_BACKUP=""
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

@test "--target plugin outside a git working tree fails cleanly" {
	cd "$TEST_TMP" || return 1
	run "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"must run inside a git working tree"* ]] || return 1
	# No leaked git stderr.
	[[ $output != *"fatal: not a git"* ]]
}

@test "json_fields: missing match/min field is reported as schema error" {
	local manifest="$TEST_TMP/manifest.yml"
	cat >"$manifest" <<'YAML'
schema_version: 1
targets:
  plugin:
    json_fields:
      - file: .claude-plugin/plugin.json
        jq: .version
YAML
	cd "$REPO_ROOT" || return 1
	run env META_BOOTSTRAP_MANIFEST="$manifest" "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"schema error"* ]]
}

@test "json_fields: legacy 'min' field still accepted for one schema cycle" {
	local manifest="$TEST_TMP/manifest.yml"
	cat >"$manifest" <<'YAML'
schema_version: 1
targets:
  plugin:
    json_fields:
      - file: .claude-plugin/plugin.json
        jq: .version
        min: '^[0-9]+\.[0-9]+\.[0-9]+'
YAML
	cd "$REPO_ROOT" || return 1
	run env META_BOOTSTRAP_MANIFEST="$manifest" "$SCRIPT" --target plugin --verify-only
	[ "$status" -eq 0 ]
}
