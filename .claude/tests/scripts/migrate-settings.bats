#!/usr/bin/env bats
# covers: scripts/migrate-settings.sh
#
# Tests for the one-time ~/.claude/settings.json migration script (#73).
# Verifies the version-bump path-walk, auto-detection of FROM_VER and
# TO_VER, hook registration delegation to register-hook.sh, dry-run
# safety, and refusal on malformed/missing settings.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/migrate-settings.sh"
	TEST_TMP=$(mktemp -d -t migrate-settings.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	export CLAUDE_SETTINGS_FILE="$TEST_TMP/settings.json"
	# Isolated plugin cache base — populate two version dirs so
	# auto-detect can pick the highest.
	export PLUGIN_CACHE_BASE="$TEST_TMP/cache"
	mkdir -p "$PLUGIN_CACHE_BASE/0.8.5" "$PLUGIN_CACHE_BASE/0.8.8"
}

teardown() {
	unset CLAUDE_SETTINGS_FILE PLUGIN_CACHE_BASE
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */migrate-settings.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: write a settings.json with three 0.8.5 hook command paths.
_write_legacy_settings() {
	jq -n '{
		hooks: {
			PreToolUse: [{
				matcher: "Bash",
				hooks: [
					{type: "command", command: "/Users/u/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.8.5/hooks/check-gh-limits.sh"},
					{type: "command", command: "/Users/u/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.8.5/hooks/memory-guard.sh"}
				]
			}]
		}
	}' >"$CLAUDE_SETTINGS_FILE"
}

# --- arg parsing ------------------------------------------------------

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"What it does"* ]]
	[[ $output == *"Exit codes"* ]]
}

@test "unknown flag rejected with exit 2" {
	_write_legacy_settings
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}

@test "--from without value rejected with exit 2" {
	_write_legacy_settings
	run "$SCRIPT" --from
	[ "$status" -eq 2 ]
	[[ $output == *"requires a version"* ]]
}

@test "--to without value rejected with exit 2" {
	_write_legacy_settings
	run "$SCRIPT" --to
	[ "$status" -eq 2 ]
	[[ $output == *"requires a version"* ]]
}

# --- preconditions ----------------------------------------------------

@test "missing settings.json exits 2" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"does not exist"* ]]
}

@test "malformed settings.json exits 3" {
	echo "not json {{{" >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 3 ]
	[[ $output == *"malformed JSON"* ]]
}

@test "missing plugin cache base + no --to → exit 2" {
	_write_legacy_settings
	# Pass PLUGIN_CACHE_BASE per-invocation via `env` instead of `export`
	# — bats' per-@test subshell would otherwise generate SC2030/SC2031.
	run env PLUGIN_CACHE_BASE="$TEST_TMP/nope" "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"plugin cache base not found"* ]]
}

# --- version detection ------------------------------------------------

@test "auto-detects TO_VER as highest semver in cache base" {
	_write_legacy_settings
	mkdir -p "$PLUGIN_CACHE_BASE/0.8.10" # higher than 0.8.8 (semver-sorted)
	run "$SCRIPT" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"→ 0.8.10"* ]]
}

@test "auto-detects FROM_VER from semver path segment, not package name" {
	# Regression: the path has TWO claude-workflow-core segments; the
	# capture must target the semver-shaped one, not the manifest name.
	_write_legacy_settings
	run "$SCRIPT" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"0.8.5 → 0.8.8"* ]]
}

@test "explicit --from --to overrides auto-detect" {
	_write_legacy_settings
	run "$SCRIPT" --from 0.7.0 --to 0.9.0 --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"0.7.0 → 0.9.0"* ]]
}

# --- dry-run safety ---------------------------------------------------

@test "--dry-run leaves settings.json unchanged" {
	_write_legacy_settings
	before=$(jq -S . "$CLAUDE_SETTINGS_FILE" | shasum -a 256 | cut -d' ' -f1)
	run "$SCRIPT" --dry-run
	[ "$status" -eq 0 ]
	after=$(jq -S . "$CLAUDE_SETTINGS_FILE" | shasum -a 256 | cut -d' ' -f1)
	[ "$before" = "$after" ]
}

@test "--dry-run prints accurate ref-bump count" {
	_write_legacy_settings
	run "$SCRIPT" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"Refs to bump:     2"* ]]
}

# --- real version bump ----------------------------------------------

@test "version bump rewrites all matching path refs" {
	_write_legacy_settings
	# Stub register-hook.sh so the migration script doesn't try to register
	# real hooks during the test.
	export PATH="$TEST_TMP/stubs:$PATH"
	mkdir -p "$TEST_TMP/stubs"
	# The script invokes $SCRIPT_DIR/register-hook.sh by absolute path,
	# not via PATH, so stubbing PATH alone isn't enough. We make sure no
	# new hooks are present so register-hook.sh is never invoked.
	# (NEW_HOOKS are filtered to "present files" — in this test those
	# files don't exist in the test tmpdir context, but they DO exist
	# in the real repo... so the test creates a special env where the
	# repo's hooks dir is invisible.)
	# Simplest: assert the version bump happened by checking the JSON
	# content directly and accept that register-hook.sh runs against
	# the real settings.json. Since CLAUDE_SETTINGS_FILE is isolated,
	# the register-hook.sh call writes to OUR tmp file, not the real one.

	run "$SCRIPT" --from 0.8.5 --to 0.8.8
	[ "$status" -eq 0 ]
	# Both refs should now be 0.8.8
	count_old=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| select(contains("/claude-workflow-core/0.8.5/"))] | length
	' "$CLAUDE_SETTINGS_FILE")
	count_new=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| select(contains("/claude-workflow-core/0.8.8/"))] | length
	' "$CLAUDE_SETTINGS_FILE")
	[ "$count_old" -eq 0 ]
	# 2 original refs + 3 new hooks registered = 5 entries. But hooks
	# get registered under new event/matcher groupings, so count of
	# 0.8.8 paths is at least 2 (the bumped ones) plus however many
	# the register-hook.sh added.
	[ "$count_new" -ge 2 ]
}

@test "version bump preserves unrelated path strings" {
	jq -n '{
		hooks: {
			PreToolUse: [{
				matcher: "Bash",
				hooks: [
					{type: "command", command: "/Users/u/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.8.5/hooks/x.sh"},
					{type: "command", command: "/some/other/path/v0.8.5/script.sh"}
				]
			}]
		}
	}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --from 0.8.5 --to 0.8.8
	[ "$status" -eq 0 ]
	# Unrelated /some/other/path/v0.8.5/ must NOT be rewritten
	got=$(jq -r '.hooks.PreToolUse[0].hooks[1].command' "$CLAUDE_SETTINGS_FILE")
	[ "$got" = "/some/other/path/v0.8.5/script.sh" ]
	# Only the claude-workflow-core path got bumped
	got=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
	[[ $got == */claude-workflow-core/0.8.8/* ]]
}

@test "no version refs + explicit --to → still attempts hook registration" {
	echo '{"hooks":{}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --to 0.8.8
	# Either succeeds (with warning) or fails — but must report the
	# no-refs-found condition clearly.
	[[ $output == *"no claude-workflow-core version refs"* ]] || [[ $output == *"Migration complete"* ]]
}
