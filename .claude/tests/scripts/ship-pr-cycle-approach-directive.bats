#!/usr/bin/env bats
# covers: scripts/ship-pr-cycle.sh
#
# (#2651) The one-time APPROACH-REVIEW checkpoint at branch-ready. Two
# contracts: it fires on the FIRST branch-ready pass of a branch, BEFORE
# any review stage; and because per-sha state re-enters branch-ready on
# every commit, the branch-keyed marker must keep it from ever firing —
# or re-blocking — again on that branch.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/ship-pr-cycle.sh"
	[ -f "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t ship-appr.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		git branch -M main
		git checkout -q -b feat-2651-approach
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work1
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp || return 0
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

@test "first branch-ready pass emits the approach directive and writes the branch marker" {
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	[[ $output == *'advanced to phase0.5'* ]] || return 1
	ls .claude/.session-state/ship-cycle/approach-reviewed.* >/dev/null 2>&1
}

@test "a later commit on the SAME branch does not re-emit the directive" {
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	# New commit = new sha = fresh per-sha state that re-enters
	# branch-ready; the branch marker must suppress the re-emit.
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m work2 || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'APPROACH REVIEW'* ]] || return 1
	[[ $output == *'advanced to phase0.5'* ]]
}

@test "a DIFFERENT branch gets its own one-time directive" {
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	git checkout -q -b feat-2651-other main || return 1
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m other1 || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]]
}
