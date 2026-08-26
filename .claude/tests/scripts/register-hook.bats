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
	# Isolated launcher dir for EVERY test, set once here rather than exported
	# per-test: registration resolves onto a launcher when one exists, so without
	# isolation a test would depend on the developer's real ~/.claude launcher
	# dir. Hoisting it also avoids SC2030/SC2031 (each @test is a subshell, so a
	# per-test export is local to it and shellcheck flags the pattern).
	export PLUGIN_LAUNCHER_DIR="$TEST_TMP/launchers"
	mkdir -p "$PLUGIN_LAUNCHER_DIR"
}

teardown() {
	unset CLAUDE_SETTINGS_FILE
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */register-hook.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Assertions that ACTUALLY FAIL wherever they appear. A bare `[[ ]]` only
# fails a bats test when it is the LAST command: bats detects failure via an
# ERR trap, and on bash 3.2 a failing conditional fires neither that trap nor
# `set -e`. Named `assert_*` — the bats convention, and what pre-commit
# bats-gate counts, so replacing a fragile check with a real one reads as the
# strengthening it is.
assert_output_contains() { # $1 = substring $output must contain
	case "$output" in
	*"$1"*) return 0 ;;
	esac
	echo "expected to find: $1"
	echo "actual output   : $output"
	return 1
}
assert_output_lacks() { # $1 = substring $output must NOT contain
	case "$output" in
	*"$1"*)
		echo "expected NOT to find: $1"
		echo "actual output       : $output"
		return 1
		;;
	esac
	return 0
}
assert_not_in() { # $1 = haystack, $2 = substring it must NOT contain
	case "$1" in
	*"$2"*)
		echo "expected NOT to find: $2"
		echo "actual              : $1"
		return 1
		;;
	esac
	return 0
}

# --- arg parsing ------------------------------------------------------

@test "register-hook.sh exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"register/unregister"* ]] || return 1
	[[ $output == *"# event:"* ]] || return 1
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
	[[ $output == *"event=SessionStart"* ]] || return 1
	# Verify settings.json has the entry.
	# (#2536) Assert the BASENAME, not a `hooks/<name>.sh` substring: the command
	# is now a version-agnostic launcher (`<launcher-dir>/<name>.sh`) whenever one
	# exists, and only falls back to a `…/hooks/<name>.sh` path when it does not.
	# The old substring encoded the version-pinned contract this change removes.
	registered=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")
	# `|| return 1`: bats has no set -e, so this middle assertion would otherwise
	# be masked by the `[ -x ]` that follows it (CR-in-CI #2540).
	[[ $registered == */cr-auto-parse-poll.sh ]] || return 1
	# whichever form it took, it must point at something real
	[ -x "$registered" ] || return 1
}

@test "register hook with event + matcher frontmatter" {
	run "$SCRIPT" hooks/phase1-directive-pending-guard.sh
	[ "$status" -eq 0 ]
	[[ $output == *"matcher=Bash|Edit|Write|MultiEdit|NotebookEdit"* ]] || return 1
	matcher=$(jq -r '.hooks.PreToolUse[0].matcher' "$CLAUDE_SETTINGS_FILE")
	[ "$matcher" = "Bash|Edit|Write|MultiEdit|NotebookEdit" ]
}

@test "register hook with packed 'PreToolUse Bash' event splits to event + matcher" {
	run "$SCRIPT" hooks/ship-cycle-director-gate.sh
	[ "$status" -eq 0 ]
	[[ $output == *"event=PreToolUse"* ]] || return 1
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

@test "--unregister does NOT delete a same-named hook from an unrelated path (#2540)" {
	# Basename-only matching over-matches: an operator's own hook that merely
	# shares a filename lives in a path we do not own, and unregister must not
	# reach into the global settings.json and delete it. Only paths under the
	# launcher dir, or legacy `…/hooks/<name>.sh` pinned paths, are ours.
	printf '#!/usr/bin/env bash\nexit 0\n' >"$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	chmod +x "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	# Add a FOREIGN registration with the SAME basename, under a path we don't own.
	local foreign="$TEST_TMP/my-own-tools/cr-auto-parse-poll.sh"
	mkdir -p "$TEST_TMP/my-own-tools"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$foreign"
	chmod +x "$foreign"
	jq --arg f "$foreign" \
		'.hooks.SessionStart[0].hooks += [{type:"command",command:$f}]' \
		"$CLAUDE_SETTINGS_FILE" >"$TEST_TMP/s.json"
	mv "$TEST_TMP/s.json" "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --unregister hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ] || return 1
	# ours is gone…
	run jq -r '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(test("/launchers/"))) | length' "$CLAUDE_SETTINGS_FILE"
	[ "$status" -eq 0 ] || return 1 # jq itself must succeed, not just match
	[ "$output" = "0" ] || return 1
	# …and the FOREIGN one survives untouched
	run jq -r --arg f "$foreign" '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(. == $f)) | length' "$CLAUDE_SETTINGS_FILE"
	[ "$status" -eq 0 ] || return 1 # jq itself must succeed, not just match
	[ "$output" = "1" ] || {
		echo "foreign same-named hook was wrongly deleted"
		return 1
	}
}

@test "--unregister run FROM A CONSUMER repo spares that consumer's hooks/ (#2540)" {
	# REPO_ROOT resolves from the CALLER's cwd, so keying "plugin-owned" on it
	# meant running this script from a consumer repo made THAT repo's hooks/ dir
	# look like ours — and unregister would delete the consumer's own
	# same-basename registration from the GLOBAL settings.json. Ownership must be
	# derived from the script's own location (PLUGIN_ROOT via BASH_SOURCE).
	printf '#!/usr/bin/env bash\nexit 0\n' >"$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	chmod +x "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	# Build a CONSUMER repo with a same-named hook and register it by hand.
	local consumer="$TEST_TMP/consumer"
	mkdir -p "$consumer/hooks"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$consumer/hooks/cr-auto-parse-poll.sh"
	chmod +x "$consumer/hooks/cr-auto-parse-poll.sh"
	(cd "$consumer" && git init -q && git config user.email t@t && git config user.name t)
	# Register the PHYSICAL path. On macOS $TMPDIR is /var/... while
	# `git rev-parse --show-toplevel` (and pwd -P) return /private/var/..., so a
	# registration written with the logical path can never string-match the
	# script's resolved root — the comparison would be vacuously false and this
	# test would pass no matter what the code does. Mutation testing caught
	# exactly that: swapping PLUGIN_ROOT back to REPO_ROOT left the suite green.
	local consumer_phys
	consumer_phys=$(cd "$consumer" && pwd -P)
	jq --arg c "$consumer_phys/hooks/cr-auto-parse-poll.sh" \
		'.hooks.SessionStart[0].hooks += [{type:"command",command:$c}]' \
		"$CLAUDE_SETTINGS_FILE" >"$TEST_TMP/s.json"
	mv "$TEST_TMP/s.json" "$CLAUDE_SETTINGS_FILE"
	# Invoke the plugin's script FROM INSIDE the consumer repo.
	run bash -c "cd '$consumer' && '$SCRIPT' --unregister hooks/cr-auto-parse-poll.sh"
	[ "$status" -eq 0 ] || return 1
	# the CONSUMER's own hook must survive
	run jq -r --arg c "$consumer_phys/hooks/cr-auto-parse-poll.sh" \
		'[.hooks.SessionStart[]?.hooks[]?.command] | map(select(. == $c)) | length' "$CLAUDE_SETTINGS_FILE"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "1" ] || {
		echo "consumer's own hooks/ registration was wrongly deleted"
		return 1
	}
}

@test "--unregister spares a THIRD-PARTY tool that also uses a hooks/ dir (#2540)" {
	# A bare `/hooks/` test is not "plugin-owned": plenty of tools keep their own
	# hooks/ directory. Only the doubled plugin-cache segment + semver (the shape
	# install-hook-launchers.sh migrates) counts as legacy-ours.
	printf '#!/usr/bin/env bash\nexit 0\n' >"$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	chmod +x "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	"$SCRIPT" hooks/cr-auto-parse-poll.sh
	local third="$TEST_TMP/some-other-tool/hooks/cr-auto-parse-poll.sh"
	local ours_legacy="$TEST_TMP/c/claude-workflow-core/claude-workflow-core/0.34.108/hooks/cr-auto-parse-poll.sh"
	mkdir -p "$(dirname "$third")" "$(dirname "$ours_legacy")"
	jq --arg t "$third" --arg o "$ours_legacy" \
		'.hooks.SessionStart[0].hooks += [{type:"command",command:$t},{type:"command",command:$o}]' \
		"$CLAUDE_SETTINGS_FILE" >"$TEST_TMP/s.json"
	mv "$TEST_TMP/s.json" "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --unregister hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ] || return 1
	# the THIRD-PARTY hooks/ path must survive — it is not ours
	run jq -r --arg t "$third" '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(. == $t)) | length' "$CLAUDE_SETTINGS_FILE"
	[ "$status" -eq 0 ] || return 1 # jq itself must succeed, not just match
	[ "$output" = "1" ] || {
		echo "third-party hooks/ path was wrongly deleted"
		return 1
	}
	# our LEGACY version-pinned plugin-cache path must be removed
	run jq -r --arg o "$ours_legacy" '[.hooks.SessionStart[]?.hooks[]?.command] | map(select(. == $o)) | length' "$CLAUDE_SETTINGS_FILE"
	[ "$status" -eq 0 ] || return 1 # jq itself must succeed, not just match
	[ "$output" = "0" ] || {
		echo "our legacy pinned path was NOT removed"
		return 1
	}
}

@test "--unregister removes a launcher-based entry even after the launcher is GC'd (#2540)" {
	# Regression: _unregister_one matched the RESOLVED command path. Once a
	# launcher is pruned, _resolve_hook_command returns a version-pinned fallback
	# that no longer equals the registered launcher path, so unregister silently
	# no-oped and left a stale registration active. Match by BASENAME instead.
	# `|| return 1` on each assertion — bats has no set -e, middle checks must abort.
	# a real, executable launcher so register resolves ONTO it
	printf '#!/usr/bin/env bash\nexit 0\n' >"$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	chmod +x "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	run "$SCRIPT" hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ] || return 1
	# the registered command must be the launcher path (proves the setup is real)
	run jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
	[ "$status" -eq 0 ] || return 1 # jq itself must succeed, not just match
	[[ $output == "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh" ]] || return 1
	# GC the launcher — _resolve_hook_command can now only return the fallback
	rm -f "$PLUGIN_LAUNCHER_DIR/cr-auto-parse-poll.sh"
	# Assert the unregister itself SUCCEEDED before trusting the count below — a
	# non-zero exit with an unchanged settings.json would otherwise read as a pass
	# via the count assertion alone (CR-in-CI #2540).
	run "$SCRIPT" --unregister hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ] || return 1
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
	[[ $output == *"ship-cycle-director-gate.sh"* ]] || return 1
	commands=$(jq -r '[.hooks // {} | to_entries[] | .value[] | (.hooks // [])[] | .command] | join(" ")' "$CLAUDE_SETTINGS_FILE")
	[[ $commands == *"ship-cycle-director-gate.sh"* ]] || return 1
	# v0.24.0: assert ALL 6 expected sentinel hooks land (data-driven
	# expansion replaces the old hardcoded 3-element set). Test now
	# enforces the full SSOT set rather than just asserting one.
	[[ $commands == *"cr-auto-parse-poll.sh"* ]] || return 1
	[[ $commands == *"monitor-misuse-block.sh"* ]] || return 1
	[[ $commands == *"session-start-stale-pin.sh"* ]] || return 1
	[[ $commands == *"ship-cycle-guard.sh"* ]] || return 1
	# phase1-directive-pending-guard.sh was DELIBERATELY de-registered on
	# 2026-08-24 (#2544/#2564) — it assumed synchronous Agent returns, which
	# the async harness broke, and its header now says `auto-register: false`
	# precisely so the installer cannot re-wire it. This test still demanded
	# it, and stayed green because a mid-test `[[ ]]` is a no-op on bash 3.2.
	# Asserting its ABSENCE turns a stale expectation into a guard for the
	# decision: if someone flips the sentinel back on, this fails and they
	# have to mean it.
	assert_not_in "$commands" "phase1-directive-pending-guard.sh"
}

# --- --dry-run --------------------------------------------------------

@test "--dry-run does not modify settings.json" {
	checksum_before=$(shasum -a 256 "$CLAUDE_SETTINGS_FILE" | awk '{print $1}')
	run "$SCRIPT" --dry-run hooks/cr-auto-parse-poll.sh
	[ "$status" -eq 0 ]
	[[ $output == *"[dry-run]"* ]] || return 1
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
	[[ $output == *"ghost.sh"* ]] || return 1
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
	[[ $output == *"ship-cycle-director-gate.sh"* ]] || return 1
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
