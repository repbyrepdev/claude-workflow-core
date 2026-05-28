#!/usr/bin/env bats
# covers: scripts/list-consumers.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/list-consumers.sh"
	TEST_TMP=$(mktemp -d -t list-cons.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		mkdir -p .github scripts
		cp "$SCRIPT" scripts/list-consumers.sh
		chmod +x scripts/list-consumers.sh
		cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: alpha
    repo: org/alpha
    local_path: ~/alpha
    pinned_version: "0.8.5"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-15
    contact: "@dev"
    notes: "first"
  - name: beta
    repo: org/beta
    local_path: ~/beta
    pinned_version: "0.18.1"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-02-20
    contact: "@dev"
    notes: "second"
YAML
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */list-cons.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--help emits usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage"* ]]
}

@test "text format lists both consumers" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh
	[ "$status" -eq 0 ]
	[[ $output == *"alpha"* ]]
	[[ $output == *"beta"* ]]
	[[ $output == *"org/alpha"* ]]
}

@test "--json emits valid JSON array of length 2" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh --json
	[ "$status" -eq 0 ]
	echo "$output" | jq -e 'type == "array"'
	echo "$output" | jq -e 'length == 2'
	echo "$output" | jq -e '.[0].name == "alpha"'
}

@test "--behind 1.0.0 returns both (both pre-1.0)" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh --behind 1.0.0
	[ "$status" -eq 0 ]
	[[ $output == *"alpha"* ]]
	[[ $output == *"beta"* ]]
}

@test "--behind 0.10.0 returns only alpha" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh --behind 0.10.0
	[ "$status" -eq 0 ]
	[[ $output == *"alpha"* ]]
	[[ $output != *"beta"* ]]
}

@test "missing consumers.yml exits 2" {
	cd "$TEST_TMP" || return 1
	rm .github/consumers.yml
	run scripts/list-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"missing"* ]]
}

@test "wrong schema_version exits 2" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 99
consumers: []
YAML
	run scripts/list-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"schema_version=99 not supported"* ]]
}

@test "unknown arg exits 2" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}
