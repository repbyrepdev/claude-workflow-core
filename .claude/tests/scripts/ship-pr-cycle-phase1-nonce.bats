#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# Tests for _write_phase1_directive_marker nonce emission (#92).
# Full orchestrator tests are in other suites; this file targets the
# specific nonce contract added in v0.10.0.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/ship-pr-cycle.sh"
	TEST_TMP=$(mktemp -d -t ship-cycle-nonce.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	export STATE_DIR="$TEST_TMP/.claude/.session-state/ship-pr-cycle"
	mkdir -p "$STATE_DIR"
	SHA="aaaa0000bbbb1111cccc2222dddd3333eeee4444"
	# Pre-create state JSON like the orchestrator would.
	printf '{"stage":"phase1","branch":"feat/v0.10.0/test"}\n' \
		>"$STATE_DIR/$SHA.json"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ship-cycle-nonce.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Source the orchestrator to make _write_phase1_directive_marker callable.
# Define stubs for the helpers we don't need.
_source_orchestrator() {
	# Define stubs BEFORE sourcing so the orchestrator picks them up.
	scm_warn() { echo "WARN: $*" >&2; }
	export -f scm_warn
	# Source only the function definitions we need by extracting them.
	# Sourcing the whole script would execute top-level code.
	sed -n '/^_phase1_directive_marker_file()/,/^}$/p; /^_write_phase1_directive_marker()/,/^}$/p' \
		"$SCRIPT" >"$TEST_TMP/funcs.sh"
	# shellcheck disable=SC1091
	. "$TEST_TMP/funcs.sh"
}

@test "_write_phase1_directive_marker writes nonce on line 1 + directive on line 2 (#92)" {
	_source_orchestrator
	_write_phase1_directive_marker "$SHA" "fire phase 1 directive"
	[ -f "$STATE_DIR/$SHA.phase1-directive.txt" ]
	# Line 1 must be a UUID-shaped string (8-4-4-4-12 hex).
	line1=$(head -1 "$STATE_DIR/$SHA.phase1-directive.txt")
	[[ $line1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
	# Line 2 must be the directive text.
	line2=$(sed -n '2p' "$STATE_DIR/$SHA.phase1-directive.txt")
	[ "$line2" = "fire phase 1 directive" ]
}

@test "_write_phase1_directive_marker writes nonce to state JSON (#92)" {
	_source_orchestrator
	_write_phase1_directive_marker "$SHA" "directive"
	state_nonce=$(jq -r '.phase1_directive_nonce // ""' "$STATE_DIR/$SHA.json")
	[ -n "$state_nonce" ]
	[[ $state_nonce =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
	# Same nonce as sentinel line 1.
	sentinel_nonce=$(head -1 "$STATE_DIR/$SHA.phase1-directive.txt")
	[ "$state_nonce" = "$sentinel_nonce" ]
}

@test "_write_phase1_directive_marker is idempotent — re-emit replaces nonce (#92)" {
	_source_orchestrator
	_write_phase1_directive_marker "$SHA" "round 1"
	nonce_r1=$(head -1 "$STATE_DIR/$SHA.phase1-directive.txt")
	_write_phase1_directive_marker "$SHA" "round 2"
	nonce_r2=$(head -1 "$STATE_DIR/$SHA.phase1-directive.txt")
	# Each emit generates a fresh nonce — round 2 nonce != round 1.
	[ "$nonce_r1" != "$nonce_r2" ]
	# State JSON has the latest nonce, not the stale one.
	state_nonce=$(jq -r '.phase1_directive_nonce' "$STATE_DIR/$SHA.json")
	[ "$state_nonce" = "$nonce_r2" ]
}
