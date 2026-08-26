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

# Phase 1 code-reviewer + type-design-analyzer dup: --help must NOT
# leak loader-framework directives (event:, auto-register:) as
# user-facing help text. Awk filter explicitly skips them.
@test "--help does not leak loader frontmatter directives" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output != *"event: none"* ]] || return 1
	[[ $output != *"auto-register: false"* ]]
}

@test "text format lists both consumers" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh
	[ "$status" -eq 0 ]
	[[ $output == *"alpha"* ]] || return 1
	[[ $output == *"beta"* ]] || return 1
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

# Both pinned versions (0.8.5, 0.18.1) sort below 1.0.0 under sort -V.
# Verify the --behind header path renders + both consumers listed.
@test "--behind 1.0.0 returns both (both pre-1.0)" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh --behind 1.0.0
	[ "$status" -eq 0 ]
	[[ $output == *"behind v1.0.0"* ]] || return 1
	[[ $output == *"alpha"* ]] || return 1
	[[ $output == *"beta"* ]]
}

@test "--behind 0.10.0 returns only alpha" {
	cd "$TEST_TMP" || return 1
	run scripts/list-consumers.sh --behind 0.10.0
	[ "$status" -eq 0 ]
	[[ $output == *"alpha"* ]] || return 1
	[[ $output != *"beta"* ]]
}

# Phase 1 code-reviewer + type-design-analyzer dup: --behind must
# reject non-semver args. Prior behavior treated `--behind foo` as a
# version that sorts after every numeric pin (digits < letters under
# sort -V), reporting every consumer as "behind vfoo".
@test "--behind rejects non-semver argument" {
	run "$SCRIPT" --behind "not-a-version"
	[ "$status" -eq 2 ]
	[[ $output == *"requires X.Y.Z semver"* ]]
}

@test "--behind rejects v-prefixed version" {
	run "$SCRIPT" --behind "v1.0.0"
	[ "$status" -eq 2 ]
	[[ $output == *"requires X.Y.Z semver"* ]]
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
	[[ $output == *"not supported"* ]]
}

# Phase 1 code-reviewer #2: .consumers: null must exit 2 with a clear
# message — not throw "Cannot iterate over null" under set -e.
@test "null .consumers exits 2 cleanly" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
YAML
	run scripts/list-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"null or empty"* ]]
}

# CR-in-CI r1: non-array .consumers (object/string) must exit 2 with
# clear array-required message, not "Cannot iterate over object" from
# jq under set -e.
@test "object .consumers exits 2 with array-required message" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  some_key: some_value
YAML
	run scripts/list-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"must be an array"* ]]
}

@test "string .consumers exits 2 with array-required message" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers: "not-a-list"
YAML
	run scripts/list-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"must be an array"* ]]
}

# Phase 1 silent-failure-hunter SF-005: corrupt YAML must exit 2 with
# the yq parse error surfaced — NOT a misleading "schema_version not
# supported" message.
@test "corrupt YAML exits 2 with yq error surfaced" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers: [
  - name: incomplete
YAML
	run scripts/list-consumers.sh
	[ "$status" -eq 2 ]
	[[ $output == *"yq failed parsing"* ]]
}

@test "unknown arg exits 2" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown arg"* ]]
}
