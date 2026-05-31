#!/usr/bin/env bats
# covers: hooks/pre-push-pipeline-gate.sh
#
# v0.31 #228: the fail-soft hook-wiring drift advisory. Sourced via
# SOURCED_FOR_TEST so the function is exercised in isolation. Contract: WARN on
# orphans, NEVER block (always rc 0), respect the skip env + an absent detector.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/pre-push-pipeline-gate.sh"
	[ -f "$HOOK" ]
	# Source for its helpers — the gate returns early (before the main body)
	# under SOURCED_FOR_TEST, after defining the _ functions.
	# shellcheck disable=SC1090  # dynamic source path (the hook under test)
	SOURCED_FOR_TEST=1 source "$HOOK"
	TMP=$(mktemp -d -t prepush.XXXXXX) || return 1
	mkdir -p "$TMP/scripts"
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */prepush.* ]] && rm -rf "$TMP"
	return 0
}

_stub_detector() {
	# $1 = exit code (1 = orphans found, 0 = clean)
	cat >"$TMP/scripts/discover-orphan-hooks.sh" <<EOF
#!/bin/bash
echo "STUB ORPHAN OUTPUT"
exit $1
EOF
	chmod +x "$TMP/scripts/discover-orphan-hooks.sh"
}

@test "_orphan_hook_advisory WARNS on orphans but returns 0 — fail-soft (#228)" {
	_stub_detector 1
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ] # never blocks the push
	[[ $output == *"hook-wiring drift"* ]]
	[[ $output == *"STUB ORPHAN OUTPUT"* ]]
	[[ $output == *"register-hook.sh --all-auto-register"* ]]
}

@test "_orphan_hook_advisory is silent + rc 0 when no orphans (#228)" {
	_stub_detector 0
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ]
	[[ $output != *"hook-wiring drift"* ]]
}

@test "_orphan_hook_advisory respects ORPHAN_HOOK_CHECK_SKIP=1 (#228)" {
	_stub_detector 1
	ORPHAN_HOOK_CHECK_SKIP=1 run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ]
	[[ $output != *"hook-wiring drift"* ]]
}

@test "_orphan_hook_advisory no-ops + rc 0 when the detector is absent (#228)" {
	# no _stub_detector → $TMP/scripts/discover-orphan-hooks.sh missing
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ]
	[[ $output != *"hook-wiring drift"* ]]
}
