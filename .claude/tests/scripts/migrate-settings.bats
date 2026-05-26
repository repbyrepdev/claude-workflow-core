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

# Helper: write a settings.json with two 0.8.5 hook command paths.
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

@test "TO_VER auto-detect ignores non-semver dirs in cache base" {
	# CR finding: prior `sort -V | tail -1` would pick a name like 'tmp'
	# or 'current' if such dirs existed under the cache base. Filter
	# must reject anything not matching X.Y.Z.
	_write_legacy_settings
	mkdir -p "$PLUGIN_CACHE_BASE/tmp" "$PLUGIN_CACHE_BASE/current"
	run "$SCRIPT" --dry-run
	[ "$status" -eq 0 ]
	# Should still pick 0.8.8 (the highest semver), not 'tmp' or 'current'
	[[ $output == *"→ 0.8.8"* ]]
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

# Helper: install a fake migrate-settings + stub register-hook into a
# tmpdir so tests can exercise the sibling-script delegation path with
# controlled behavior (missing/failing register-hook.sh).
_install_fake_layout() {
	local register_behavior=$1    # 'success' | 'fail' | 'missing'
	local hooks_present=${2:-yes} # 'yes' | 'no' (../hooks/<name>.sh existence)
	local fakedir="$TEST_TMP/fakerepo/scripts"
	mkdir -p "$fakedir"
	cp "$SCRIPT" "$fakedir/migrate-settings.sh"
	chmod +x "$fakedir/migrate-settings.sh"
	if [ "$register_behavior" != "missing" ]; then
		# Stub: write the path-args to a log file so the test can assert
		# the call shape. Behavior is success unless 'fail'.
		cat >"$fakedir/register-hook.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "stub-register-hook called: \$*" >"$TEST_TMP/register-hook.log"
EOF
		if [ "$register_behavior" = "fail" ]; then
			echo "exit 1" >>"$fakedir/register-hook.sh"
		fi
		chmod +x "$fakedir/register-hook.sh"
	fi
	if [ "$hooks_present" = "yes" ]; then
		mkdir -p "$TEST_TMP/fakerepo/hooks"
		for h in cr-auto-parse-poll phase1-directive-pending-guard ship-cycle-director-gate; do
			# Real hook frontmatter — needed by register-hook.sh
			cat >"$TEST_TMP/fakerepo/hooks/$h.sh" <<EOF
#!/bin/bash
# event: PreToolUse
# matcher: Bash
echo "stub-hook"
EOF
			chmod +x "$TEST_TMP/fakerepo/hooks/$h.sh"
		done
	fi
	echo "$fakedir/migrate-settings.sh"
}

@test "version bump rewrites all matching path refs + invokes register-hook.sh" {
	_write_legacy_settings
	fake=$(_install_fake_layout success yes)
	run "$fake" --from 0.8.5 --to 0.8.8
	[ "$status" -eq 0 ]
	# Version bump applied
	count_old=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| select(contains("/claude-workflow-core/0.8.5/"))] | length
	' "$CLAUDE_SETTINGS_FILE")
	count_new=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| select(contains("/claude-workflow-core/0.8.8/"))] | length
	' "$CLAUDE_SETTINGS_FILE")
	[ "$count_old" -eq 0 ]
	[ "$count_new" -eq 2 ]
	# Stub register-hook.sh was invoked with all 3 hook paths
	[ -f "$TEST_TMP/register-hook.log" ]
	log=$(cat "$TEST_TMP/register-hook.log")
	[[ $log == *"cr-auto-parse-poll"* ]]
	[[ $log == *"phase1-directive-pending-guard"* ]]
	[[ $log == *"ship-cycle-director-gate"* ]]
}

@test "missing register-hook.sh sibling → exit 2" {
	_write_legacy_settings
	fake=$(_install_fake_layout missing yes)
	run "$fake" --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"register-hook.sh not found"* ]]
}

@test "register-hook.sh non-zero exit → exit 3 + partial-state guidance" {
	_write_legacy_settings
	fake=$(_install_fake_layout fail yes)
	run "$fake" --from 0.8.5 --to 0.8.8
	[ "$status" -eq 3 ]
	[[ $output == *"hook registration FAILED"* ]]
	[[ $output == *"partial-migration state"* ]]
	# Version bump WAS committed before the failure
	count_new=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| select(contains("/claude-workflow-core/0.8.8/"))] | length
	' "$CLAUDE_SETTINGS_FILE")
	[ "$count_new" -eq 2 ]
}

@test "ALL hooks missing → loud warning + Step 2 skipped" {
	_write_legacy_settings
	fake=$(_install_fake_layout success no)
	run "$fake" --from 0.8.5 --to 0.8.8
	[ "$status" -eq 0 ]
	[[ $output == *"none of the"* ]]
	[[ $output == *"expected hook files exist"* ]]
	# register-hook stub was NOT invoked (no log file)
	[ ! -f "$TEST_TMP/register-hook.log" ]
}

@test "from==to no-op: settings.json content unchanged" {
	_write_legacy_settings
	fake=$(_install_fake_layout success no) # hooks absent → Step 2 skipped
	before=$(jq -S . "$CLAUDE_SETTINGS_FILE" | shasum -a 256 | cut -d' ' -f1)
	run "$fake" --from 0.8.8 --to 0.8.8
	[ "$status" -eq 0 ]
	after=$(jq -S . "$CLAUDE_SETTINGS_FILE" | shasum -a 256 | cut -d' ' -f1)
	# from == to means no refs match (the legacy settings has 0.8.5 refs,
	# not 0.8.8). Content should be byte-identical.
	[ "$before" = "$after" ]
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

@test "no version refs in settings + explicit --to → reports SKIPPED bump" {
	# Replaces the prior loose-OR test. Asserts the auto-detect branch
	# explicitly emits the SKIPPED label (post-fix) AND that Migration
	# complete is reached.
	echo '{"hooks":{}}' >"$CLAUDE_SETTINGS_FILE"
	fake=$(_install_fake_layout success no) # hooks absent → Step 2 also skipped
	run "$fake" --to 0.8.8
	[ "$status" -eq 0 ]
	[[ $output == *"NOTE: no claude-workflow-core version refs"* ]]
	[[ $output == *"SKIPPED (no refs found)"* ]]
	[[ $output == *"Migration complete"* ]]
}

@test "no version refs in settings → Step 1 inode unchanged (no spurious mv)" {
	# When SKIP_BUMP is set, the mktemp + mv path is skipped entirely
	# so the inode + mtime stay stable. Catches a regression where a
	# future refactor reintroduces a no-op write.
	echo '{"hooks":{}}' >"$CLAUDE_SETTINGS_FILE"
	inode_before=$(stat -f '%i' "$CLAUDE_SETTINGS_FILE" 2>/dev/null || stat -c '%i' "$CLAUDE_SETTINGS_FILE")
	fake=$(_install_fake_layout success no)
	run "$fake" --to 0.8.8
	[ "$status" -eq 0 ]
	inode_after=$(stat -f '%i' "$CLAUDE_SETTINGS_FILE" 2>/dev/null || stat -c '%i' "$CLAUDE_SETTINGS_FILE")
	[ "$inode_before" = "$inode_after" ]
}
