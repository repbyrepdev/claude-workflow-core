#!/usr/bin/env bats
# covers: scripts/install-register-hook-permissions.sh scripts/register-hook.sh
#
# Regression tests for install-register-hook-permissions.sh (#72). Verifies
# the four invocation modes (status / --check / --json / --help), detection
# of missing vs present allowlist entries, precondition failures (missing
# or malformed settings.json), and the register-hook.sh --check-permissions
# delegation including its short-circuit before register-hook.sh's own
# preconditions.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/install-register-hook-permissions.sh"
	REGSCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/register-hook.sh"
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

# Helper: write a settings.json with the full required allowlist
_write_full_allowlist() {
	jq -n '{permissions: {allow: [
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check-permissions)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --all-auto-register)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --dry-run --all-auto-register)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --check)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --json)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
}

# --- arg parsing ------------------------------------------------------

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"WHY this script exists"* ]] || return 1
	[[ $output == *"--check"* ]] || return 1
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

# --- preconditions (status mode) --------------------------------------

@test "status mode: missing settings.json exits 2 with clear message" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"does not exist"* ]]
}

@test "status mode: malformed settings.json exits 3 + emits jq detail" {
	echo "not valid json {{{" >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 3 ]
	[[ $output == *"malformed JSON"* ]] || return 1
	# jq error detail is surfaced so the operator knows WHERE the parse failed.
	[[ $output == *"jq:"* ]]
}

# --- preconditions (--check mode) ------------------------------------

@test "--check: missing settings.json exits 2 (precondition cascade)" {
	# pr-test-analyzer finding: --check inherits precondition checks
	# and exits 2/3 — NOT 1 — when settings are unreadable. Caller
	# scripts must distinguish 'allowlist missing' (exit 1) from
	# 'config broken' (exit 2/3) to remediate correctly.
	run "$SCRIPT" --check
	[ "$status" -eq 2 ]
	[[ $output == *"does not exist"* ]]
}

@test "--check: malformed settings.json exits 3" {
	# Same precondition contract as default mode — caller must not
	# conflate exit 1 (missing pattern) with exit 3 (broken config).
	echo "}{ broken" >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
	[ "$status" -eq 3 ]
	[[ $output == *"malformed JSON"* ]]
}

# --- detection: missing vs present ------------------------------------

@test "empty permissions reports all 7 patterns missing" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ $output == *"NOT installed"* ]] || return 1
	[[ $output == *"register-hook.sh --check"* ]] || return 1
	[[ $output == *"register-hook.sh --check-permissions"* ]] || return 1
	[[ $output == *"register-hook.sh --all-auto-register"* ]] || return 1
	[[ $output == *"install-register-hook-permissions.sh --check"* ]] || return 1
	[[ $output == *"install-register-hook-permissions.sh --json"* ]]
}

@test "partial allowlist (install-side present) reports register-side missing" {
	jq -n '{permissions: {allow: [
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --check)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --json)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ $output == *"NOT installed"* ]] || return 1
	# install-side patterns should NOT appear in the missing list
	[[ $output != *"- Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --check)"* ]] || return 1
	# register-hook patterns SHOULD appear in the missing list
	[[ $output == *"- Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)"* ]]
}

@test "partial allowlist (register-side present) reports install-side missing" {
	# Reverse-direction coverage per pr-test-analyzer: bug in pattern
	# loop indexing could pass one direction and fail the other.
	jq -n '{permissions: {allow: [
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check-permissions)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --all-auto-register)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --dry-run --all-auto-register)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ $output == *"NOT installed"* ]] || return 1
	[[ $output != *"- Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)"* ]] || return 1
	[[ $output == *"- Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --check)"* ]]
}

@test "full allowlist reports installed" {
	_write_full_allowlist
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"are present"* ]]
}

@test "extra unrelated allow entries do not affect detection" {
	jq -n '{permissions: {allow: [
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --check-permissions)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --all-auto-register)",
		"Bash(*/claude-workflow-core/*scripts/register-hook.sh --dry-run --all-auto-register)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --check)",
		"Bash(*/claude-workflow-core/*scripts/install-register-hook-permissions.sh --json)",
		"Bash(ls *)",
		"Read(*)"
	]}}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"are present"* ]]
}

# --- --check mode -----------------------------------------------------

@test "--check: exits 0 when fully installed" {
	_write_full_allowlist
	run "$SCRIPT" --check
	[ "$status" -eq 0 ]
}

@test "--check: exits 1 when patterns missing" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
	[ "$status" -eq 1 ]
	[[ $output == *"pattern(s) missing"* ]]
}

# --- --json mode (short-circuit) --------------------------------------

@test "--json: emits valid JSON snippet from any state" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	echo "$output" | jq empty
	# Must enumerate every REQUIRED_PATTERN
	got=$(echo "$output" | jq -r '.permissions.allow | length')
	[ "$got" -eq 7 ]
	# First entry is the register-hook --check probe form
	first=$(echo "$output" | jq -r '.permissions.allow[0]')
	[ "$first" = "Bash(*/claude-workflow-core/*scripts/register-hook.sh --check)" ]
}

@test "--json: short-circuits before settings.json read (missing OK)" {
	# Operators on fresh machines need this output BEFORE settings.json
	# exists. --json must NOT inherit the missing-file precondition.
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	echo "$output" | jq empty
	got=$(echo "$output" | jq -r '.permissions.allow | length')
	[ "$got" -eq 7 ]
}

@test "--json: short-circuits before settings.json read (malformed OK)" {
	echo "}{ broken" >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	echo "$output" | jq empty
}

@test "--json: shape unchanged regardless of current state" {
	_write_full_allowlist
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	echo "$output" | jq empty
	got=$(echo "$output" | jq -r '.permissions.allow | length')
	[ "$got" -eq 7 ]
}

# --- security: no trailing wildcard in REQUIRED_PATTERNS -------------

@test "--json: no pattern ends in a trailing wildcard" {
	# A trailing `*` in fnmatch matches shell metacharacters including
	# ` && ` / ` ; ` / ` | `, allowing command-chaining past the
	# classifier. Each REQUIRED_PATTERN must end with an exact arg set.
	run "$SCRIPT" --json
	[ "$status" -eq 0 ]
	# Every pattern's last character before the closing `)` must NOT be `*`.
	bad=$(echo "$output" | jq -r '.permissions.allow[] | select(test("\\*\\)$"))')
	[ -z "$bad" ]
}

# --- register-hook.sh integration -----------------------------------

@test "register-hook.sh --check-permissions: delegates (missing → exit 1)" {
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$REGSCRIPT" --check-permissions
	[ "$status" -eq 1 ]
	# Output must be from the installer, not register-hook.sh itself.
	[[ $output == *"install-register-hook-permissions.sh"* ]] || return 1
	[[ $output == *"pattern(s) missing"* ]]
}

@test "register-hook.sh --check-permissions: delegates (installed → exit 0)" {
	# Success-path delegation — autonomous agent/plugin invocations
	# gate on `register-hook.sh --check-permissions && ...`, so the
	# exit-0 contract is load-bearing.
	_write_full_allowlist
	run "$REGSCRIPT" --check-permissions
	[ "$status" -eq 0 ]
}

@test "conflicting mode flags rejected with exit 2" {
	# CR finding: --check --json silently won the last-set, turning
	# failing probe into exit 0. Conflict must be a usage error.
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check --json
	[ "$status" -eq 2 ]
	[[ $output == *"conflicting flags"* ]]
}

@test "same mode flag repeated is OK (idempotent)" {
	# Conflict-check should distinguish 'same flag twice' (harmless)
	# from 'two different flags' (ambiguous). Only the latter errors.
	_write_full_allowlist
	run "$SCRIPT" --check --check
	[ "$status" -eq 0 ]
}

@test "--json works without jq (no dependency)" {
	# CR finding: --json snippet is constant, doesn't need jq. Fresh
	# machines must be able to extract the snippet BEFORE installing jq.
	# Simulate jq absence by setting PATH to a directory without jq.
	mkdir -p "$TEST_TMP/nobin"
	run env PATH="$TEST_TMP/nobin" "$SCRIPT" --json
	[ "$status" -eq 0 ]
	# Output must still be valid JSON (verified with jq via real PATH)
	echo "$output" | jq empty
	got=$(echo "$output" | jq -r '.permissions.allow | length')
	[ "$got" -eq 7 ]
}

@test "register-hook --check-permissions: rejects combination with --check" {
	# CR finding: --check-permissions execs immediately; other flags
	# would be silently discarded. Must be exclusive.
	run "$REGSCRIPT" --check-permissions --check
	[ "$status" -eq 2 ]
	[[ $output == *"exclusive"* ]]
}

@test "register-hook --check-permissions: rejects combination with hook path" {
	run "$REGSCRIPT" --check-permissions hooks/foo.sh
	[ "$status" -eq 2 ]
	[[ $output == *"exclusive"* ]]
}

@test "register-hook --check-permissions: rejects combination with --all-auto-register" {
	run "$REGSCRIPT" --check-permissions --all-auto-register
	[ "$status" -eq 2 ]
	[[ $output == *"exclusive"* ]]
}

@test "register-hook.sh --check-permissions: works outside git repo" {
	# Bootstrap scenario: operator runs from $HOME (no git repo) to
	# verify allowlist readiness. The short-circuit MUST run before
	# register-hook.sh's git-repo precondition.
	_write_full_allowlist
	cwd=$PWD
	cd "$TEST_TMP"
	run "$REGSCRIPT" --check-permissions
	cd "$cwd"
	[ "$status" -eq 0 ]
}
