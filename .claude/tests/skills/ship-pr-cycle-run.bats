#!/usr/bin/env bats
# covers: skills/ship-pr-cycle/run.sh
#
# v0.34.32 (#2237): the wrapper is LAYOUT-AGNOSTIC (git rev-parse, not ../..
# counting) and, in a CONSUMER repo, resolves + execs the PINNED-CACHE driver
# instead of a local (rot-prone) scripts/ship-pr-cycle.sh. In the PLUGIN repo
# it execs the local driver. This is the root fix for the phase1-nonce desync
# (a stale local consumer driver wrote no nonce → guard deadlock).

setup() {
	WRAPPER="${BATS_TEST_DIRNAME}/../../../skills/ship-pr-cycle/run.sh"
	PIN_LIB="${BATS_TEST_DIRNAME}/../../../_lib/resolve-plugin-pin.sh"
	TEST_TMP=$(mktemp -d -t ship-wrapper.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-wrapper.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_init_git() {
	git -C "$1" init -q
	git -C "$1" config user.email t@x
	git -C "$1" config user.name T
}

_write_stub_driver() {
	# $1 = scripts dir, $2 = marker label echoed by the stub
	mkdir -p "$1"
	cat >"$1/ship-pr-cycle.sh" <<EOF
#!/bin/bash
echo "$2 args=\$*"
EOF
	chmod +x "$1/ship-pr-cycle.sh"
}

_pin_config() {
	# $1 = repo, $2 = rev string
	cat >"$1/.pre-commit-config.yaml" <<EOF
repos:
  - repo: https://github.com/repbyrepdev/claude-workflow-core
    rev: $2
    hooks:
      - id: lint-gate
EOF
}

@test "PLUGIN mode: execs the local scripts/ship-pr-cycle.sh" {
	repo="$TEST_TMP/plugin"
	mkdir -p "$repo/.claude-plugin"
	echo '{"name":"claude-workflow-core","version":"9.9.9"}' >"$repo/.claude-plugin/plugin.json"
	_write_stub_driver "$repo/scripts" "LOCAL-DRIVER"
	_init_git "$repo"
	run bash -c "cd '$repo' && bash '$WRAPPER' status"
	[ "$status" -eq 0 ]
	[[ $output == *"LOCAL-DRIVER args=status"* ]]
}

@test "CONSUMER mode: resolves the pinned-cache driver by pin" {
	repo="$TEST_TMP/consumer"
	mkdir -p "$repo/.claude/_lib"
	cp "$PIN_LIB" "$repo/.claude/_lib/resolve-plugin-pin.sh"
	_pin_config "$repo" "v7.7.7"
	_init_git "$repo"
	cache="$TEST_TMP/cache"
	_write_stub_driver "$cache/somemarket/claude-workflow-core/7.7.7/scripts" "CACHE-DRIVER"
	run bash -c "cd '$repo' && SHIP_CYCLE_CACHE_ROOT='$cache' bash '$WRAPPER' next"
	[ "$status" -eq 0 ]
	[[ $output == *"CACHE-DRIVER args=next"* ]]
}

@test "CONSUMER mode: no claude-workflow-core pin → exit 2 (could not resolve)" {
	repo="$TEST_TMP/consumer2"
	mkdir -p "$repo/.claude/_lib"
	cp "$PIN_LIB" "$repo/.claude/_lib/resolve-plugin-pin.sh"
	echo 'repos: []' >"$repo/.pre-commit-config.yaml"
	_init_git "$repo"
	run bash -c "cd '$repo' && SHIP_CYCLE_CACHE_ROOT='$TEST_TMP/cache' bash '$WRAPPER' status"
	[ "$status" -eq 2 ]
	[[ $output == *"could not resolve"* ]]
}

@test "CONSUMER mode: pin resolves but cache driver missing → exit 2 (no cached)" {
	repo="$TEST_TMP/consumer3"
	mkdir -p "$repo/.claude/_lib"
	cp "$PIN_LIB" "$repo/.claude/_lib/resolve-plugin-pin.sh"
	_pin_config "$repo" "v0.0.1"
	_init_git "$repo"
	run bash -c "cd '$repo' && SHIP_CYCLE_CACHE_ROOT='$TEST_TMP/emptycache' bash '$WRAPPER' status"
	[ "$status" -eq 2 ]
	[[ $output == *"no cached"* ]]
}

@test "CONSUMER mode: missing resolve-plugin-pin lib → exit 2" {
	repo="$TEST_TMP/consumer4"
	mkdir -p "$repo/.claude"
	_pin_config "$repo" "v1.2.3"
	_init_git "$repo"
	run bash -c "cd '$repo' && bash '$WRAPPER' status"
	[ "$status" -eq 2 ]
	[[ $output == *"resolve-plugin-pin.sh missing"* ]]
}

@test "not a git repo → exit 2" {
	mkdir -p "$TEST_TMP/nogit"
	run bash -c "cd '$TEST_TMP/nogit' && bash '$WRAPPER' status"
	[ "$status" -eq 2 ]
	[[ $output == *"must run inside a git repository"* ]]
}

@test "PLUGIN mode: driver present but NON-executable → exit 2 (#2237 r1)" {
	# The final `[ ! -x "$ORCHESTRATOR" ]` guard was uncovered (every other
	# test writes an executable stub or exits earlier). A plugin checkout
	# whose scripts/ship-pr-cycle.sh lost its +x bit must fail loud.
	repo="$TEST_TMP/plugin-nonexec"
	mkdir -p "$repo/.claude-plugin" "$repo/scripts"
	echo '{"name":"claude-workflow-core","version":"9.9.9"}' >"$repo/.claude-plugin/plugin.json"
	printf '#!/bin/bash\necho should-not-run\n' >"$repo/scripts/ship-pr-cycle.sh"
	# Deliberately NOT chmod +x.
	_init_git "$repo"
	run bash -c "cd '$repo' && bash '$WRAPPER' status"
	[ "$status" -eq 2 ]
	[[ $output == *"missing or not executable"* ]]
}
