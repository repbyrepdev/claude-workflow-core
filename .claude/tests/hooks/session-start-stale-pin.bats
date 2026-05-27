#!/usr/bin/env bats
# covers: hooks/session-start-stale-pin.sh
#
# Tests for the SessionStart stale-pin detector (#89). Verifies:
# - Drift detected (settings ver < cache ver) → warn line emitted
# - Up-to-date (equal versions) → silent
# - Settings has no plugin-cache refs → silent
# - Settings missing / cache dir missing → silent pass
# - SESSION_START_STALE_PIN_SKIP=1 → silent
# - Cache has non-semver subdirs → filtered out by regex

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/session-start-stale-pin.sh"
	TEST_TMP=$(mktemp -d -t stale-pin.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	SETTINGS="$TEST_TMP/settings.json"
	CACHE_DIR="$TEST_TMP/cache/claude-workflow-core/claude-workflow-core"
	mkdir -p "$CACHE_DIR"
	export SESSION_START_STALE_PIN_SETTINGS="$SETTINGS"
	export SESSION_START_STALE_PIN_CACHE_DIR="$CACHE_DIR"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */stale-pin.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_settings_with_version() {
	local ver=$1
	cat >"$SETTINGS" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "/Users/x/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/$ver/hooks/some-hook.sh"}
        ]
      }
    ]
  }
}
EOF
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "drift detected: settings v0.8.5 vs cache v0.9.7 → warn emitted" {
	_write_settings_with_version "0.8.5"
	mkdir -p "$CACHE_DIR/0.8.5" "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"plugin-cache drift detected"* ]]
	[[ $output == *"v0.8.5"* ]]
	[[ $output == *"v0.9.7"* ]]
	[[ $output == *"migrate-settings.sh"* ]]
}

@test "up-to-date: settings v0.9.7 == cache v0.9.7 → silent" {
	_write_settings_with_version "0.9.7"
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "settings newer than cache (downgrade scenario) → silent" {
	# Defensive: if settings somehow refs a version newer than cache
	# (e.g., manual edit), the hook doesn't pester operator.
	_write_settings_with_version "0.10.0"
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "semver-aware: v0.9.5 vs v0.10.0 → drift (10 > 9 numerically)" {
	# Locks the regression target — lex compare would say 0.9.5 > 0.10.0.
	_write_settings_with_version "0.9.5"
	mkdir -p "$CACHE_DIR/0.9.5" "$CACHE_DIR/0.10.0"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"v0.9.5"* ]]
	[[ $output == *"v0.10.0"* ]]
	[[ $output == *"drift"* ]]
}

@test "settings has no plugin-cache refs → silent" {
	cat >"$SETTINGS" <<'EOF'
{"hooks": {"PreToolUse": [{"hooks": [{"command": "/usr/local/bin/some-tool"}]}]}}
EOF
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "settings.json missing → silent pass" {
	# No SETTINGS file created.
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "cache dir missing → silent pass" {
	_write_settings_with_version "0.9.7"
	rm -rf "$CACHE_DIR"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "SESSION_START_STALE_PIN_SKIP=1 → silent bypass" {
	_write_settings_with_version "0.8.5"
	mkdir -p "$CACHE_DIR/0.9.7"
	SESSION_START_STALE_PIN_SKIP=1 run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "cache has non-semver subdirs → filtered, picks max semver" {
	_write_settings_with_version "0.8.5"
	# Mix of valid semver + garbage subdirs (e.g., partial extract).
	mkdir -p "$CACHE_DIR/0.8.5" "$CACHE_DIR/0.9.0" "$CACHE_DIR/.cache" "$CACHE_DIR/extract-tmp"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"v0.9.0"* ]]
}

@test "multiple refs in settings → picks max version" {
	# settings.json has both 0.8.5 + 0.9.5 refs (mid-migration state).
	# Hook compares the HIGHEST settings ver to highest cache ver.
	cat >"$SETTINGS" <<'EOF'
{
  "hooks": {
    "PreToolUse": [{
      "hooks": [
        {"command": "/Users/x/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.8.5/hooks/old.sh"},
        {"command": "/Users/x/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/0.9.5/hooks/new.sh"}
      ]
    }]
  }
}
EOF
	mkdir -p "$CACHE_DIR/0.9.5"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	# 0.9.5 == 0.9.5 → no drift, silent.
	[ -z "$output" ]
}
