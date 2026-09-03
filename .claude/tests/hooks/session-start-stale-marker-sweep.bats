#!/usr/bin/env bats
# covers: hooks/session-start-stale-marker-sweep.sh
#
# v0.30.0 (#180 PR2): regression locks for the v0.28.0 (#174) SessionStart
# stale-marker sweep. The sweep removes phase1-directive markers whose SHA is
# unreachable from any local ref (abandoned branches), while NEVER removing a
# reachable marker and NEVER acting on a non-git dir or a for-each-ref failure.
# Covers gaps T6/T7/T8/T11/T17 + the missing-marker-dir early return + CR-SFH
# fix #1 (hex-validate before for-each-ref) + CR-SFH #2 (for-each-ref FAILURE
# is fail-closed-keep, never mass-rm) + the rm-failure WARN path (T9/T15 family)
# + the filename-not-contents invariant (an unreadable marker file is handled
# identically — the sweep keys on the basename SHA, never the file contents)
# + the positive peer-repo sweep (the peer-loop body, otherwise masked by the
# current-repo call) + the "cleared N stale marker(s)" success summary + the
# SESSION_START_MARKER_SWEEP_SKIP escape hatch + the self-as-peer dedup guard.
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
# Make a fresh git repo at $1 with one commit (a "peer" repo fixture).
_init_repo() {
	(
		set -e
		mkdir -p "$1"
		cd "$1"
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit --allow-empty -q -m init
	)
}
# Run the sweep with cwd = the tmp repo + peer roots pinned to a missing dir.
_run() {
	run bash -c "cd '$TEST_TMP' && MARKER_SWEEP_PEER_ROOTS='$TEST_TMP/nopeer' bash '$HOOK'"
}

@test "reachable-sha marker kept, unreachable-sha marker removed + summary emitted (T6)" {
	local head orphan
	head=$(git -C "$TEST_TMP" rev-parse HEAD)
	orphan=$(_orphan_sha)
	_marker "$head"
	_marker "$orphan"
	_run
	[ "$status" -eq 0 ]
	_has "$head"
	[ ! -f "$MDIR/$orphan.phase1-directive.txt" ]
	# hook line 63: the success path emits a 'cleared N stale marker(s)' summary
	# (the operator's only positive signal). Exactly one orphan was removed.
	[[ $output == *"cleared 1 stale marker"* ]]
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
	[[ $output == *"WARN for-each-ref"* ]] || return 1
	[[ $output == *"keeping marker"* ]] || return 1
	_has "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
}

@test "empty marker dir → no error, nothing removed (T8 nullglob)" {
	# Dir exists but holds no markers — the glob must not expand to a literal
	# and error; the [ -f ] guard skips it.
	_run
	[ "$status" -eq 0 ]
}

@test "non-regular entries matching the glob are skipped by [ -f ] (dir + dangling symlink)" {
	# hook line 34 (`[ -f "$f" ] || continue`) must skip anything that is not a
	# regular file so the glob can't feed a directory / FIFO / dangling symlink
	# into for-each-ref + rm. Drop two non-regular entries whose names look like
	# valid-hex markers; both must survive untouched with no error. (Even if the
	# [ -f ] test were removed, a dir fails `rm -f` and a dangling symlink's hex
	# basename hits the CR-SFH #2 keep — so survival is the right assertion.)
	mkdir -p "$MDIR/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.phase1-directive.txt"
	ln -s /nonexistent-target "$MDIR/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.phase1-directive.txt"
	_run
	[ "$status" -eq 0 ]
	# directory skipped (still present); dangling symlink skipped (still present).
	[ -d "$MDIR/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.phase1-directive.txt" ]
	[ -L "$MDIR/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.phase1-directive.txt" ]
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

@test "positive peer sweep: orphan removed + reachable kept INSIDE a real git peer (peer-loop body)" {
	# The other peer tests hit early-return guards (missing dir / non-git dir),
	# so _sweep_repo's BODY is only ever reached for the CURRENT repo. This
	# drives the peer code path (hook lines 78-82 → _sweep_repo) into a REAL git
	# peer. Without it, a regression in the peer iteration/quoting (e.g. a bad
	# split of $PEER_ROOTS or a quoting bug on $_peer) passes every other test
	# because the current-repo call masks it. The CURRENT repo (cwd) has no
	# markers, so the only sweeping observable here happens inside the peer.
	local peer="$TEST_TMP/peer-git"
	_init_repo "$peer"
	local pmdir="$peer/.claude/.session-state/ship-cycle"
	mkdir -p "$pmdir"
	git -C "$peer" commit --allow-empty -q -m orphan
	local porphan phead
	porphan=$(git -C "$peer" rev-parse HEAD)
	git -C "$peer" reset --hard -q HEAD~1
	phead=$(git -C "$peer" rev-parse HEAD)
	: >"$pmdir/$porphan.phase1-directive.txt"
	: >"$pmdir/$phead.phase1-directive.txt"
	run bash -c "cd '$TEST_TMP' && MARKER_SWEEP_PEER_ROOTS='$peer' bash '$HOOK'"
	[ "$status" -eq 0 ]
	# orphan inside the PEER removed; reachable inside the PEER kept.
	[ ! -f "$pmdir/$porphan.phase1-directive.txt" ]
	[ -f "$pmdir/$phead.phase1-directive.txt" ]
	# the peer removal emits the success summary (cleaned=1 in the peer).
	[[ $output == *"cleared 1 stale marker"* ]]
}

@test "current repo listed as its own peer: swept once, gracefully (dedup guard, hook line 80)" {
	# hook line 80 (`[ "$_peer" = "$CURRENT_REPO" ] && continue`) skips a peer
	# entry that equals the current repo (already swept at lines 69-71). Setting
	# PEER_ROOTS to the current toplevel exercises that continue branch: the
	# orphan is cleared exactly once and the run stays clean (no error, no
	# double-fault). Locks that self-as-peer is handled, not that the redundant
	# pass is impossible — a removed guard re-sweeps idempotently (markers
	# already gone), so the observable contract is "one clear, no error".
	local orphan top
	orphan=$(_orphan_sha)
	_marker "$orphan"
	top=$(git -C "$TEST_TMP" rev-parse --show-toplevel)
	run bash -c "cd '$TEST_TMP' && MARKER_SWEEP_PEER_ROOTS='$top' bash '$HOOK'"
	[ "$status" -eq 0 ]
	[ ! -f "$MDIR/$orphan.phase1-directive.txt" ]
	# exactly one 'cleared' summary — the current repo is not processed twice.
	[ "$(printf '%s\n' "$output" | grep -c 'cleared 1 stale marker')" -eq 1 ]
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

@test "SESSION_START_MARKER_SWEEP_SKIP=1 disables the sweep — orphan marker kept (escape hatch)" {
	# hook lines 21-23: the documented bypass (header line 19) is the operator's
	# only way to disable a misbehaving sweep. With it set, an otherwise-stale
	# orphan marker must be left untouched (and the run exits 0 immediately).
	local orphan
	orphan=$(_orphan_sha)
	_marker "$orphan"
	run bash -c "cd '$TEST_TMP' && SESSION_START_MARKER_SWEEP_SKIP=1 MARKER_SWEEP_PEER_ROOTS='$TEST_TMP/nopeer' bash '$HOOK'"
	[ "$status" -eq 0 ]
	# sweep disabled → the stale orphan is STILL present.
	_has "$orphan"
}

@test "rm failure on a stale marker is surfaced + marker kept, not silently dropped (T9/T15)" {
	# This test forces rm to fail via DAC perms (chmod 555 on the marker dir).
	# UID 0 bypasses DAC, so under root rm would succeed and the assertions
	# below would break — skip rather than false-fail in a root CI container.
	if [ "$(id -u)" -eq 0 ]; then
		skip "#180 rm-failure path relies on DAC perms, which root (uid 0) bypasses"
	fi
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
	[[ $output == *"failed to rm"* ]] || return 1
	_has "$orphan"
}

@test "unreadable marker file: removed-if-orphan, kept-if-reachable (keys on filename, not contents)" {
	# The sweep derives the SHA from the marker FILENAME (basename) and never
	# reads the file contents, so a marker whose file is unreadable (chmod 000)
	# must behave identically to a readable one. This locks that invariant: a
	# future refactor that began reading contents would break on unreadable
	# markers. (rm needs dir-write perm, not file-read perm, so the orphan is
	# still removed; the reachable one is still kept.)
	local head orphan
	head=$(git -C "$TEST_TMP" rev-parse HEAD)
	orphan=$(_orphan_sha)
	_marker "$head"
	_marker "$orphan"
	chmod 000 "$MDIR/$head.phase1-directive.txt" "$MDIR/$orphan.phase1-directive.txt"
	_run
	[ "$status" -eq 0 ]
	_has "$head"
	[ ! -f "$MDIR/$orphan.phase1-directive.txt" ]
}

# ---- (#2651) approach-directive-emitted branch markers --------------------

@test "approach marker for a LIVE branch is kept; deleted-branch marker is removed" {
	cd "$TEST_TMP" || return 1
	git checkout -q -b appr-live || return 1
	git checkout -q -b appr-dead || return 1
	git checkout -q appr-live || return 1
	git branch -q -D appr-dead || return 1
	mkdir -p "$MDIR/branch" || return 1
	: >"$MDIR/branch/appr-live.approach-directive-emitted" || return 1
	: >"$MDIR/branch/appr-dead.approach-directive-emitted" || return 1
	_run
	[ "$status" -eq 0 ] || return 1
	[ -f "$MDIR/branch/appr-live.approach-directive-emitted" ] || return 1
	[ ! -f "$MDIR/branch/appr-dead.approach-directive-emitted" ] || return 1
	# The removal is reported, not silent (phase2 CR).
	[[ $output == *'cleared 1 stale marker(s)'* ]]
}

@test "approach marker for a slash-bearing live branch survives the sweep" {
	cd "$TEST_TMP" || return 1
	git checkout -q -b appr/nested/live || return 1
	mkdir -p "$MDIR/branch/appr/nested" || return 1
	: >"$MDIR/branch/appr/nested/live.approach-directive-emitted" || return 1
	_run
	[ "$status" -eq 0 ] || return 1
	[ -f "$MDIR/branch/appr/nested/live.approach-directive-emitted" ] || return 1
	# Nothing was stale, so nothing may be reported cleared (phase2 CR).
	[[ $output != *'cleared'* ]]
}
