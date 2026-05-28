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

# CR-in-CI r1 F3: explicit happy-path coverage for all 4 categories.
@test "passes on valid superset entry" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .github/labels.yml
    category: superset
    reason: "Domain labels extend plugin's generic set"
    added: "2026-04-21"
    diff_allowed: domain_extensions_only
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid legacy entry" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: scripts/old-helper.sh
    category: legacy
    reason: "Predates SSOT discipline; reconcile in future audit"
    added: "2025-01-15"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

# CR-in-CI r1 F2: benign filenames with `..` (e.g. `docs/v1..v2-notes.md`)
# must PASS — the path-traversal guard targets `..` as a path segment only.
@test "passes on benign filename containing '..'" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: docs/v1..v2-notes.md
    category: legacy
    reason: "Benign filename — '..' is part of filename, not path segment"
    added: "2025-01-15"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 0 ]
}

# CR-in-CI r1 F1: non-array `overrides:` (e.g. scalar string) must
# be rejected with a clear "must be a list" message — not silently
# slip through to `.overrides[$i]` iteration crash.
@test "fails on non-array .overrides (scalar)" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides: bogus
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"must be a list"* ]]
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

# CR-CLI r3: per-field missing-field coverage for the 4 required fields
# (path/category/reason/added). Mirrors the existing "missing path" test.
@test "fails on missing category field" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    reason: "Reason long enough to pass min-length check"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"category missing"* ]]
}

@test "fails on missing reason field" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"reason missing"* ]]
}

@test "fails on missing added field" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: .claude/hooks/foo.sh
    category: domain-extension
    reason: "Reason long enough to pass min-length check"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"added missing"* ]]
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

@test "fails on path-traversal '..' as path segment" {
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
	[[ $output == *"path traversal"* ]] || [[ $output == *"'..' as a path segment"* ]]
}

# Other path-traversal shapes — embedded '..' segment after a prefix.
@test "fails on embedded '..' as path segment" {
	cd "$TEST_TMP" || return 1
	cat >.claude/local-overrides.yml <<'YAML'
schema_version: 1
overrides:
  - path: docs/../etc/passwd
    category: domain-extension
    reason: "Embedded path traversal attempt"
    added: "2026-04-21"
YAML
	git add .claude/local-overrides.yml
	run pre-commit-hooks/local-overrides-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"path traversal"* ]]
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
