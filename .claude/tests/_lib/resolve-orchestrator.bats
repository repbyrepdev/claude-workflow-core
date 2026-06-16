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
	# the SPECIFIC error fired (not just any rc 2): missing pin lib. `run` merges
	# stderr into $output, so the diagnostic is assertable.
	[[ $output == *"resolve-plugin-pin.sh"* ]]
	[[ $output == *"missing"* ]]
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
	# the SPECIFIC error fired: pin resolved but no cached driver.
	[[ $output == *"no cached"* ]]
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
	# the SPECIFIC error fired: present-but-not-executable driver.
	[[ $output == *"not executable"* ]]
}

@test "resolve_ship_orchestrator: CONSUMER cache under a NON-default marketplace segment still resolves (glob, #2427)" {
	# The resolver GLOBs the marketplace path segment ($cache_root/*/claude-...),
	# so a non-default marketplace dir name still resolves. The happy-path test
	# uses a literal 'marketplace' segment, which would pass even against a
	# hardcoded path — this proves the glob's PURPOSE and guards against a future
	# refactor back to a frozen literal (the #2427 deadlock bug class).
	REPO="$TEST_TMP/consumer-altmp"
	mkdir -p "$REPO/.claude/_lib"
	printf '#!/bin/bash\nresolve_plugin_pin() { echo "0.34.81"; }\n' >"$REPO/.claude/_lib/resolve-plugin-pin.sh"
	: >"$REPO/.pre-commit-config.yaml"
	CACHE="$TEST_TMP/cache-altmp"
	DRIVER="$CACHE/some-other-marketplace/claude-workflow-core/0.34.81/scripts/ship-pr-cycle.sh"
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

@test "resolve_ship_orchestrator: no repo_root arg in a non-git dir → rc 2 (git rev-parse default)" {
	# With no arg the resolver defaults repo_root via `git rev-parse
	# --show-toplevel`; outside a git work-tree that fails and the resolver must
	# rc 2 (never silently resolve the wrong tree). Locks the zero-arg contract
	# even though both production callers pass repo_root explicitly. The call runs
	# in a subshell cd'd into a non-git tmp dir (mktemp dirs have no .git ancestor).
	NONGIT="$TEST_TMP/nongit"
	mkdir -p "$NONGIT"
	run bash -c "cd '$NONGIT' && . '$LIB' && resolve_ship_orchestrator"
	[ "$status" -eq 2 ]
	# the SPECIFIC error fired: not inside a git repository.
	[[ $output == *"git repository"* ]]
}

@test "resolve_ship_orchestrator: CONSUMER pinned driver under MULTIPLE marketplaces → rc 2 (ambiguous, deterministic-fail)" {
	# A corrupted/duplicated cache where two marketplace dirs BOTH carry the
	# pinned driver must fail loudly (rc 2 + list both) rather than silently
	# first-match by filesystem order — the resolver is the SSOT, so ambiguity is
	# an error, not a coin-flip.
	REPO="$TEST_TMP/consumer-dup"
	mkdir -p "$REPO/.claude/_lib"
	printf '#!/bin/bash\nresolve_plugin_pin() { echo "0.34.82"; }\n' >"$REPO/.claude/_lib/resolve-plugin-pin.sh"
	: >"$REPO/.pre-commit-config.yaml"
	CACHE="$TEST_TMP/cache-dup"
	local mp d
	for mp in marketplace-a marketplace-b; do
		d="$CACHE/$mp/claude-workflow-core/0.34.82/scripts/ship-pr-cycle.sh"
		mkdir -p "$(dirname "$d")"
		printf '#!/bin/bash\n' >"$d"
		chmod +x "$d"
	done
	export SHIP_CYCLE_CACHE_ROOT="$CACHE"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 2 ]
	[[ $output == *"multiple cached"* ]]
}

@test "resolve_ship_orchestrator: CONSUMER pin resolver returns EMPTY at rc 0 → rc 2 (defensive, no double-slash glob)" {
	# resolve_plugin_pin regex-validates so a rc-0 empty pin is impossible today,
	# but the resolver must fail closed rather than build a malformed
	# .../claude-workflow-core//scripts/... glob if that contract is ever violated.
	REPO="$TEST_TMP/consumer-emptypin"
	mkdir -p "$REPO/.claude/_lib"
	# Stub returns empty stdout + rc 0 (echo succeeds) — the contract violation.
	printf '#!/bin/bash\nresolve_plugin_pin() { echo ""; }\n' >"$REPO/.claude/_lib/resolve-plugin-pin.sh"
	: >"$REPO/.pre-commit-config.yaml"
	# shellcheck source=/dev/null
	. "$LIB"
	run resolve_ship_orchestrator "$REPO"
	[ "$status" -eq 2 ]
	[[ $output == *"empty pin"* ]]
}
