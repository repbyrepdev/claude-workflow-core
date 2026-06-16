#!/usr/bin/env bats
# covers: hooks/post-commit-ship-cycle.sh
#
# v0.30.0 (#180 PR3): regression locks for the v4.28-W4 (#728) post-commit
# helper that fires `ship-pr-cycle.sh resume` after a commit AND proactively
# sweeps stale phase1-directive markers (v0.28.0 #174 Axis 2 — markers for
# non-HEAD unreachable shas accumulate and lock out tool calls). Covers gap
# T10 (post-commit + session-start race on the same marker_dir — here the
# post-commit sweep half) + the CR-SFH #5 fixes (hex-validate before
# for-each-ref, and for-each-ref FAILURE = fail-closed keep, never mass-rm).
#
# The hook EXITS via the resolver's `[ -x ]` check (#2427) BEFORE the sweep
# when scripts/ship-pr-cycle.sh is absent, so the fixture ships a no-op stub.
# The stub also makes the detached `resume` spawn (setsid/nohup) a harmless
# exit-0.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/post-commit-ship-cycle.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t post-commit-ship.XXXXXX) || {
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
		# ship-pr-cycle.sh stub: the hook resolves the orchestrator (#2427, via
		# _lib/resolve-orchestrator.sh) and refuses to proceed past its `[ -x ]`
		# check without it; the detached resume call must be a harmless no-op.
		mkdir -p scripts
		printf '#!/bin/bash\nexit 0\n' >scripts/ship-pr-cycle.sh
		chmod +x scripts/ship-pr-cycle.sh
		# #2427: a .claude-plugin/plugin.json makes this a PLUGIN repo, so
		# resolve_ship_orchestrator returns the LOCAL scripts/ship-pr-cycle.sh stub
		# above. (A bare synth repo with no plugin.json would be treated as a
		# consumer with no pin lib → rc 2 → exit 0 before the sweep.)
		mkdir -p .claude-plugin
		printf '{}\n' >.claude-plugin/plugin.json
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
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */post-commit-ship.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_marker() { : >"$MDIR/$1.phase1-directive.txt"; }
_has() { [ -f "$MDIR/$1.phase1-directive.txt" ]; }
# Valid-but-unreachable sha: commit then reset away (real object, no ref).
_orphan_sha() {
	git -C "$TEST_TMP" commit --allow-empty -q -m orphan
	local s
	s=$(git -C "$TEST_TMP" rev-parse HEAD)
	git -C "$TEST_TMP" reset --hard -q HEAD~1
	printf '%s' "$s"
}
_run() {
	run bash -c "cd '$TEST_TMP' && bash '$HOOK'"
}

@test "current-HEAD marker is kept (active phase1 round, hook line 66)" {
	local head
	head=$(git -C "$TEST_TMP" rev-parse HEAD)
	_marker "$head"
	_run
	[ "$status" -eq 0 ]
	# The current HEAD's marker is the active round — never swept.
	_has "$head"
}

@test "stale unreachable-sha marker is removed (hook line 84)" {
	local orphan
	orphan=$(_orphan_sha)
	_marker "$orphan"
	_run
	[ "$status" -eq 0 ]
	[ ! -f "$MDIR/$orphan.phase1-directive.txt" ]
}

@test "reachable non-HEAD marker is kept (for-each-ref returns a ref)" {
	# A sha reachable from a branch ref but != HEAD: for-each-ref --contains
	# returns the refname (non-empty) → not stale → kept. Distinguishes the
	# 'unreachable → rm' path from 'reachable → keep'.
	local first
	first=$(git -C "$TEST_TMP" rev-parse HEAD)
	git -C "$TEST_TMP" commit --allow-empty -q -m second
	# first is now reachable from the branch tip but is not HEAD.
	_marker "$first"
	_run
	[ "$status" -eq 0 ]
	_has "$first"
}

@test "marker sha reachable from MULTIPLE refs is kept (for-each-ref returns >1 ref)" {
	# A sha contained by several refs → for-each-ref --contains emits multiple
	# refnames (non-empty); the hook's `[ -z "$_ref_out" ]` emptiness check is
	# ref-count-agnostic → kept. Confirms multi-ref reachability isn't mistaken
	# for stale.
	local c1
	c1=$(git -C "$TEST_TMP" rev-parse HEAD)
	git -C "$TEST_TMP" branch b2                     # b2 also contains c1
	git -C "$TEST_TMP" commit --allow-empty -q -m c2 # advance HEAD past c1
	_marker "$c1"
	_run
	[ "$status" -eq 0 ]
	_has "$c1"
}

@test "valid-hex but nonexistent sha: for-each-ref errors → marker KEPT (CR-SFH #5)" {
	# A valid-hex basename that is not a real object errors for-each-ref
	# (rc!=0); the hook must WARN + KEEP (fail-closed), never mass-rm.
	_marker "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
	_run
	[ "$status" -eq 0 ]
	[[ $output == *"WARN for-each-ref"* ]]
	[[ $output == *"keeping marker"* ]]
	_has "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
}

@test "real object that is not a commit (blob sha): for-each-ref errors → marker KEPT (CR-SFH #5)" {
	# A blob sha is a REAL 40-hex object (passes the hex guard + exists in the
	# object db) but `for-each-ref --contains` rejects it ("is a blob, not a
	# commit", rc!=0). Distinct from the deadbeef invalid-object case: proves
	# the fail-closed keep also covers a real-but-non-commit object (corrupt /
	# perms / non-commit causes all funnel through the same rc!=0 branch).
	local blob
	echo "i am a blob, not a commit" >"$TEST_TMP/blob-src.txt"
	blob=$(git -C "$TEST_TMP" hash-object -w "$TEST_TMP/blob-src.txt")
	_marker "$blob"
	_run
	[ "$status" -eq 0 ]
	[[ $output == *"WARN for-each-ref"* ]]
	[[ $output == *"keeping marker"* ]]
	_has "$blob"
}

@test "non-hex marker basename is skipped before for-each-ref (CR-SFH #5)" {
	_marker "notahexsha-editor-swap"
	_run
	[ "$status" -eq 0 ]
	_has "notahexsha-editor-swap"
}

@test "SHIP_CYCLE_POST_COMMIT_SKIP=1 disables the helper — stale marker kept" {
	# hook lines 27-29: the operator bypass exits 0 before the sweep, so even a
	# stale orphan marker is left untouched.
	local orphan
	orphan=$(_orphan_sha)
	_marker "$orphan"
	run bash -c "cd '$TEST_TMP' && SHIP_CYCLE_POST_COMMIT_SKIP=1 bash '$HOOK'"
	[ "$status" -eq 0 ]
	_has "$orphan"
}

@test "non-executable scripts/ship-pr-cycle.sh → exit 0 before sweep (resolver -x check, #2427)" {
	# `[ -x "$SCRIPT" ]` is false for a present-but-non-executable file just as
	# for a missing one (chmod -x clears all x bits, so even root's test -x is
	# false) → exit 0 before the sweep, stale marker untouched.
	chmod -x "$TEST_TMP/scripts/ship-pr-cycle.sh"
	local orphan
	orphan=$(_orphan_sha)
	_marker "$orphan"
	_run
	[ "$status" -eq 0 ]
	_has "$orphan"
}

@test "missing scripts/ship-pr-cycle.sh → exit 0 before sweep, marker untouched (resolver -x check, #2427)" {
	# Without the orchestrator present the helper has nothing to resume; it
	# exits 0 at the `[ -x "$SCRIPT" ]` guard BEFORE the sweep, so a stale
	# marker is left in place (the sweep is coupled to a real resume).
	rm -f "$TEST_TMP/scripts/ship-pr-cycle.sh"
	local orphan
	orphan=$(_orphan_sha)
	_marker "$orphan"
	_run
	[ "$status" -eq 0 ]
	_has "$orphan"
}

@test "the fire-resume record is appended to ship-cycle-resume.jsonl with sha + branch" {
	# hook lines 50-51 — the documented core behavior (#3): append a
	# {action:"fire-resume"} record carrying the HEAD sha + branch (jq-escaped,
	# not interpolated). Every other test checks only the sweep; this locks the
	# forensic log itself so a broken/removed append can't pass silently.
	local sha branch
	sha=$(git -C "$TEST_TMP" rev-parse HEAD)
	branch=$(git -C "$TEST_TMP" rev-parse --abbrev-ref HEAD)
	_run
	[ "$status" -eq 0 ]
	local logf="$TEST_TMP/.claude/logs/ship-cycle-resume.jsonl"
	[ -f "$logf" ]
	run jq -e --arg s "$sha" --arg b "$branch" \
		'select(.action=="fire-resume" and .sha==$s and .branch==$b)' "$logf"
	[ "$status" -eq 0 ]
}
