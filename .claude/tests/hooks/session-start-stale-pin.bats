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
	mkdir -p "$CACHE_DIR/0.8.5" "$CACHE_DIR/0.9.7/scripts"
	# Provide an EXECUTABLE remediation script in the newest cache dir so the
	# primary (launcher-based) remediation branch fires (CR-in-CI #2540 phase2:
	# the hook now picks the newest version whose script is runnable, not a blind
	# CACHE_VER that may ship no script).
	printf '#!/usr/bin/env bash\nexit 0\n' >"$CACHE_DIR/0.9.7/scripts/install-hook-launchers.sh"
	chmod +x "$CACHE_DIR/0.9.7/scripts/install-hook-launchers.sh"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"plugin-cache drift detected"* ]] || return 1
	[[ $output == *"v0.8.5"* ]] || return 1
	[[ $output == *"v0.9.7"* ]] || return 1
	# remediation names the launcher tool by ABSOLUTE path + warns off migrate-settings.sh
	[[ $output == *"0.9.7/scripts/install-hook-launchers.sh"* ]] || return 1
	[[ $output == *"migrate-settings.sh"* ]] || return 1
}

@test "drift but NO executable remediation script → reinstall advice, no 404 command (#2540)" {
	# When no cache version ships a runnable install-hook-launchers.sh, the hook
	# must keep the drift warning but NOT print a remediation command that would
	# 404 — it points at the plugin manager instead.
	_write_settings_with_version "0.8.5"
	mkdir -p "$CACHE_DIR/0.8.5" "$CACHE_DIR/0.9.7" # no scripts/ anywhere
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"plugin-cache drift detected"* ]] || return 1
	[[ $output == *"No cache version"* ]] || return 1
	[[ $output == *"plugin reload claude-workflow-core"* ]] || return 1
	# Reject ANY absolute launcher-script path — not just one with specific flags.
	# None exists in any cache version here, so any `/…/scripts/install-hook-launchers.sh`
	# in the output is a 404 the operator would run (CR-in-CI #2540). Matching the
	# path (not the flag string) keeps this from passing if the remediation flags
	# change but the dangling path remains. (The else-branch names the script in
	# prose as ` scripts/…` with no leading slash, so this correctly does NOT trip.)
	[[ $output != *"/scripts/install-hook-launchers.sh"* ]] || return 1
}

@test "up-to-date: settings v0.9.7 == cache v0.9.7 → silent" {
	_write_settings_with_version "0.9.7"
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "settings newer than cache → inverse drift warning (#89 r1)" {
	# Phase 1 r1 finding: settings > cache is broken state (hooks
	# reference paths that don't exist). Surface as 'inverse drift'
	# warning, not silent pass.
	_write_settings_with_version "0.10.0"
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"inverse plugin-cache drift"* ]]
	[[ $output == *"v0.10.0"* ]]
	[[ $output == *"v0.9.7"* ]]
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

@test "malformed settings.json → warn + silent pass (#89 r1)" {
	# Phase 1 r1: corrupt JSON should not look like 'no refs'. Pre-
	# validate via jq empty + warn operator.
	echo "{ broken json" >"$SETTINGS"
	mkdir -p "$CACHE_DIR/0.9.7"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"not valid JSON"* ]]
}

@test "cache dir empty (no subdirs at all) → warn corrupt-cache (#89 r1)" {
	# Phase 1 r1: nullglob + empty-dir detection. Previously silent;
	# now surfaces as corrupt-cache warning.
	_write_settings_with_version "0.9.7"
	# CACHE_DIR exists (from setup), no subdirs created.
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"may be corrupt or partially installed"* ]]
}

@test "cache dir has only non-semver subdirs → warn unexpected-layout (#89 r1)" {
	_write_settings_with_version "0.9.7"
	mkdir -p "$CACHE_DIR/.Trash" "$CACHE_DIR/extract-tmp"
	run bash "$SCRIPT" 2>&1
	[ "$status" -eq 0 ]
	[[ $output == *"layout unexpected"* ]]
}

@test "stderr-only output (drift goes to stderr, not stdout) (#89 r1)" {
	_write_settings_with_version "0.8.5"
	mkdir -p "$CACHE_DIR/0.9.7"
	# Capture stdout and stderr separately
	stdout=$(bash "$SCRIPT" 2>/dev/null)
	stderr=$(bash "$SCRIPT" 2>&1 >/dev/null)
	[ -z "$stdout" ]
	[[ $stderr == *"drift detected"* ]]
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
