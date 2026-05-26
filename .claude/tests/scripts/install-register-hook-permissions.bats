#!/usr/bin/env bats
# covers: scripts/install-register-hook-permissions.sh
#
# Regression tests for install-register-hook-permissions.sh (#72). Verifies
# the four invocation modes (status / --check / --json / --help), detection
# of missing vs present allowlist entries, and precondition failures
# (missing or malformed settings.json).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/install-register-hook-permissions.sh"
	TEST_TMP=$(mktemp -d -t install-perms.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	export CLAUDE_SETTINGS_FILE="$TEST_TMP/settings.json"
}

teardown() {
	unset CLAUDE_SETTINGS_FILE
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */install-perms.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# --- arg parsing ------------------------------------------------------

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"WHY this script exists"* ]]
	[[ $output == *"--check"* ]]
	[[ $output == *"Exit codes"* ]]
}

@test "unknown flag rejected with exit 2" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}

@test "unexpected positional rejected with exit 2" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" somefile
	[ "$status" -eq 2 ]
	[[ $output == *"unexpected positional"* ]]
}

# --- preconditions ----------------------------------------------------

@test "missing settings.json exits 2 with clear message" {
	# CLAUDE_SETTINGS_FILE points at a path that doesn't exist
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"does not exist"* ]]
}

@test "malformed settings.json exits 3" {
	echo "not valid json {{{" >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 3 ]
	[[ $output == *"malformed JSON"* ]]
}

# --- detection: missing vs present ------------------------------------

@test "empty permissions reports both patterns missing" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ $output == *"NOT installed"* ]]
	[[ $output == *"register-hook.sh"* ]]
	[[ $output == *"install-register-hook-permissions.sh"* ]]
}

@test "partial allowlist still reports the missing one" {
	jq -n '{permissions: {allow: ["Bash(*/scripts/register-hook.sh*)"]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ $output == *"NOT installed"* ]]
	# the register-hook one is present so should not be in the missing list
	[[ $output != *"- Bash(*/scripts/register-hook.sh*)"* ]]
	[[ $output == *"- Bash(*/scripts/install-register-hook-permissions.sh*)"* ]]
}

@test "both patterns present reports installed" {
	jq -n '{permissions: {allow: [
		"Bash(*/scripts/register-hook.sh*)",
		"Bash(*/scripts/install-register-hook-permissions.sh*)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"are present"* ]]
}

@test "extra unrelated allow entries do not affect detection" {
	jq -n '{permissions: {allow: [
		"Bash(*/scripts/register-hook.sh*)",
		"Bash(*/scripts/install-register-hook-permissions.sh*)",
		"Bash(ls *)",
		"Read(*)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"are present"* ]]
}

# --- --check mode -----------------------------------------------------

@test "--check exits 0 when installed" {
	jq -n '{permissions: {allow: [
		"Bash(*/scripts/register-hook.sh*)",
		"Bash(*/scripts/install-register-hook-permissions.sh*)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
	[ "$status" -eq 0 ]
}

@test "--check exits 1 when missing, prints to stderr" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
	[ "$status" -eq 1 ]
	# --check goes to stderr; bats `output` merges streams unless redirected.
	# We verify exit code + the missing-pattern message appears.
	[[ $output == *"pattern(s) missing"* ]]
}

# --- --json mode ------------------------------------------------------

@test "--json emits valid JSON snippet" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	# Snippet must be valid JSON
	echo "$output" | jq empty
	# Must contain both allow entries
	got=$(echo "$output" | jq -r '.permissions.allow | length')
	[ "$got" -eq 2 ]
	got=$(echo "$output" | jq -r '.permissions.allow[0]')
	[ "$got" = "Bash(*/scripts/register-hook.sh*)" ]
}

@test "--json shape unchanged regardless of current settings" {
	# --json is purely descriptive — same output even when already installed
	jq -n '{permissions: {allow: [
		"Bash(*/scripts/register-hook.sh*)",
		"Bash(*/scripts/install-register-hook-permissions.sh*)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	echo "$output" | jq empty
	got=$(echo "$output" | jq -r '.permissions.allow | length')
	[ "$got" -eq 2 ]
}

# --- register-hook.sh integration ------------------------------------

@test "register-hook.sh --check-permissions delegates to installer" {
	REG="${BATS_TEST_DIRNAME}/../../../scripts/register-hook.sh"
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$REG" --check-permissions
	[ "$status" -eq 1 ]
	# Output should be from the installer, not register-hook.sh itself
	[[ $output == *"install-register-hook-permissions.sh"* ]]
	[[ $output == *"pattern(s) missing"* ]]
}
