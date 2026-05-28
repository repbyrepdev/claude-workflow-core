#!/usr/bin/env bats
# covers: pre-commit-hooks/local-overrides-schema-check.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	HOOK="${REPO_ROOT}/pre-commit-hooks/local-overrides-schema-check.sh"
	TEST_TMP=$(mktemp -d -t lo-schema.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .claude pre-commit-hooks
		cp "$HOOK" pre-commit-hooks/local-overrides-schema-check.sh
		chmod +x pre-commit-hooks/local-overrides-schema-check.sh
		git commit --allow-empty -q -m init
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */lo-schema.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_valid_empty() {
	cat >"$TEST_TMP/.claude/local-overrides.yml" <<'YAML'
schema_version: 1
overrides: []
YAML
}

_write_valid_one_domain_extension() {
	cat >"$TEST_TMP/.claude/local-overrides.yml" <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/check-compose-envfile.sh
    category: domain-extension
    reason: "Homelab-specific docker compose validation; not portable"
    added: "2026-04-21"
YAML
}

@test "passes when local-overrides.yml not staged" {
	cd "$TEST_TMP" || return 1
	echo "unrelated" >README.md
	git add README.md
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on empty overrides[]" {
	cd "$TEST_TMP" || return 1
	_write_valid_empty
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid one-entry domain-extension" {
	cd "$TEST_TMP" || return 1
	_write_valid_one_domain_extension
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "fails on wrong schema_version" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 99
overrides: []
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"schema_version must equal 1"* ]]
}

@test "fails on missing path field" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - category: domain-extension
    reason: "Homelab-specific docker compose validation; not portable"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"path missing or null"* ]]
}

@test "fails on absolute path" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: /etc/passwd
    category: domain-extension
    reason: "Should not be allowed — absolute path"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be repo-relative"* ]]
}

@test "fails on path-traversal" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: ../etc/passwd
    category: domain-extension
    reason: "Path traversal attempt"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be repo-relative"* ]]
}

@test "fails on invalid category" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: bogus
    reason: "Invalid category should be rejected"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be one of"* ]]
}

@test "fails on short reason" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: "too short"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"too short"* ]]
}

@test "fails on malformed added date" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: "Reason long enough to pass min"
    added: "April 2026"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be YYYY-MM-DD"* ]]
}

@test "fails when temp-divergence missing expires field" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: temp-divergence
    reason: "Temporary divergence requires expires"
    added: "2026-05-15"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"expires required"* ]]
}

@test "fails on expired temp-divergence" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: temp-divergence
    reason: "Expired temp divergence should fail"
    added: "2024-01-01"
    expires: "2024-12-31"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"in the past"* ]]
}

@test "passes on valid future-expires temp-divergence" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: temp-divergence
    reason: "Valid until far-future date"
    added: "2026-05-15"
    expires: "2099-12-31"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on staged deletion of local-overrides.yml" {
	cd "$TEST_TMP" || return 1
	_write_valid_empty
	git add .claude/local-overrides.yml
	git commit -q -m "seed"
	git rm -q .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "exits 2 on corrupt YAML" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides: [
  - unclosed
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"yq failed parsing"* ]]
}

@test "bypass env LOCAL_OVERRIDES_SCHEMA_SKIP=1 lets bad schema through" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 99
overrides: bogus
YAML
	git add .claude/local-overrides.yml
	LOCAL_OVERRIDES_SCHEMA_SKIP=1 run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
	[[ $output == *"LOCAL_OVERRIDES_SCHEMA_SKIP"* ]]
}
