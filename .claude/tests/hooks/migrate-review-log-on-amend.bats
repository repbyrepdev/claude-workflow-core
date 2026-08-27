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
	[[ $output != *"invalidated stale graduation marker"* ]] || return 1 # no noisy invalidation on a non-amend
	[ -f "$marker" ]                                                     # still present — only amends invalidate
}

@test "hook FAILS LOUD (exit 1 + ERROR) outside a git repository (#2483)" {
	# #2483: resolver failures were silent exit-0 no-ops; they must now surface.
	# git ignores a post-commit hook's exit status (githooks(5)) so this can
	# never block a commit; the documented caller's `|| true` only keeps a
	# set -e post-commit DISPATCHER running its remaining hooks after our exit 1.
	NOGIT=$(mktemp -d -t mrloa-nogit.XXXXXX)
	run bash -c "cd '$NOGIT' && bash '$HOOK'"
	rm -rf "$NOGIT"
	[ "$status" -eq 1 ]
	[[ $output == *"ERROR"* ]] || return 1
	[[ $output == *"not inside a git repository"* ]]
}

# ---- #2483 round-1 lock-in tests -------------------------------------------
# Shared PATH-shim helper: a fake `git` that fails for ONE subcommand shape and
# execs the real git otherwise. $1 = match mode (abbrev-ref | reflog | revparse-head).
_make_git_shim() {
	REAL_GIT=$(command -v git)
	mkdir -p "$TMP/bin"
	{
		echo '#!/bin/bash'
		echo "REAL='$REAL_GIT'"
		case "$1" in
		abbrev-ref) echo 'if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then exit 128; fi' ;;
		reflog) echo 'if [ "${1:-}" = "reflog" ]; then exit 128; fi' ;;
		revparse-head) echo 'if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "HEAD" ]; then exit 128; fi' ;;
		esac
		echo 'exec "$REAL" "$@"'
	} >"$TMP/bin/git"
	chmod +x "$TMP/bin/git"
}

@test "branch-resolution failure still MIGRATES the review-log (fail-loud, non-fatal) (#2483)" {
	# The invalidation preflight must not abort the hook's PRIMARY #512 job.
	git checkout -q -b feat/decouple
	echo work >g
	git add g
	git commit -qm work
	c2=$(git rev-parse HEAD)
	mkdir -p .claude/review-log
	printf '{"sha":"%s","phase":1,"round":1,"agent":"code-reviewer","findings":0}\n' "$c2" >".claude/review-log/${c2}.jsonl"
	git commit -q --amend -m "work amended"
	c2p=$(git rev-parse HEAD)
	_make_git_shim abbrev-ref
	run bash -c "PATH='$TMP/bin':\$PATH bash '$HOOK'"
	[ "$status" -eq 1 ]                                                # fail-loud rc
	[[ $output == *"cannot resolve the current branch"* ]] || return 1 # the ERROR surfaced
	[ -f ".claude/review-log/${c2p}.jsonl" ]                           # migration STILL ran
	run jq -r '.sha' ".claude/review-log/${c2p}.jsonl"
	[[ $output == "$c2p" ]] # sha rewritten to the amended commit
}

@test "reflog read failure is fail-loud (rc 1 + ERROR), not 'not an amend' (#2483)" {
	git checkout -q -b feat/reflogfail
	echo work >g
	git add g
	git commit -qm work
	_make_git_shim reflog
	run bash -c "PATH='$TMP/bin':\$PATH bash '$HOOK'"
	[ "$status" -eq 1 ]
	[[ $output == *"ERROR"* ]] || return 1
	[[ $output == *"cannot read the reflog"* ]]
}

@test "HEAD resolution failure after a detected amend is fail-loud (#2483)" {
	git checkout -q -b feat/headfail
	echo work >g
	git add g
	git commit -qm work
	git commit -q --amend -m "work amended"
	_make_git_shim revparse-head
	run bash -c "PATH='$TMP/bin':\$PATH bash '$HOOK'"
	[ "$status" -eq 1 ]
	[[ $output == *"ERROR"* ]] || return 1
	[[ $output == *"cannot resolve HEAD"* ]]
}

@test "unreadable-lib WARN is evidence-gated: fires with a marker present, silent without (#2483)" {
	# Copy the hook out from under its _lib sibling (bare-symlink install shape).
	mkdir -p "$TMP/hooks"
	cp "$HOOK" "$TMP/hooks/migrate-review-log-on-amend.sh"
	git checkout -q -b feat/warngate
	echo work >g
	git add g
	git commit -qm work
	git commit -q --amend -m "work amended"
	# (B) no marker dir → silent (no WARN), rc 0
	run bash "$TMP/hooks/migrate-review-log-on-amend.sh"
	[ "$status" -eq 0 ]
	[[ $output != *"graduation lib unreadable"* ]] || return 1
	# (A) marker evidence present → WARN fires, rc 0
	mkdir -p .claude/.session-state/phase-graduation
	printf '{"branch":"other","graduated_sha":"deadbeef","phase1_round":1}\n' >.claude/.session-state/phase-graduation/other-12345678.json
	git commit -q --amend -m "work amended again"
	run bash "$TMP/hooks/migrate-review-log-on-amend.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"graduation lib unreadable"* ]] || return 1
	[[ $output == *"ancestry check"* ]] # message cites the real backstop
}
