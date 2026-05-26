#!/usr/bin/env bats
# covers: pre-commit-hooks/event-frontmatter-check.sh
#
# Tests for the event-frontmatter parity gate (#70). Verifies the gate
# fires on BOTH consumer-layout (`.claude/hooks/*.sh`) AND plugin-source-
# layout (`hooks/*.sh`) paths, skips opt-out forms, and accepts hooks
# with valid frontmatter.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/event-frontmatter-check.sh"
	TEST_TMP=$(mktemp -d -t event-fm.XXXXXX) || {
		echo "FATAL: mktemp -d failed" >&2
		return 1
	}
	# Init a fake repo so `git rev-parse --show-toplevel` inside the
	# hook resolves to a directory under our control.
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email "test@example.com"
		git config user.name "Test"
	)
}

teardown() {
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */event-fm.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helpers
_write_hook_no_frontmatter() {
	local path=$1
	mkdir -p "$(dirname "$TEST_TMP/$path")"
	cat >"$TEST_TMP/$path" <<'EOF'
#!/bin/bash
set -euo pipefail
echo "no frontmatter"
EOF
	chmod +x "$TEST_TMP/$path"
}

_write_hook_with_frontmatter() {
	local path=$1
	local event=$2
	mkdir -p "$(dirname "$TEST_TMP/$path")"
	cat >"$TEST_TMP/$path" <<EOF
#!/bin/bash
set -euo pipefail
# event: $event
echo "valid hook"
EOF
	chmod +x "$TEST_TMP/$path"
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

# --- consumer layout: .claude/hooks/*.sh ----------------------------

@test "consumer-layout: missing frontmatter fails" {
	_write_hook_no_frontmatter ".claude/hooks/bad.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" .claude/hooks/bad.sh
	cd "$cwd"
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
}

@test "consumer-layout: valid frontmatter passes" {
	_write_hook_with_frontmatter ".claude/hooks/good.sh" "PreToolUse"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" .claude/hooks/good.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

# --- plugin-source layout: hooks/*.sh (#70) -------------------------

@test "plugin-source-layout: missing frontmatter fails" {
	# #70 extension: the gate must cover the plugin's own source-tree
	# hooks/ dir, not just consumer .claude/hooks/.
	_write_hook_no_frontmatter "hooks/bad.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" hooks/bad.sh
	cd "$cwd"
	[ "$status" -eq 1 ]
	[[ $output == *"lack required frontmatter"* ]]
	[[ $output == *"hooks/bad.sh"* ]]
}

@test "plugin-source-layout: valid frontmatter passes" {
	_write_hook_with_frontmatter "hooks/good.sh" "PreToolUse"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" hooks/good.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

@test "plugin-source-layout: SessionStart event accepted" {
	_write_hook_with_frontmatter "hooks/session.sh" "SessionStart"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" hooks/session.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

# --- excluded paths ------------------------------------------------

@test "pre-commit-hooks/*.sh is NOT subject to the gate" {
	# Different lifecycle — pre-commit-hooks/ scripts are registered
	# via entry: in .pre-commit-hooks.yaml, not via # event: frontmatter.
	_write_hook_no_frontmatter "pre-commit-hooks/something.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" pre-commit-hooks/something.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

@test "filename _*.sh helper opt-out (plugin-source layout)" {
	_write_hook_no_frontmatter "hooks/_helper.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" hooks/_helper.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

@test "filename install-*.sh installer opt-out (plugin-source layout)" {
	_write_hook_no_frontmatter "hooks/install-something.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" hooks/install-something.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

@test "explicit auto-register:false opt-out" {
	mkdir -p "$TEST_TMP/hooks"
	cat >"$TEST_TMP/hooks/opt-out.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
# auto-register: false
echo "helper called by other hooks"
EOF
	chmod +x "$TEST_TMP/hooks/opt-out.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run "$SCRIPT" hooks/opt-out.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
}

# --- EVENT_FRONTMATTER_SKIP bypass --------------------------------

@test "EVENT_FRONTMATTER_SKIP=1 bypasses with stderr warning" {
	_write_hook_no_frontmatter "hooks/missing.sh"
	cwd=$PWD
	cd "$TEST_TMP"
	run env EVENT_FRONTMATTER_SKIP=1 "$SCRIPT" hooks/missing.sh
	cd "$cwd"
	[ "$status" -eq 0 ]
	[[ $output == *"SKIP via EVENT_FRONTMATTER_SKIP"* ]]
}
