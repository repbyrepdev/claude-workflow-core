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

@test "_orphan_hook_advisory rc=2 (precondition) is NOT framed as drift (#228 r1)" {
	# silent-failure-hunter/pr-test r1: a detector tooling error (rc=2) must read
	# as "could not run", not "drift" with a register-hook hint that wouldn't fix it.
	_stub_detector 2
	run _orphan_hook_advisory "$TMP"
	[ "$status" -eq 0 ] # still never blocks
	[[ $output == *"could not run"* ]]
	[[ $output != *"hook-wiring drift"* ]]
	[[ $output != *"register-hook.sh"* ]]
}

@test "the gate body INVOKES the advisory before the ref loop — call-site guard (#228 r1 integration)" {
	# Guards the wiring (line ~366), not just the function: run the gate
	# NON-sourced with empty stdin (no refs ⇒ no pipeline checks) + a stub
	# detector reporting an orphan. The advisory must fire (proving the call-site
	# is reached) and the gate must still exit 0 (advisory never blocks).
	local repo
	repo=$(mktemp -d -t prepushint.XXXXXX)
	(cd "$repo" && git init -q && git config user.email t@t.t && git config user.name t && git commit -q --allow-empty -m init)
	mkdir -p "$repo/scripts"
	cat >"$repo/scripts/discover-orphan-hooks.sh" <<'STUB'
#!/bin/bash
echo "INTEGRATION STUB ORPHAN"
exit 1
STUB
	chmod +x "$repo/scripts/discover-orphan-hooks.sh"
	run bash -c "cd '$repo' && printf '' | bash '$HOOK' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"hook-wiring drift"* ]]
	[[ $output == *"INTEGRATION STUB ORPHAN"* ]]
	[ -d "$repo" ] && [[ $repo == */prepushint.* ]] && rm -rf "$repo"
}
