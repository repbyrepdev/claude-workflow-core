#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh scripts/meta-bootstrap-manifest.yml

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
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

# Write a stub manifest to TEST_TMP. Tests pass the path via `run env
# META_BOOTSTRAP_MANIFEST=...` so the env modification stays subshell-
# local (avoids SC2030/SC2031 "export in @test subshell is lost") and
# the tracked scripts/meta-bootstrap-manifest.yml is never touched —
# so a bats interruption can't pollute the working tree.
_stub_manifest() {
	cat >"$TEST_TMP/manifest.yml"
}

@test "--target machine with positional arg exits 2" {
	run "$SCRIPT" --target machine -- /tmp/stray
	[ "$status" -eq 2 ]
	[[ $output == *"accepts no positional arguments"* ]]
}

@test "--target machine --verify-only against this machine passes the manifest" {
	# Use the tracked manifest. This machine ran bootstrap-machine.sh
	# historically, so the brew/commands/keychain_entries rules should
	# already be satisfied. Failure here = either (a) missing dev setup,
	# or (b) manifest declares packages bootstrap-machine.sh doesn't
	# install (real drift). Disambiguate before blaming the manifest.
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	[[ $output == *"all manifest rules pass"* ]]
}

@test "--target machine --verify-only emits a remediation line per failure" {
	_stub_manifest <<'YAML'
schema_version: 1
targets:
  machine:
    brew_packages:
      - definitely-not-a-real-package-xyz789
    commands:
      - definitely-not-a-real-command-abc456
YAML
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"brew package missing: definitely-not-a-real-package-xyz789"* ]]
	[[ $output == *"command not on PATH: definitely-not-a-real-command-abc456"* ]]
}

@test "all 5 rule kinds can fail in one run (no short-circuit)" {
	_stub_manifest <<'YAML'
schema_version: 1
targets:
  machine:
    brew_packages: [definitely-not-real-pkg]
    commands: [definitely-not-real-cmd]
    keychain_entries: [definitely-not-real-keychain-entry-xyz]
    paths: [/definitely/not/a/real/path]
    json_fields:
      - file: /tmp/definitely-not-a-real-file.json
        jq: .version
        match: '^[0-9]+'
YAML
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"brew package missing"* ]]
	[[ $output == *"command not on PATH"* ]]
	[[ $output == *"Keychain entry missing"* ]]
	[[ $output == *"required path missing"* ]]
	[[ $output == *"file missing"* ]]
}

@test "--target machine --verify-only is idempotent (re-run is a no-op)" {
	# Stub manifest decouples the assertion from whatever brew packages
	# happen to live on the host.
	_stub_manifest <<'YAML'
schema_version: 1
targets:
  machine:
    commands: [sh, ls]
YAML
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	first_output=$output
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 0 ]
	[ "$output" = "$first_output" ]
}

@test "manifest missing → verify-only fails with a clear error" {
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/does-not-exist.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"manifest not found"* ]]
}

@test "schema_version mismatch is fail-closed (no silent partial read)" {
	_stub_manifest <<'YAML'
schema_version: 999
targets:
  machine:
    commands: [sh]
YAML
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"schema_version=999"* ]]
}

@test "target with no rule kinds and no inline:true fails (no vacuous pass)" {
	_stub_manifest <<'YAML'
schema_version: 1
targets:
  machine: {}
YAML
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"refusing to fake-pass"* ]]
}

@test 'tilde path expansion: ~/ resolves to $HOME' {
	# Create a fixture under $HOME, declare it in the manifest, assert pass.
	# The fixture has a unique name so concurrent test runs don't collide.
	local fixture=".meta-bootstrap-fixture-$$-$RANDOM"
	touch "$HOME/$fixture"
	_stub_manifest <<YAML
schema_version: 1
targets:
  machine:
    paths:
      - ~/$fixture
YAML
	run env META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	rm -f "$HOME/$fixture"
	[ "$status" -eq 0 ]
}

@test "non-mikefarah yq variant is refused (fail-closed on wrong fork)" {
	# Shim a fake yq onto PATH that reports itself as Python yq.
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/yq" <<'STUB'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "yq 3.4.3 (python)"; exit 0; fi
exit 0
STUB
	chmod +x "$TEST_TMP/bin/yq"
	_stub_manifest <<'YAML'
schema_version: 1
targets:
  machine:
    commands: [sh]
YAML
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" META_BOOTSTRAP_MANIFEST="$TEST_TMP/manifest.yml" "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 1 ]
	[[ $output == *"mikefarah/yq"* ]]
}
