#!/usr/bin/env bats
# covers: hooks/session-start-stale-marker-sweep.sh
#
# v0.30.0 (#180 PR2): regression locks for the v0.28.0 (#174) SessionStart
# stale-marker sweep. The sweep removes phase1-directive markers whose SHA is
# unreachable from any local ref (abandoned branches), while NEVER removing a
# reachable marker and NEVER acting on a non-git dir or a for-each-ref failure.
# Covers gaps T6/T7/T8/T11/T17 + the missing-marker-dir early return + CR-SFH
# fix #1 (hex-validate before for-each-ref) + CR-SFH #2 (for-each-ref FAILURE
# is fail-closed-keep, never mass-rm) + the rm-failure WARN path (T9/T15 family).
#
# MARKER_SWEEP_PEER_ROOTS is pinned to a non-existent dir per test so the real
# peer-repo defaults ($HOME/media-server:...) are never swept.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/session-start-stale-marker-sweep.sh"
	[ -f "$HOOK" ]
	TEST_TMP=$(mktemp -d -t marker-sweep.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit --allow-empty -q -m init
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
	MDIR="$TEST_TMP/.claude/.session-state/ship-cycle"
	mkdir -p "$MDIR"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	# Restore write perms first (a test may chmod the marker dir read-only).
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ]; then
		chmod -R u+w "$TEST_TMP" 2>/dev/null || true
	fi
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */marker-sweep.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_marker() { : >"$MDIR/$1.phase1-directive.txt"; }
_has() { [ -f "$MDIR/$1.phase1-directive.txt" ]; }
# Make a VALID-but-unreachable commit object: commit then reset it away. Its
# sha is a real object (so for-each-ref --contains succeeds, returning empty)
# but no ref contains it → the sweep treats it as stale. (A bogus hex sha like
# deadbeef is an INVALID object → for-each-ref ERRORS → fail-closed keep, which
# is the CR-SFH #2 path, not the stale-removal path.)
_orphan_sha() {
	git -C "$TEST_TMP" commit --allow-empty -q -m orphan
	local s
	s=$(git -C "$TEST_TMP" rev-parse HEAD)
	git -C "$TEST_TMP" reset --hard -q HEAD~1
	printf '%s' "$s"
}
# Run the sweep with cwd = the tmp repo + peer roots pinned to a missing dir.
_run() {
	run bash -c "cd '$TEST_TMP' && MARKER_SWEEP_PEER_ROOTS='$TEST_TMP/nopeer' bash '$HOOK'"
}

@test "reachable-sha marker kept, unreachable-sha marker removed (T6)" {
	local head orphan
	head=$(git -C "$TEST_TMP" rev-parse HEAD)
	orphan=$(_orphan_sha)
	_marker "$head"
	_marker "$orphan"
	_run
	[ "$status" -eq 0 ]
	_has "$head"
	[ ! -f "$MDIR/$orphan.phase1-directive.txt" ]
}

@test "valid-hex but nonexistent SHA: for-each-ref errors → marker KEPT, never mass-rm'd (CR-SFH #2)" {
	# CR-SFH #2: when for-each-ref FAILS (corrupt repo, perm denied, or — as
	# here — a valid-hex basename that is not a real object) the hook must WARN
	# + KEEP the marker (fail-closed), NEVER treat rc!=0 as "unreachable → rm".
	# deadbeef… passes the hex-validate guard (CR-SFH #1) so it reaches
	# for-each-ref, which errors rc=129 (no such commit). This locks the single
	# most safety-critical property: an unreadable ref-db must not mass-delete.
	# Complements T6 (orphan → for-each-ref SUCCEEDS empty → removed): together
	# they pin the reachable / unreachable-success / error trichotomy.
	_marker "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	_run
	[ "$status" -eq 0 ]
	[[ $output == *"WARN for-each-ref"* ]]
	[[ $output == *"keeping marker"* ]]
	_has "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
}

@test "empty marker dir → no error, nothing removed (T8 nullglob)" {
	# Dir exists but holds no markers — the glob must not expand to a literal
	# and error; the [ -f ] guard skips it.
	_run
	[ "$status" -eq 0 ]
}

@test "missing marker dir → early return, no error (hooks line 28 guard)" {
	# A repo that never ran a ship-cycle has no marker dir at all. hooks line 28
	# (`[ -d "$marker_dir" ] || return 0`) must short-circuit so the sweep
	# no-ops instead of erroring on the missing dir under set -euo pipefail.
	rm -rf "$MDIR"
	_run
	[ "$status" -eq 0 ]
}

@test "non-hex marker basename is skipped, never removed (CR-SFH #1)" {
	# A stray non-sha file (.DS_Store-style) must be skipped BEFORE for-each-ref,
	# else for-each-ref errors and the `!` could flip to mass-rm.
	_marker "notahexsha-backup"
	_run
	[ "$status" -eq 0 ]
	_has "notahexsha-backup"
}

@test "detached HEAD: marker for a branch-reachable sha is kept (T11)" {
	git -C "$TEST_TMP" commit --allow-empty -q -m c2
	local sha
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	git -C "$TEST_TMP" checkout -q --detach "$sha"
	_marker "$sha"
	_run
	[ "$status" -eq 0 ]
	# sha is still reachable from the branch ref (for-each-ref --contains),
	# regardless of HEAD being detached → marker kept.
	_has "$sha"
}

@test "non-git peer dir is not swept (T17 missing-git fallback)" {
	local peer="$TEST_TMP/peer-nongit"
	mkdir -p "$peer/.claude/.session-state/ship-cycle"
	: >"$peer/.claude/.session-state/ship-cycle/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef.phase1-directive.txt"
	run bash -c "cd '$TEST_TMP' && MARKER_SWEEP_PEER_ROOTS='$peer' bash '$HOOK'"
	[ "$status" -eq 0 ]
	# peer is not a git repo → _sweep_repo returns early → marker untouched.
	[ -f "$peer/.claude/.session-state/ship-cycle/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef.phase1-directive.txt" ]
}

@test "empty PEER_ROOTS entries are skipped without error (T7)" {
	local head
	head=$(git -C "$TEST_TMP" rev-parse HEAD)
	_marker "$head"
	# Leading/trailing/double colon → empty entries; the [ -n ] guard skips them.
	run bash -c "cd '$TEST_TMP' && MARKER_SWEEP_PEER_ROOTS=':$TEST_TMP/nopeer::' bash '$HOOK'"
	[ "$status" -eq 0 ]
	_has "$head"
}

@test "rm failure on a stale marker is surfaced + marker kept, not silently dropped (T9/T15)" {
	# An unreachable marker in a non-writable dir can't be rm'd; the hook must
	# WARN (not silently succeed) and leave the marker in place (cleaned counter
	# only increments on a successful rm).
	local orphan
	orphan=$(_orphan_sha)
	_marker "$orphan"
	chmod 555 "$MDIR"
	_run
	chmod u+w "$MDIR"
	[ "$status" -eq 0 ]
	[[ $output == *"failed to rm"* ]]
	_has "$orphan"
}
