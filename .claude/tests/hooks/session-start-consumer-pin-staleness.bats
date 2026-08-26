#!/usr/bin/env bats
# covers: hooks/session-start-consumer-pin-staleness.sh
#
# Tests for the SessionStart consumer-pin staleness detector (#2280). Verifies:
# - Stale pin (config rev < cache max) → advisory warn, exit 0
# - Up-to-date (pin == cache max) → silent, exit 0
# - Inverse (pin > cache max) → distinct advisory warn, exit 0
# - Config has no claude-workflow-core repo block → silent
# - No .pre-commit-config / no cache dir → silent pass
# - SESSION_START_CONSUMER_PIN_SKIP=1 → silent
# - Non-semver cache subdirs filtered out by the regex

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/session-start-consumer-pin-staleness.sh"
	TEST_TMP=$(mktemp -d -t consumerpin.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	CONFIG="$TEST_TMP/.pre-commit-config.yaml"
	CACHE_DIR="$TEST_TMP/cache/claude-workflow-core/claude-workflow-core"
	mkdir -p "$CACHE_DIR"
	export SESSION_START_CONSUMER_PIN_CONFIG="$CONFIG"
	export SESSION_START_CONSUMER_PIN_CACHE_DIR="$CACHE_DIR"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */consumerpin.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_config_pinning() {
	# $1 = rev (e.g. v0.34.40); $2 = optional dest path (default $CONFIG).
	# Writes a config with a claude-workflow-core block.
	printf 'repos:\n  - repo: https://github.com/repbyrepdev/claude-workflow-core\n    rev: %s\n    hooks:\n      - id: bash-safety\n' "$1" >"${2:-$CONFIG}"
}

_make_cache() {
	# remaining args = version dir names to create under CACHE_DIR
	local v
	for v in "$@"; do mkdir -p "$CACHE_DIR/$v"; done
}

@test "stale pin (rev < cache max) → advisory warn + exit 0 (#2280)" {
	_write_config_pinning "v0.34.40"
	_make_cache 0.34.40 0.34.49 0.34.7
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"pins claude-workflow-core v0.34.40 but v0.34.49 is installed"* ]] || return 1
	[[ $output == *"Refresh"* ]]
}

@test "up-to-date (rev == cache max) → silent + exit 0 (#2280)" {
	_write_config_pinning "v0.34.49"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "inverse drift (rev > cache max) → distinct warn + exit 0 (#2280)" {
	_write_config_pinning "v0.34.50"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"newest installed release is v0.34.49"* ]] || return 1
	[[ $output == *"plugin cache may be behind"* ]]
}

@test "config has no claude-workflow-core block → silent (#2280)" {
	printf 'repos:\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: v4.0.0\n' >"$CONFIG"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "no .pre-commit-config → silent pass (#2280)" {
	rm -f "$CONFIG"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "no plugin cache dir → silent pass (#2280)" {
	_write_config_pinning "v0.34.40"
	rm -rf "$CACHE_DIR"
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "SESSION_START_CONSUMER_PIN_SKIP=1 → silent (#2280)" {
	_write_config_pinning "v0.34.40"
	_make_cache 0.34.49
	SESSION_START_CONSUMER_PIN_SKIP=1 run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "non-semver cache subdirs filtered → compares only semver (#2280)" {
	_write_config_pinning "v0.34.40"
	_make_cache 0.34.49 latest main
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"but v0.34.49 is installed"* ]]
}

@test "cache present but ONLY non-semver subdirs → silent (#2280)" {
	_write_config_pinning "v0.34.40"
	_make_cache latest main
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "unpinned claude-workflow-core block + later pinned repo → silent (#2280)" {
	# Regression for the awk cross-block rev leak: the claude-workflow-core
	# block has no rev:; the following pre-commit-hooks block does. The hook
	# must NOT grab v4.0.0 for claude-workflow-core.
	printf 'repos:\n  - repo: https://github.com/repbyrepdev/claude-workflow-core\n    hooks:\n      - id: bash-safety\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: v4.0.0\n' >"$CONFIG"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "fork repo (...claude-workflow-core-fork) → NOT matched, silent (#2280)" {
	# Regression for the substring false-match: a different repo whose path
	# merely CONTAINS claude-workflow-core must not be treated as the plugin.
	printf 'repos:\n  - repo: https://github.com/repbyrepdev/claude-workflow-core-fork\n    rev: v0.34.40\n' >"$CONFIG"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "repo URL with .git suffix → matched + warns when stale (#2280)" {
	printf 'repos:\n  - repo: https://github.com/repbyrepdev/claude-workflow-core.git\n    rev: v0.34.40\n' >"$CONFIG"
	_make_cache 0.34.49
	run bash "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ $output == *"but v0.34.49 is installed"* ]]
}

@test "repo-root anchor: resolves config from a SUBDIR via git rev-parse, no override (#2344)" {
	# No SESSION_START_CONSUMER_PIN_CONFIG → the hook must anchor to the repo
	# root. A real git repo with the pinned config at its ROOT, run from a
	# nested subdir, must still surface the staleness advisory.
	local repo="$TEST_TMP/consumer"
	mkdir -p "$repo/deep/nested/subdir"
	# The nested `git init` is LOAD-BEARING for determinism: it makes $repo the
	# nearest work tree, so `git rev-parse --show-toplevel` from the subdir
	# returns $repo regardless of whether $TMPDIR sits inside an outer repo.
	git -C "$repo" init -q
	_write_config_pinning v0.34.40 "$repo/.pre-commit-config.yaml"
	_make_cache 0.34.40 0.34.49
	unset SESSION_START_CONSUMER_PIN_CONFIG
	# Config exists ONLY at the repo root — a $PWD-relative resolution from the
	# subdir would miss it and exit silently, so the advisory proves anchoring.
	run bash -c "cd '$repo/deep/nested/subdir' && bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[[ $output == *"pins claude-workflow-core v0.34.40 but v0.34.49 is installed"* ]]
}

@test "repo-root anchor: up-to-date via repo-root branch → silent (#2344)" {
	# The new branch must also stay SILENT on the happy path (pin == cache max),
	# not only emit the advisory — guards the CONFIG path assembly.
	local repo="$TEST_TMP/uptodate"
	mkdir -p "$repo/sub"
	git -C "$repo" init -q
	_write_config_pinning v0.34.49 "$repo/.pre-commit-config.yaml"
	_make_cache 0.34.49
	unset SESSION_START_CONSUMER_PIN_CONFIG
	run bash -c "cd '$repo/sub' && bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "repo-root anchor: outer repo whose root lacks a config → silent, no over-reach (#2344)" {
	# Anchoring widens the search from $PWD up to the git root. In a subdir of a
	# NON-consumer parent repo (monorepo / $HOME-as-repo) the resolved root has
	# no .pre-commit-config — the hook must stay silent, never false-advise.
	local repo="$TEST_TMP/outer"
	mkdir -p "$repo/sub"
	git -C "$repo" init -q
	# No .pre-commit-config.yaml at the repo root.
	_make_cache 0.34.49
	unset SESSION_START_CONSUMER_PIN_CONFIG
	run bash -c "cd '$repo/sub' && bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test 'repo-root anchor: falls back to $PWD when git is unavailable/not-a-repo (#2344)' {
	# Force the fallback: a git on PATH that always fails (simulates "not a
	# work tree" / git absent). The advisory hook must never error and must
	# read the config at $PWD instead.
	local dir="$TEST_TMP/nongit"
	mkdir -p "$dir/fakebin"
	_write_config_pinning v0.34.40 "$dir/.pre-commit-config.yaml"
	_make_cache 0.34.40 0.34.49
	printf '#!/bin/sh\nexit 1\n' >"$dir/fakebin/git"
	chmod +x "$dir/fakebin/git"
	unset SESSION_START_CONSUMER_PIN_CONFIG
	run bash -c "cd '$dir' && PATH='$dir/fakebin:$PATH' bash '$SCRIPT'"
	[ "$status" -eq 0 ]
	[[ $output == *"pins claude-workflow-core v0.34.40 but v0.34.49 is installed"* ]]
}
