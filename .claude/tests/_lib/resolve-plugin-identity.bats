#!/usr/bin/env bats
# covers: _lib/resolve-plugin-identity.sh
# shellcheck disable=SC2030,SC2031  # bats @test bodies run in subshells; per-test env exports are intentional + isolated
#
# #2310/#2316: resolve-plugin-identity.sh is the SSOT for plugin identity
# (derived from .claude-plugin/plugin.json) + plugin-cache path resolution.
# These tests lock:
#   - constants derive correctly from the manifest (name/repo/short/owner);
#   - env overrides win over derivation (testability contract);
#   - cache base default + PLUGIN_CACHE_BASE override;
#   - cache latest = highest semver path; empty cache → rc 1; single version;
#   - installed-versions lists ALL semver dirs, sort -V order (not lexical);
#   - require_plugin_identity gate: ok when complete, rc 2 when manifest absent.
#
# The lib is copied into a synthetic <plugin>/_lib/ with a fixture
# <plugin>/.claude-plugin/plugin.json so BASH_SOURCE-relative PLUGIN_JSON
# resolution points at the fixture, not the real repo manifest.

setup() {
	LIB_SRC="${BATS_TEST_DIRNAME}/../../../_lib/resolve-plugin-identity.sh"
	[ -f "$LIB_SRC" ]
	TEST_TMP=$(mktemp -d -t rpi.XXXXXX) || return 1
	PLUGIN="$TEST_TMP/plugin"
	mkdir -p "$PLUGIN/_lib" "$PLUGIN/.claude-plugin"
	cp "$LIB_SRC" "$PLUGIN/_lib/resolve-plugin-identity.sh"
	LIB="$PLUGIN/_lib/resolve-plugin-identity.sh"
	cat >"$PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "test-plugin-name",
  "version": "1.2.3",
  "repository": "https://github.com/test-owner/test-plugin-name"
}
EOF
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rpi.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "identity constants derive from plugin.json" {
	# shellcheck source=/dev/null
	. "$LIB"
	[ "$PLUGIN_NAME" = "test-plugin-name" ]
	[ "$PLUGIN_REPO_URL" = "https://github.com/test-owner/test-plugin-name" ]
	[ "$PLUGIN_REPO_SHORT" = "test-owner/test-plugin-name" ]
	[ "$PLUGIN_OWNER" = "test-owner" ]
}

@test "trailing .git is stripped from the derived short slug" {
	cat >"$PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "test-plugin-name",
  "version": "1.2.3",
  "repository": "https://github.com/test-owner/test-plugin-name.git"
}
EOF
	# shellcheck source=/dev/null
	. "$LIB"
	[ "$PLUGIN_REPO_SHORT" = "test-owner/test-plugin-name" ]
	[ "$PLUGIN_OWNER" = "test-owner" ]
}

@test "env override wins over plugin.json derivation" {
	export PLUGIN_NAME="overridden-name"
	export PLUGIN_REPO_URL="https://github.com/over/ride"
	# shellcheck source=/dev/null
	. "$LIB"
	[ "$PLUGIN_NAME" = "overridden-name" ]
	[ "$PLUGIN_REPO_SHORT" = "over/ride" ]
	[ "$PLUGIN_OWNER" = "over" ]
}

@test "resolve_plugin_cache_base default uses doubled-name layout under HOME" {
	export HOME="$TEST_TMP/home"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_plugin_cache_base
	[ "$status" -eq 0 ]
	[ "$output" = "$TEST_TMP/home/.claude/plugins/cache/test-plugin-name/test-plugin-name" ]
}

@test "resolve_plugin_cache_base respects PLUGIN_CACHE_BASE override" {
	export PLUGIN_CACHE_BASE="$TEST_TMP/custom/cache"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_plugin_cache_base
	[ "$status" -eq 0 ]
	[ "$output" = "$TEST_TMP/custom/cache" ]
}

@test "resolve_plugin_installed_versions lists semver dirs in sort -V order" {
	export PLUGIN_CACHE_BASE="$TEST_TMP/cache"
	mkdir -p "$PLUGIN_CACHE_BASE/0.1.0" "$PLUGIN_CACHE_BASE/0.10.0" "$PLUGIN_CACHE_BASE/0.2.0"
	mkdir -p "$PLUGIN_CACHE_BASE/not-a-version"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_plugin_installed_versions
	[ "$status" -eq 0 ]
	# Non-semver dir excluded; semver dirs in numeric (not lexical) order.
	[ "${lines[0]}" = "0.1.0" ]
	[ "${lines[1]}" = "0.2.0" ]
	[ "${lines[2]}" = "0.10.0" ]
	[ "${#lines[@]}" -eq 3 ]
}

@test "resolve_plugin_cache_latest returns path to highest semver" {
	export PLUGIN_CACHE_BASE="$TEST_TMP/cache"
	mkdir -p "$PLUGIN_CACHE_BASE/0.1.0" "$PLUGIN_CACHE_BASE/0.10.0" "$PLUGIN_CACHE_BASE/0.2.0"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_plugin_cache_latest
	[ "$status" -eq 0 ]
	[ "$output" = "$TEST_TMP/cache/0.10.0" ]
}

@test "resolve_plugin_cache_latest with a single version returns it" {
	export PLUGIN_CACHE_BASE="$TEST_TMP/cache"
	mkdir -p "$PLUGIN_CACHE_BASE/3.4.5"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_plugin_cache_latest
	[ "$status" -eq 0 ]
	[ "$output" = "$TEST_TMP/cache/3.4.5" ]
}

@test "resolve_plugin_cache_latest returns 1 on empty/absent cache" {
	export PLUGIN_CACHE_BASE="$TEST_TMP/cache-empty"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_plugin_cache_latest
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "require_plugin_identity passes when identity is complete" {
	# shellcheck source=/dev/null
	. "$LIB"
	run require_plugin_identity
	[ "$status" -eq 0 ]
}

@test "require_plugin_identity returns 2 when plugin.json is absent" {
	# Point PLUGIN_JSON at a nonexistent manifest BEFORE sourcing so derivation
	# yields empty identity; the gate must then fail closed (rc 2), not pass.
	export PLUGIN_JSON="$TEST_TMP/nonexistent.json"
	# shellcheck source=/dev/null
	. "$LIB" 2>/dev/null
	run require_plugin_identity
	[ "$status" -eq 2 ]
}
