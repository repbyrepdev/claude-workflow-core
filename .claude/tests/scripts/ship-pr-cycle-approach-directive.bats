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
	[ -f .claude/.session-state/ship-cycle/branch/feat-2651-approach.approach-directive-emitted ]
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

@test "a DIFFERENT branch gets its own one-time directive and its own marker" {
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
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	# Marker isolation: one file per branch, both present.
	[ -f .claude/.session-state/ship-cycle/branch/feat-2651-approach.approach-directive-emitted ] || return 1
	[ -f .claude/.session-state/ship-cycle/branch/feat-2651-other.approach-directive-emitted ]
}

@test "a slash-bearing branch name nests its marker like the branch pointers do" {
	cd "$TEST_TMP" || return 1
	git checkout -q -b feat/2651/slashy main || return 1
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m slashy1 || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	[ -f .claude/.session-state/ship-cycle/branch/feat/2651/slashy.approach-directive-emitted ]
}

@test "detached resume does NOT consume the checkpoint (marker only on live emission)" {
	# Backup review on 3bc669e: the post-commit hook runs `resume`
	# detached with SHIP_PR_IN_RESUME=1, whose emit is stdout-only (no
	# ack) into a log nobody reads — persisting the marker there retires
	# the question unanswered. The marker must survive only a LIVE pass.
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run env SHIP_PR_IN_RESUME=1 bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	[ ! -f .claude/.session-state/ship-cycle/branch/feat-2651-approach.approach-directive-emitted ] || return 1
	# The next LIVE pass re-fires and persists.
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m live || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	[ -f .claude/.session-state/ship-cycle/branch/feat-2651-approach.approach-directive-emitted ]
}

@test "recreated same-name branch on a foreign lineage RE-EMITS (marker sha not ancestor)" {
	# phase2 r2: a bare sentinel would survive delete+recreate within a
	# session and suppress the checkpoint on an unrelated lineage; the
	# marker's recorded sha must be an ancestor of HEAD to suppress.
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	# Recreate the branch from main: same name, different lineage
	# (main has no commit from the old branch).
	git checkout -q main || return 1
	git branch -q -D feat-2651-approach || return 1
	git checkout -q -b feat-2651-approach || return 1
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m recreated || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]]
}

@test "marker write failure warns, still advances, and may re-fire" {
	cd "$TEST_TMP" || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	# Block the branch/ dir with a FILE so mkdir -p and the marker write
	# both fail: the directive must stay advisory (warn + advance).
	# (start already created the real dir for the pointer — replace it.)
	rm -rf .claude/.session-state/ship-cycle/branch || return 1
	: >.claude/.session-state/ship-cycle/branch || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	[[ $output == *'marker write failed'* ]] || return 1
	[[ $output == *'advanced to phase0.5'* ]] || return 1
	# The promised re-fire is real: with the blocker removed and no
	# marker recorded, the next branch-ready pass emits again (and this
	# time persists the marker) — phase2 r3.
	rm -f .claude/.session-state/ship-cycle/branch || return 1
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m refire || return 1
	run bash "$SCRIPT" start
	[ "$status" -eq 0 ] || return 1
	run bash "$SCRIPT" next
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'APPROACH REVIEW'* ]] || return 1
	[ -f .claude/.session-state/ship-cycle/branch/feat-2651-approach.approach-directive-emitted ]
}
