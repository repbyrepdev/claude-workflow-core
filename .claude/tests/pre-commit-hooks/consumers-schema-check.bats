#!/usr/bin/env bats
# covers: pre-commit-hooks/consumers-schema-check.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	HOOK="${REPO_ROOT}/pre-commit-hooks/consumers-schema-check.sh"
	TEST_TMP=$(mktemp -d -t cons-schema.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .github pre-commit-hooks
		cp "$HOOK" pre-commit-hooks/consumers-schema-check.sh
		chmod +x pre-commit-hooks/consumers-schema-check.sh
		git commit --allow-empty -q -m init
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cons-schema.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_valid_consumers() {
	cat >"$TEST_TMP/.github/consumers.yml" <<'YAML'
schema_version: 1
consumers:
  - name: media-server
    repo: repbyrepdev/plex_arr_media_stack
    local_path: ~/media-server
    pinned_version: "0.8.5"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-04-21
    contact: "@damien"
    notes: "Homelab consumer"
YAML
}

# Block-scalar notes match the production .github/consumers.yml shape.
# Phase 1 comment-analyzer #12: minimal fixture doesn't exercise block-
# scalar form; this helper does for at least one test.
_write_valid_consumers_block_scalar() {
	cat >"$TEST_TMP/.github/consumers.yml" <<'YAML'
schema_version: 1
consumers:
  - name: media-server
    repo: repbyrepdev/plex_arr_media_stack
    local_path: ~/media-server
    pinned_version: "0.8.5"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-04-21
    contact: "@damien"
    notes: |
      Multi-line block-scalar notes
      with several lines of context.
YAML
}

@test "passes when consumers.yml not staged" {
	cd "$TEST_TMP" || return 1
	echo "unrelated" >README.md
	git add README.md
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid schema_version:1 consumers.yml" {
	cd "$TEST_TMP" || return 1
	_write_valid_consumers
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid consumers.yml with block-scalar notes" {
	cd "$TEST_TMP" || return 1
	_write_valid_consumers_block_scalar
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "fails on wrong schema_version" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 99
consumers:
  - name: x
    repo: a/b
    local_path: ~/x
    pinned_version: "0.1.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-01
    contact: "@x"
    notes: "x"
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"schema_version must equal 1"* ]]
}

@test "fails on missing required field" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: x
    repo: a/b
    pinned_version: "0.1.0"
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"missing or null"* ]]
}

@test "fails on duplicate consumer name" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: foo
    repo: a/b
    local_path: ~/x
    pinned_version: "0.1.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-01
    contact: "@x"
    notes: "x"
  - name: foo
    repo: a/c
    local_path: ~/y
    pinned_version: "0.2.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-02
    contact: "@x"
    notes: "y"
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"duplicate consumer name: foo"* ]]
}

@test "fails on malformed repo coordinate" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: x
    repo: "not-a-coordinate"
    local_path: ~/x
    pinned_version: "0.1.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-01
    contact: "@x"
    notes: "x"
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be owner/name format"* ]]
}

@test "fails on non-semver pinned_version" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: x
    repo: a/b
    local_path: ~/x
    pinned_version: "latest"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: 2026-01-01
    contact: "@x"
    notes: "x"
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be X.Y.Z semver"* ]]
}

@test "fails on malformed bootstrap_date" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers:
  - name: x
    repo: a/b
    local_path: ~/x
    pinned_version: "0.1.0"
    overrides_file: .claude/local-overrides.yml
    bootstrap_date: "April 2026"
    contact: "@x"
    notes: "x"
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be YYYY-MM-DD"* ]]
}

# Phase 1 type-design-analyzer #9: registry deletion silently passed
# under diff-filter=ACMR. Acceptance #4 says cascade tools depend on
# the file existing — block deletion at the gate.
@test "fails on staged deletion of consumers.yml (registry SSOT)" {
	cd "$TEST_TMP" || return 1
	_write_valid_consumers
	git add .github/consumers.yml
	git commit -q -m "add consumers.yml"
	git rm -q .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"staged for DELETION"* ]]
}

# Phase 1 silent-failure-hunter SF-001/002/003: a corrupt YAML must
# exit 2 (parse failure / precondition error), NOT 1 (schema violation).
# Distinguishes "operator wrote bad content" from "parser can't read it".
@test "fails with exit 2 on corrupt YAML (yq parse failure)" {
	cd "$TEST_TMP" || return 1
	# Unclosed bracket — guarantees yq parse failure.
	cat >.github/consumers.yml <<'YAML'
schema_version: 1
consumers: [
  - name: incomplete
YAML
	git add .github/consumers.yml
	run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"yq failed parsing"* ]]
}

@test "bypass env CONSUMERS_SCHEMA_SKIP=1 lets bad schema through" {
	cd "$TEST_TMP" || return 1
	cat >.github/consumers.yml <<'YAML'
schema_version: 99
consumers:
  - name: x
YAML
	git add .github/consumers.yml
	CONSUMERS_SCHEMA_SKIP=1 run pre-commit-hooks/consumers-schema-check.sh
	[ "$status" -eq 0 ]
	[[ $output == *"CONSUMERS_SCHEMA_SKIP"* ]]
}
