#!/usr/bin/env bats
# covers: hooks/cr-pause-detector.sh
#
# #2571: the `@coderabbitai review` follow-up is CONDITIONAL. The
# unconditional post contradicted the ship-cycle never-post rule and
# burned CR rate allowance (each request counts against the budget whose
# exhaustion causes the 50-min "Review limit reached" stalls). Contract:
#   resume  → always posted on an unresumed pause (unchanged);
#   review  → ONLY when the head commit is at-or-after the pause notice
#             AND no CR in-progress marker is newer than the pause.
# The audit row records the OUTCOME (review_posted true only when the
# review comment actually posted).
#
# Harness: CLI mode (--pr), tmp git repo with a controllable head commit
# time (GIT_COMMITTER_DATE), PATH-stubbed gh serving a comments fixture
# and logging `pr comment` bodies.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	HOOK="${REPO_ROOT}/hooks/cr-pause-detector.sh"
	TEST_TMP=$(mktemp -d -t cr-pause-cond.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	export GH_ARGS_LOG="$TEST_TMP/gh-args.log"
	export COMMENTS_FIXTURE="$TEST_TMP/comments.json"
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_ARGS_LOG"
case "$1 $2" in
"pr comment")
	if [ "${FAIL_REVIEW_POST:-0}" = "1" ] && printf '%s' "$*" | grep -q "coderabbitai review"; then
		exit 1
	fi
	exit 0
	;;
"repo view")
	printf 'testowner/testrepo\n'
	;;
*)
	case "$*" in
	*"/issues/"*"/comments"*) cat "$COMMENTS_FIXTURE" ;;
	*) echo "[]" ;;
	esac
	;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cr-pause-cond.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Build the sandbox repo with the head commit at a given UTC instant.
_repo_with_head_at() { # $1 = ISO UTC commit time
	(
		set -e
		cd "$TEST_TMP"
		git init -q repo
		cd repo
		GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" \
			git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	) || return 1
	cd "$TEST_TMP/repo" || return 1
}

# Comments fixture: a pause notice at $1, optionally a CR busy marker at $2.
_comments_pause_at() {
	local pause_ts="$1" busy_ts="${2:-}"
	if [ -n "$busy_ts" ]; then
		printf '[{"user":{"login":"coderabbitai"},"created_at":"%s","body":"Reviews paused. To resume, comment @coderabbitai resume"},{"user":{"login":"coderabbitai"},"created_at":"%s","body":"Currently processing new changes in this PR."}]' \
			"$pause_ts" "$busy_ts" >"$COMMENTS_FIXTURE"
	else
		printf '[{"user":{"login":"coderabbitai"},"created_at":"%s","body":"Reviews paused. To resume, comment @coderabbitai resume"}]' \
			"$pause_ts" >"$COMMENTS_FIXTURE"
	fi
}

@test "commits landed AFTER the pause + no busy marker: resume AND review posted, audit says review_posted=true" {
	_repo_with_head_at "2026-08-24T12:00:00Z"
	_comments_pause_at "2026-08-24T11:00:00Z"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	[[ $output == *"resume + review"* ]]
	grep -q "pr comment 42 --body @coderabbitai resume" "$GH_ARGS_LOG"
	grep -q "pr comment 42 --body @coderabbitai review" "$GH_ARGS_LOG"
	grep -q '"review_posted":true' .claude/logs/cr-resume-fired.jsonl
}

@test "NO commits after the pause: resume only — the banned review-request stays unposted" {
	_repo_with_head_at "2026-08-24T10:00:00Z"
	_comments_pause_at "2026-08-24T11:00:00Z"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	# $output is checked BEFORE any `run !` below — run resets it.
	[[ $output == *"resume ONLY"* ]]
	grep -q "pr comment 42 --body @coderabbitai resume" "$GH_ARGS_LOG"
	run ! grep -q "pr comment 42 --body @coderabbitai review" "$GH_ARGS_LOG"
	grep -q '"review_posted":false' .claude/logs/cr-resume-fired.jsonl
}

@test "commits after the pause BUT CR already busy (in-progress marker newer than pause): resume only" {
	_repo_with_head_at "2026-08-24T12:00:00Z"
	_comments_pause_at "2026-08-24T11:00:00Z" "2026-08-24T11:30:00Z"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	[[ $output == *"resume ONLY"* ]]
	grep -q "pr comment 42 --body @coderabbitai resume" "$GH_ARGS_LOG"
	run ! grep -q "pr comment 42 --body @coderabbitai review" "$GH_ARGS_LOG"
	grep -q '"review_posted":false' .claude/logs/cr-resume-fired.jsonl
}

@test "already resumed by a human: no posts at all (unchanged behavior)" {
	_repo_with_head_at "2026-08-24T12:00:00Z"
	printf '[{"user":{"login":"coderabbitai"},"created_at":"2026-08-24T11:00:00Z","body":"Reviews paused. To resume, comment @coderabbitai resume"},{"user":{"login":"human"},"created_at":"2026-08-24T11:05:00Z","body":"@coderabbitai resume"}]' \
		>"$COMMENTS_FIXTURE"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	[[ $output != *"auto-posted"* ]]
	run ! grep -q "pr comment" "$GH_ARGS_LOG"
}

@test "second busy wording ('Come back again in a few minutes') also suppresses the review post" {
	_repo_with_head_at "2026-08-24T12:00:00Z"
	printf '[{"user":{"login":"coderabbitai"},"created_at":"2026-08-24T11:00:00Z","body":"Reviews paused. To resume, comment @coderabbitai resume"},{"user":{"login":"coderabbitai"},"created_at":"2026-08-24T11:30:00Z","body":"Come back again in a few minutes."}]' \
		>"$COMMENTS_FIXTURE"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	grep -q "pr comment 42 --body @coderabbitai resume" "$GH_ARGS_LOG"
	run ! grep -q "pr comment 42 --body @coderabbitai review" "$GH_ARGS_LOG"
}

@test "unparseable pause timestamp fails toward NOT posting the banned request" {
	_repo_with_head_at "2026-08-24T12:00:00Z"
	printf '[{"user":{"login":"coderabbitai"},"created_at":"garbage-not-a-date","body":"Reviews paused. To resume, comment @coderabbitai resume"}]' \
		>"$COMMENTS_FIXTURE"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	[[ $output == *"not parseable by date"* ]]
	[[ $output == *"resume ONLY"* ]]
	grep -q "pr comment 42 --body @coderabbitai resume" "$GH_ARGS_LOG"
	run ! grep -q "pr comment 42 --body @coderabbitai review" "$GH_ARGS_LOG"
}

@test "AT-OR-AFTER boundary: head commit exactly at the pause instant posts the review" {
	_repo_with_head_at "2026-08-24T11:00:00Z"
	_comments_pause_at "2026-08-24T11:00:00Z"
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	[[ $output == *"resume + review"* ]]
	grep -q "pr comment 42 --body @coderabbitai review" "$GH_ARGS_LOG"
}

@test "review post FAILS while resume succeeded: outcome false, status names the review post (p2r4)" {
	_repo_with_head_at "2026-08-24T12:00:00Z"
	_comments_pause_at "2026-08-24T11:00:00Z"
	export FAIL_REVIEW_POST=1
	run "$HOOK" --pr 42
	[ "$status" -eq 0 ]
	grep -q '"review_posted":false' .claude/logs/cr-resume-fired.jsonl
	grep -q '"status":"errored-review-post-failed"' .claude/logs/cr-resume-fired.jsonl
}
