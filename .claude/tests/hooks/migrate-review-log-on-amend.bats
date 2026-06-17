#!/usr/bin/env bats
# covers: hooks/migrate-review-log-on-amend.sh
#
# #2296: an amend rotates HEAD's SHA, so a graduation marker certifying Phase
# 0.5/1 at the pre-amend SHA is stale. The hook invalidates it immediately on
# the post-commit amend, BEFORE the existing review-log migration. These are
# integration tests: a real throwaway git repo, the REAL phase-graduation lib
# (the same one the hook sources via BASH_SOURCE/../_lib), and a real amend.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/migrate-review-log-on-amend.sh"
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/phase-graduation.sh"
	[ -f "$HOOK" ]
	[ -f "$LIB" ]
	TMP=$(mktemp -d -t mrloa.XXXXXX) || return 1
	cd "$TMP" || return 1
	git init -q
	git config user.email t@t
	git config user.name t
	echo seed >f
	git add f
	git commit -qm seed
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */mrloa.* ]] && rm -rf "$TMP"
	return 0
}

@test "amend invalidates an existing graduation marker (#2296)" {
	git checkout -q -b feat/amendtest
	# Establish a graduation marker via the SAME lib the hook will source.
	# shellcheck disable=SC1090
	source "$LIB"
	echo work >g
	git add g
	git commit -qm work
	graduation_mark "feat/amendtest" "$(git rev-parse HEAD)" 1
	marker=$(graduation_marker_path "feat/amendtest")
	[ -f "$marker" ]
	# Amend → rotates HEAD's SHA + writes a "commit (amend)" reflog subject.
	git commit -q --amend -m "work amended"
	run bash "$HOOK"
	[ "$status" -eq 0 ]
	[ ! -f "$marker" ] # marker invalidated by the amend
	[[ $output == *"invalidated stale graduation marker"* ]]
}

@test "amend with NO graduation marker is silent + rc 0 (#2296)" {
	git checkout -q -b feat/nomarker
	echo work >g
	git add g
	git commit -qm work
	git commit -q --amend -m "work amended"
	run bash "$HOOK"
	[ "$status" -eq 0 ]
	[[ $output != *"invalidated stale graduation marker"* ]]
}

@test "a normal (non-amend) commit leaves the graduation marker intact (#2296)" {
	git checkout -q -b feat/normal
	# shellcheck disable=SC1090
	source "$LIB"
	echo work >g
	git add g
	git commit -qm work
	graduation_mark "feat/normal" "$(git rev-parse HEAD)" 1
	marker=$(graduation_marker_path "feat/normal")
	[ -f "$marker" ]
	# A regular follow-up commit (NOT an amend) must not invalidate — the hook
	# exits at the reflog amend-subject guard before reaching invalidation.
	echo more >h
	git add h
	git commit -qm more
	run bash "$HOOK"
	[ "$status" -eq 0 ]
	[[ $output != *"invalidated stale graduation marker"* ]] # no noisy invalidation on a non-amend
	[ -f "$marker" ]                                         # still present — only amends invalidate
}
