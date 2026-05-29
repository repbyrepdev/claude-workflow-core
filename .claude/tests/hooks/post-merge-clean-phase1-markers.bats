#!/usr/bin/env bats
# covers: hooks/post-merge-clean-phase1-markers.sh
#
# Tests for v0.27.0 #173 Layer 3: post-merge hook scans the
# phase1-directive marker dir and drops markers whose sha is reachable
# from origin/main.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/post-merge-clean-phase1-markers.sh"
	[ -f "$HOOK" ]
	TEST_TMP=$(mktemp -d -t post-merge-marker.XXXXXX) || return 1
	mkdir -p "$TEST_TMP/.claude/.session-state/ship-cycle" "$TEST_TMP/.claude/logs"
	(cd "$TEST_TMP" && git init -q && git config user.email t@x && git config user.name t)
	(cd "$TEST_TMP" && git commit --allow-empty -q -m base)
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */post-merge-marker.* ]] && rm -rf "$TEST_TMP"
}

@test "no-op when marker dir absent" {
	rm -rf "$TEST_TMP/.claude/.session-state/ship-cycle"
	cd "$TEST_TMP" || return 1
	run "$HOOK"
	[ "$status" -eq 0 ]
}

@test "no-op when no markers" {
	cd "$TEST_TMP" || return 1
	run "$HOOK"
	[ "$status" -eq 0 ]
}

@test "log-dir creation failure no longer aborts cleanup (v0.27.1 CR fix)" {
	# v0.27.1 CR-in-CI #179 r1 finding: mkdir -p LOG_DIR was || exit 0
	# which aborted cleanup when log dir couldn't be created. Now || true.
	# Verify the script contains the fix (regression guard).
	grep -q 'mkdir -p "\$LOG_DIR" 2>/dev/null || true' "$HOOK"
}

@test "marker for unreachable sha preserved" {
	echo "directive" >"$TEST_TMP/.claude/.session-state/ship-cycle/deadbeef.phase1-directive.txt"
	cd "$TEST_TMP" || return 1
	"$HOOK" || true
	# Marker should still exist (sha not reachable from origin/main)
	[ -f "$TEST_TMP/.claude/.session-state/ship-cycle/deadbeef.phase1-directive.txt" ]
}
