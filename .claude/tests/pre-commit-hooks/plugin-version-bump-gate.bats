#!/usr/bin/env bats
# covers: pre-commit-hooks/plugin-version-bump-gate.sh
#
# Tests for the pre-commit version-bump gate (#87). Verifies that
# staged hook files require a corresponding plugin.json version bump.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/plugin-version-bump-gate.sh"
	TEST_TMP=$(cd "$(mktemp -d -t pv-bump.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Init a real git repo + seed plugin.json + an empty initial commit.
	# `|| return 1` makes subshell failures propagate to setup() (CR
	# r2: prior version swallowed subshell exit, letting setup silently
	# half-complete if any git step failed).
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email "t@x"
		git config user.name "T"
		mkdir -p .claude-plugin hooks
		printf '{"name":"test","version":"0.1.0"}\n' >.claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git commit -q -m "init"
	) || return 1
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */pv-bump.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: run the gate with cwd=TEST_TMP in a subshell
_run_gate() {
	(cd "$TEST_TMP" && bash "$SCRIPT")
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

# --- no hooks staged → passes -------------------------------------

@test "no hook changes staged → passes" {
	# Stage an unrelated file
	(cd "$TEST_TMP" && echo readme >README.md && git add README.md)
	run _run_gate
	[ "$status" -eq 0 ]
}

# --- hooks staged without plugin.json bump → fails ----------------

@test "new hook + no plugin.json staged → FAIL" {
	(
		cd "$TEST_TMP"
		echo '#!/bin/bash' >hooks/new-hook.sh
		echo '# event: PreToolUse' >>hooks/new-hook.sh
		chmod +x hooks/new-hook.sh
		git add hooks/new-hook.sh
	)
	run _run_gate
	[ "$status" -eq 1 ]
	[[ $output == *"staged hook(s) without plugin.json bump"* ]] || return 1
	[[ $output == *"new-hook.sh"* ]]
}

@test "new hook + plugin.json staged but version unchanged → FAIL" {
	(
		cd "$TEST_TMP"
		echo '#!/bin/bash' >hooks/new.sh
		echo '# event: PreToolUse' >>hooks/new.sh
		chmod +x hooks/new.sh
		# Touch plugin.json with the SAME version (e.g. description-only change)
		jq '.description = "updated"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add hooks/new.sh .claude-plugin/plugin.json
	)
	run _run_gate
	[ "$status" -eq 1 ]
	[[ $output == *"version is still"* ]]
}

# --- hooks staged WITH plugin.json bump → passes ------------------

@test "new hook + plugin.json version bumped → passes" {
	(
		cd "$TEST_TMP"
		echo '#!/bin/bash' >hooks/new.sh
		echo '# event: PreToolUse' >>hooks/new.sh
		chmod +x hooks/new.sh
		jq '.version = "0.1.1"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add hooks/new.sh .claude-plugin/plugin.json
	)
	run _run_gate
	[ "$status" -eq 0 ]
}

@test "modified hook + version bumped → passes" {
	# Seed an existing hook first, then modify it + bump
	(
		cd "$TEST_TMP"
		echo '#!/bin/bash' >hooks/existing.sh
		echo '# event: PreToolUse' >>hooks/existing.sh
		chmod +x hooks/existing.sh
		git add hooks/existing.sh
		jq '.version = "0.1.1"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git commit -q -m "seed existing.sh"
		# Now modify the existing hook + bump again
		echo 'echo "modified"' >>hooks/existing.sh
		jq '.version = "0.1.2"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add hooks/existing.sh .claude-plugin/plugin.json
	)
	run _run_gate
	[ "$status" -eq 0 ]
}

# --- downgrade detection ------------------------------------------

@test "plugin.json downgrade → FAIL" {
	(
		cd "$TEST_TMP"
		# Seed a higher version first
		jq '.version = "0.5.0"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git commit -q -m "bump to 0.5.0"
		# Now stage a hook + downgrade plugin.json
		echo '#!/bin/bash' >hooks/n.sh
		echo '# event: PreToolUse' >>hooks/n.sh
		chmod +x hooks/n.sh
		jq '.version = "0.2.0"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add hooks/n.sh .claude-plugin/plugin.json
	)
	run _run_gate
	[ "$status" -eq 1 ]
	[[ $output == *"downgrades version"* ]]
}

# --- bypass -------------------------------------------------------

@test "PLUGIN_VERSION_BUMP_SKIP=1 bypasses + emits audit log" {
	(
		cd "$TEST_TMP"
		echo '#!/bin/bash' >hooks/skip.sh
		echo '# event: PreToolUse' >>hooks/skip.sh
		chmod +x hooks/skip.sh
		git add hooks/skip.sh
	)
	run bash -c "cd '$TEST_TMP' && export PLUGIN_VERSION_BUMP_SKIP=1 && bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"PLUGIN_VERSION_BUMP_SKIP=1"* ]] || return 1
	[[ $output == *"audit logged"* ]]
}

# --- layout + scope coverage --------------------------------------

@test ".claude/hooks/*.sh also triggers gate (consumer layout)" {
	(
		cd "$TEST_TMP"
		mkdir -p .claude/hooks
		echo '#!/bin/bash' >.claude/hooks/new.sh
		echo '# event: PreToolUse' >>.claude/hooks/new.sh
		chmod +x .claude/hooks/new.sh
		git add .claude/hooks/new.sh
	)
	run _run_gate
	[ "$status" -eq 1 ]
	[[ $output == *"new.sh"* ]]
}

@test "modified existing hook + NO bump → FAIL (status M coverage)" {
	(
		cd "$TEST_TMP"
		echo '#!/bin/bash' >hooks/existing.sh
		echo '# event: PreToolUse' >>hooks/existing.sh
		chmod +x hooks/existing.sh
		jq '.version = "0.2.0"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add hooks/existing.sh .claude-plugin/plugin.json
		git commit -q -m "seed existing hook"
		echo 'echo modified' >>hooks/existing.sh
		git add hooks/existing.sh
	)
	run _run_gate
	[ "$status" -eq 1 ]
	[[ $output == *"existing.sh"* ]]
}

@test "nested hooks/sub/x.sh ignored (single-level scope)" {
	(
		cd "$TEST_TMP"
		mkdir -p hooks/sub
		echo '#!/bin/bash' >hooks/sub/nested.sh
		echo '# event: PreToolUse' >>hooks/sub/nested.sh
		chmod +x hooks/sub/nested.sh
		git add hooks/sub/nested.sh
	)
	run _run_gate
	[ "$status" -eq 0 ]
}

@test "non-.sh files under hooks/ ignored (regex specificity)" {
	(
		cd "$TEST_TMP"
		echo doc >hooks/README.md
		git add hooks/README.md
	)
	run _run_gate
	[ "$status" -eq 0 ]
}

@test "downgrade: semver ordering (0.10.0 > 0.9.0, not lex)" {
	(
		cd "$TEST_TMP"
		jq '.version = "0.10.0"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git commit -q -m "bump to 0.10.0"
		echo '#!/bin/bash' >hooks/x.sh
		echo '# event: PreToolUse' >>hooks/x.sh
		chmod +x hooks/x.sh
		jq '.version = "0.9.0"' .claude-plugin/plugin.json >"$TEST_TMP/_pj.json" && mv "$TEST_TMP/_pj.json" .claude-plugin/plugin.json
		git add hooks/x.sh .claude-plugin/plugin.json
	)
	run _run_gate
	[ "$status" -eq 1 ]
	[[ $output == *"downgrades version"* ]]
}

# --- precondition handling -----------------------------------------

@test "no plugin.json (not a plugin repo) → passes through" {
	# Remove plugin.json AFTER setup
	(
		cd "$TEST_TMP"
		rm -rf .claude-plugin
		git add -A
		echo '#!/bin/bash' >hooks/whatever.sh
		echo '# event: PreToolUse' >>hooks/whatever.sh
		git add hooks/whatever.sh
	)
	run _run_gate
	[ "$status" -eq 0 ]
}

@test "malformed plugin.json → exit 2" {
	(
		cd "$TEST_TMP"
		echo 'not json' >.claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		echo '#!/bin/bash' >hooks/x.sh
		echo '# event: PreToolUse' >>hooks/x.sh
		git add hooks/x.sh
	)
	run _run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"malformed JSON"* ]]
}
