#!/usr/bin/env bats
# covers: _lib/resolve-orchestrator.sh
# shellcheck disable=SC2030,SC2031  # bats @test bodies run in subshells; per-test env exports are intentional + isolated
#
# #2427: resolve-orchestrator.sh is the SSOT both the skill wrapper
# (skills/ship-pr-cycle/run.sh) and the post-commit auto-fire
# (hooks/post-commit-ship-cycle.sh) source to resolve the ship-pr-cycle driver
# layout-agnostically — so neither hardcodes the repo-root path (the frozen
# consumer copy that caused the 2026-06-16 deadlock). These tests lock:
#   - PLUGIN repo (plugin.json present) → the LOCAL scripts/ship-pr-cycle.sh;
#   - CONSUMER repo (no plugin.json) → the PINNED-CACHE driver (pin stubbed);
#   - missing pin lib → rc 2; pin resolves but no cached driver → rc 2.
# The pin resolution is STUBBED (a fake .claude/_lib/resolve-plugin-pin.sh) so
# this unit is isolated from resolve-plugin-pin's internals. repo_root is passed
# as the arg, so no git fixture is needed.

setup() {
	LIB_SRC="${BATS_TEST_DIRNAME}/../../../_lib/resolve-orchestrator.sh"
	[ -f "$LIB_SRC" ]
	TEST_TMP=$(mktemp -d -t rso.XXXXXX) || return 1
	LIB="$TEST_TMP/resolve-orchestrator.sh"
	cp "$LIB_SRC" "$LIB"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rso.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "resolve_ship_orchestrator: PLUGIN repo (plugin.json present) → local scripts/ship-pr-cycle.sh" {
	REPO="$TEST_TMP/plugin"
	mkdir -p "$REPO/.claude-plugin" "$REPO/scripts"
	echo '{}' >"$REPO/.claude-plugin/plugin.json"
	printf '#!/bin/bash\n' >"$REPO/scripts/ship-pr-cycle.sh"
	chmod +x "$REPO/scripts/ship-pr-cycle.sh"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 0 ]
	[ "$output" = "$REPO/scripts/ship-pr-cycle.sh" ]
}

@test "resolve_ship_orchestrator: CONSUMER repo (no plugin.json) → pinned-cache driver" {
	REPO="$TEST_TMP/consumer"
	mkdir -p "$REPO/.claude/_lib"
	# Stub the pin resolver so this unit is isolated from resolve-plugin-pin.
	printf '#!/bin/bash\nresolve_plugin_pin() { echo "0.34.81"; }\n' >"$REPO/.claude/_lib/resolve-plugin-pin.sh"
	: >"$REPO/.pre-commit-config.yaml"
	CACHE="$TEST_TMP/cache"
	DRIVER="$CACHE/marketplace/claude-workflow-core/0.34.81/scripts/ship-pr-cycle.sh"
	mkdir -p "$(dirname "$DRIVER")"
	printf '#!/bin/bash\n' >"$DRIVER"
	chmod +x "$DRIVER"
	export SHIP_CYCLE_CACHE_ROOT="$CACHE"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 0 ]
	[ "$output" = "$DRIVER" ]
}

@test "resolve_ship_orchestrator: CONSUMER with missing pin lib → rc 2" {
	REPO="$TEST_TMP/consumer-nopin"
	mkdir -p "$REPO/.claude/_lib" # dir exists but no resolve-plugin-pin.sh
	: >"$REPO/.pre-commit-config.yaml"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 2 ]
}

@test "resolve_ship_orchestrator: CONSUMER pin resolves but no cached driver → rc 2" {
	REPO="$TEST_TMP/consumer-nocache"
	mkdir -p "$REPO/.claude/_lib"
	printf '#!/bin/bash\nresolve_plugin_pin() { echo "9.9.9"; }\n' >"$REPO/.claude/_lib/resolve-plugin-pin.sh"
	: >"$REPO/.pre-commit-config.yaml"
	mkdir -p "$TEST_TMP/empty-cache"
	export SHIP_CYCLE_CACHE_ROOT="$TEST_TMP/empty-cache"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 2 ]
}

@test "resolve_ship_orchestrator: PLUGIN repo but driver not executable → rc 2" {
	REPO="$TEST_TMP/plugin-noexec"
	mkdir -p "$REPO/.claude-plugin" "$REPO/scripts"
	echo '{}' >"$REPO/.claude-plugin/plugin.json"
	printf '#!/bin/bash\n' >"$REPO/scripts/ship-pr-cycle.sh" # NOT chmod +x
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 2 ]
}
