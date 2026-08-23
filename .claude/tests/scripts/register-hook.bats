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
	# Verify settings.json has the entry.
	# (#2536) Assert the BASENAME, not a `hooks/<name>.sh` substring: the command
	# is now a version-agnostic launcher (`<launcher-dir>/<name>.sh`) whenever one
	# exists, and only falls back to a `…/hooks/<name>.sh` path when it does not.
	# The old substring encoded the version-pinned contract this change removes.
	registered=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
	[[ $registered == */cr-auto-parse-poll.sh ]]
	# whichever form it took, it must point at something real
	[ -x "$registered" ]
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

@test "--unregister removes a launcher-based entry even after the launcher is GC'd (#2540)" {
	# Regression: _unregister_one matched the RESOLVED command path. Once a
	# launcher is pruned, _resolve_hook_command returns a version-pinned fallback
	# that no longer equals the registered launcher path, so unregister silently
	# no-oped and left a stale registration active. Match by BASENAME instead.
	# `|| return 1` on each assertion — bats has no set -e, middle checks must abort.
	export PLUGIN_LAUNCHER_DIR="$TEST_TMP/launchers"
	mkdir -p "$PLUGIN_LAUNCHER_DIR"
	# a real, executable launcher so register resolves ONTO it
	printf '#!/usr/bin/env bash\nexit 0\n' >"$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	chmod +x "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	run "$SCRIPT" hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ] || return 1
	# the registered command must be the launcher path (proves the setup is real)
	run jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
	[[ $output == "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh" ]] || return 1
	# GC the launcher — _resolve_hook_command can now only return the fallback
	rm -f "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	"$SCRIPT" --unregister hooks/cr-auto-parse-poll.sh
	# Parenthesize so BOTH a missing key AND an existing empty array yield 0 —
	# `.hooks.SessionStart // [] | length` without parens is fine in jq (// binds
	# tighter than |), but the explicit group documents intent and is robust to a
	# future filter change (CR-in-CI #2540).
	count=$(jq '(.hooks.SessionStart // []) | length' "$CLAUDE_SETTINGS_FILE")
	[ "$count" = "0" ] || return 1
}

# --- --all-auto-register ----------------------------------------------

@test "--all-auto-register registers only hooks with the sentinel" {
	# v0.24.0 #150: data-driven discovery expanded the set; multiple
	# hooks now declare `# auto-register: true` — assert each lands AND
	# that hooks lacking the sentinel (e.g. install-hooks.sh which has
	# only doc-mention of the directive in a comment, monitor-misuse-
	# block.sh which has the directive at the top) behave as expected.
	run "$SCRIPT" --all-auto-register
	[ "$status" -eq 0 ]
	# At least ship-cycle-director-gate must register (longest-tenured
	# sentinel hook).
	[[ $output == *"ship-cycle-director-gate.sh"* ]]
	commands=$(jq -r '[.hooks // {} | to_entries[] | .value[] | (.hooks // [])[] | .command] | join(" ")' "$CLAUDE_SETTINGS_FILE")
	[[ $commands == *"ship-cycle-director-gate.sh"* ]]
	# v0.24.0: assert ALL 6 expected sentinel hooks land (data-driven
	# expansion replaces the old hardcoded 3-element set). Test now
	# enforces the full SSOT set rather than just asserting one.
	[[ $commands == *"cr-auto-parse-poll.sh"* ]]
	[[ $commands == *"phase1-directive-pending-guard.sh"* ]]
	[[ $commands == *"monitor-misuse-block.sh"* ]]
	[[ $commands == *"session-start-stale-pin.sh"* ]]
	[[ $commands == *"ship-cycle-guard.sh"* ]]
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

@test "--check clean returns 0 (all sentinel hooks registered + no orphans)" {
	# Must register every hook with `# auto-register: true` to be clean.
	"$SCRIPT" --all-auto-register
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

@test "register preserves pre-existing hooks under different events" {
	# Pre-populate with an unrelated hook entry (e.g. PostToolUse)
	jq '.hooks = {"PostToolUse": [{"matcher":"","hooks":[{"type":"command","command":"/x/sibling.sh"}]}]}' \
		"$CLAUDE_SETTINGS_FILE" >"$CLAUDE_SETTINGS_FILE.tmp"
	mv "$CLAUDE_SETTINGS_FILE.tmp" "$CLAUDE_SETTINGS_FILE"
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	# Both should coexist
	[ "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")" = "/x/sibling.sh" ]
	[[ $(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE") == *"cr-auto-parse-poll.sh"* ]]
}

@test "--check detects unregistered auto-register hook (bidirectional drift)" {
	# Plugin has ship-cycle-director-gate.sh with auto-register:true; with
	# empty settings.json, --check should flag the unregistered direction.
	echo '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
	[ "$status" -eq 1 ]
	[[ $output == *"ship-cycle-director-gate.sh"* ]]
	[[ $output == *"not in settings.json"* ]]
}

@test "register-hook handles paths with embedded spaces" {
	# jq's --arg should round-trip arbitrary strings; verify with a
	# space-containing fixture path.
	mkdir -p "$TEST_TMP/repo with space/hooks"
	cd "$TEST_TMP/repo with space" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	cat >hooks/spaced.sh <<-'EOF'
		#!/bin/bash
		set -euo pipefail
		# event: SessionStart
		echo "spaced"
	EOF
	chmod +x hooks/spaced.sh
	git add . >/dev/null
	git commit -q -m "initial"
	"$SCRIPT" hooks/spaced.sh
	cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
	[[ $cmd == *"repo with space/hooks/spaced.sh" ]]
}

@test "frontmatter with trailing whitespace stripped (silent-mismatch guard)" {
	mkdir -p "$TEST_TMP/repo/hooks"
	cd "$TEST_TMP/repo" || return 1
	git init -q
	git config user.email "test@test"
	git config user.name "test"
	# Trailing space after event name — must be stripped
	printf '#!/bin/bash\nset -euo pipefail\n# event: SessionStart   \necho ok\n' >hooks/trail.sh
	chmod +x hooks/trail.sh
	git add . >/dev/null
	git commit -q -m "initial"
	"$SCRIPT" hooks/trail.sh
	# Key in settings.json should be exactly "SessionStart" (no trailing whitespace)
	[ -n "$(jq -r '.hooks.SessionStart // null' "$CLAUDE_SETTINGS_FILE")" ]
	# Verify the trailing-whitespace key was NOT created
	[ "$(jq -r '.hooks | keys[]' "$CLAUDE_SETTINGS_FILE" | grep -c 'SessionStart$')" = "1" ]
}

@test "--check on malformed settings.json refused with exit 3" {
	echo 'not json' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --check
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
