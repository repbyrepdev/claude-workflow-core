#!/usr/bin/env bats
# covers: scripts/register-hook.sh
#
# Regression tests for register-hook.sh (#68 + #69). Covers arg parsing,
# frontmatter discovery, idempotent register/unregister, drift --check,
# and dry-run preview.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/register-hook.sh"
	TEST_TMP=$(mktemp -d -t register-hook.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	# Isolated settings.json + isolated hook directory per test
	export CLAUDE_SETTINGS_FILE="$TEST_TMP/settings.json"
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
}

teardown() {
	unset CLAUDE_SETTINGS_FILE
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */register-hook.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# --- arg parsing ------------------------------------------------------

@test "register-hook.sh exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"register/unregister"* ]]
	[[ $output == *"# event:"* ]]
	[[ $output == *"Exit codes"* ]]
}

@test "unknown flag rejected with exit 2" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}

@test "--unregister without value rejected with exit 2" {
	run "$SCRIPT" --unregister
	[ "$status" -eq 2 ]
	[[ $output == *"requires a hook path"* ]]
}

@test "no hook paths supplied refused with exit 2" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"no hook paths supplied"* ]]
}

@test "non-existent hook path refused with exit 2" {
	run "$SCRIPT" hooks/does-not-exist.sh
	[ "$status" -eq 2 ]
	[[ $output == *"hook file not found"* ]]
}

# --- frontmatter parsing + register ----------------------------------

@test "register hook with event-only frontmatter" {
	run "$SCRIPT" hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ]
	[[ $output == *"event=SessionStart"* ]]
	# Verify settings.json has the entry
	registered=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
	[[ $registered == *"hooks/cr-auto-parse-poll.sh"* ]]
}

@test "register hook with event + matcher frontmatter" {
	run "$SCRIPT" hooks/phase1-directive-pending-guard.sh
	[ "$status" -eq 0 ]
	[[ $output == *"matcher=Bash|Edit|Write|MultiEdit|NotebookEdit"* ]]
	matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$CLAUDE_SETTINGS_FILE")
	[ "$matcher" = "Bash|Edit|Write|MultiEdit|NotebookEdit" ]
}

@test "register hook with packed 'PreToolUse Bash' event splits to event + matcher" {
	run "$SCRIPT" hooks/ship-cycle-director-gate.sh
	[ "$status" -eq 0 ]
	[[ $output == *"event=PreToolUse"* ]]
	[[ $output == *"matcher=Bash"* ]]
}

@test "idempotent: re-registering same hook doesn't duplicate" {
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	count=$(jq '.hooks.SessionStart[0].hooks | length' "$CLAUDE_SETTINGS_FILE")
	[ "$count" = "1" ]
}

@test "registering 2 different hooks under same matcher coexists" {
	# Register one from the plugin repo
	cd "${BATS_TEST_DIRNAME}/../../.."
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	# Set up a 2nd fake hook in its own git repo + register from there
	mkdir -p "$TEST_TMP/repo/hooks"
	cd "$TEST_TMP/repo" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	cat >hooks/test-sessionstart.sh <<-'EOF'
		#!/bin/bash
		set -euo pipefail
		# event: SessionStart
		echo "test"
	EOF
	chmod +x hooks/test-sessionstart.sh
	git add . >/dev/null
	git commit -q -m "initial"
	"$SCRIPT" hooks/test-sessionstart.sh
	count=$(jq '.hooks.SessionStart[0].hooks | length' "$CLAUDE_SETTINGS_FILE")
	[ "$count" = "2" ]
}

# --- unregister -------------------------------------------------------

@test "--unregister removes the entry" {
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	"$SCRIPT" --unregister hooks/cr-auto-parse-poll.sh
	count=$(jq '.hooks.SessionStart // [] | length' "$CLAUDE_SETTINGS_FILE")
	[ "$count" = "0" ]
}

@test "--unregister on never-registered hook is a no-op (idempotent)" {
	run "$SCRIPT" --unregister hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ]
	[[ $output == *"no-op"* ]]
}

# --- --all-auto-register ----------------------------------------------

@test "--all-auto-register registers only hooks with the sentinel" {
	# Only ship-cycle-director-gate.sh has the # auto-register: true sentinel today
	run "$SCRIPT" --all-auto-register
	[ "$status" -eq 0 ]
	[[ $output == *"ship-cycle-director-gate.sh"* ]]
	# Verify ONLY that one landed (cr-auto-parse-poll lacks the sentinel)
	commands=$(jq -r '[.hooks // {} | to_entries[] | .value[] | (.hooks // [])[] | .command] | join(" ")' "$CLAUDE_SETTINGS_FILE")
	[[ $commands == *"ship-cycle-director-gate.sh"* ]]
	[[ $commands != *"cr-auto-parse-poll.sh"* ]]
}

# --- --dry-run --------------------------------------------------------

@test "--dry-run does not modify settings.json" {
	checksum_before=$(shasum -a 256 "$CLAUDE_SETTINGS_FILE" | awk '{print $1}')
	run "$SCRIPT" --dry-run hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ]
	[[ $output == *"[dry-run]"* ]]
	checksum_after=$(shasum -a 256 "$CLAUDE_SETTINGS_FILE" | awk '{print $1}')
	[ "$checksum_before" = "$checksum_after" ]
}

# --- --check (drift detection) ---------------------------------------

@test "--check clean returns 0" {
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	run "$SCRIPT" --check
	[ "$status" -eq 0 ]
	[[ $output == *"drift=0"* ]]
}

@test "--check detects orphaned settings ref (file missing)" {
	# Manually inject a ref to a non-existent hook
	jq '.hooks = {"SessionStart": [{"matcher":"","hooks":[{"type":"command","command":"/tmp/hooks/ghost.sh"}]}]}' \
		"$CLAUDE_SETTINGS_FILE" >"$CLAUDE_SETTINGS_FILE.tmp"
	mv "$CLAUDE_SETTINGS_FILE.tmp" "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
	[ "$status" -eq 1 ]
	[[ $output == *"ghost.sh"* ]]
	[[ $output == *"does not exist"* ]]
}

# --- error handling ---------------------------------------------------

@test "malformed settings.json refused with exit 3" {
	echo 'not json' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 3 ]
	[[ $output == *"malformed JSON"* ]]
}

@test "missing settings.json is created with empty hooks" {
	rm -f "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ]
	[ -f "$CLAUDE_SETTINGS_FILE" ]
	[[ $(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE") == *"cr-auto-parse-poll.sh"* ]]
}

@test "hook with no '# event:' frontmatter refused" {
	# Need a git repo so the script's REPO_ROOT resolve doesn't fail.
	mkdir -p "$TEST_TMP/repo/hooks"
	cd "$TEST_TMP/repo" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	cat >hooks/no-event.sh <<-'EOF'
		#!/bin/bash
		# this hook has no event declaration
		echo "x"
	EOF
	chmod +x hooks/no-event.sh
	git add . >/dev/null
	git commit -q -m "initial"
	run "$SCRIPT" hooks/no-event.sh
	[ "$status" -eq 2 ]
	[[ $output == *"no '# event:' frontmatter"* ]]
}
