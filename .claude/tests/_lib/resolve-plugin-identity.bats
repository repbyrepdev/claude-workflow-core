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

@test "resolve_plugin_cache_base fails closed (rc 2) without PLUGIN_NAME or override (#2310 r2)" {
	# Absent manifest → empty PLUGIN_NAME; no PLUGIN_CACHE_BASE override. The base
	# resolver must rc 2 (not emit a malformed .../cache// path).
	export PLUGIN_JSON="$TEST_TMP/nonexistent.json"
	unset PLUGIN_CACHE_BASE
	# shellcheck source=/dev/null
	. "$LIB" 2>/dev/null
	run resolve_plugin_cache_base
	[ "$status" -eq 2 ]
}

@test "resolve_plugin_installed_versions lists semver dirs in sort -V order" {
	export PLUGIN_CACHE_BASE="$TEST_TMP/cache"
	mkdir -p "$PLUGIN_CACHE_BASE/0.1.0" "$PLUGIN_CACHE_BASE/0.10.0" "$PLUGIN_CACHE_BASE/0.2.0"
	# non-semver, prerelease, and extra-segment dirs must ALL be excluded by the
	# strict X.Y.Z regex (#2310 phase2 r2 — the old glob let prerelease through).
	mkdir -p "$PLUGIN_CACHE_BASE/not-a-version" "$PLUGIN_CACHE_BASE/1.2.3-rc1" "$PLUGIN_CACHE_BASE/1.2.3.4"
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

@test "resolve_plugin_cache_latest PROPAGATES inner rc 2 (hard error), not collapse to 1 (#2427)" {
	# Absent manifest → empty PLUGIN_NAME; no PLUGIN_CACHE_BASE override. The inner
	# resolve_plugin_installed_versions → resolve_plugin_cache_base hard-errors
	# (rc 2). Before #2427, `|| return 1` masked it as "no versions" (rc 1); the
	# fix captures rc + propagates so a caller distinguishes broken identity from
	# no-cache-installed. rc 1 (empty cache, test above) must STILL be 1.
	export PLUGIN_JSON="$TEST_TMP/nonexistent.json"
	unset PLUGIN_CACHE_BASE
	# shellcheck source=/dev/null
	. "$LIB" 2>/dev/null
	run resolve_plugin_cache_latest
	[ "$status" -eq 2 ]
	# `run` merges stderr: the hard-error diagnostic surfaced, proving the rc-2
	# (broken-identity) path fired, NOT a silent rc-1 "no versions" collapse.
	[[ $output == *"PLUGIN_NAME"* ]]
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

@test "require_plugin_identity returns 2 on a present-but-incomplete manifest (.repository missing) (#2310)" {
	# Manifest exists with .name but NO .repository (realistic partial manifest).
	# Source + gate inside `run bash -c` (no set -e there) so the missing-field
	# jq failure can't abort under a caller errexit and leave the gate undefined.
	cat >"$PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "test-plugin-name",
  "version": "1.2.3"
}
EOF
	run bash -c '. "$1" 2>/dev/null; require_plugin_identity' _ "$LIB"
	[ "$status" -eq 2 ]
}

@test "require_plugin_identity returns 2 on a non-github (ssh) repository URL (#2310 fix A)" {
	# An ssh-form URL does NOT match the https github prefix-strip, so the
	# well-formedness gate blanks SHORT/OWNER. NAME + URL stay non-empty, so a
	# rc-2 here proves the malformed slug was blanked (not accepted).
	cat >"$PLUGIN/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "test-plugin-name",
  "version": "1.2.3",
  "repository": "git@github.com:test-owner/test-plugin-name.git"
}
EOF
	# shellcheck source=/dev/null
	. "$LIB" 2>/dev/null
	[ -z "$PLUGIN_REPO_SHORT" ] # well-formedness gate blanked the malformed slug
	run require_plugin_identity
	[ "$status" -eq 2 ]
}
