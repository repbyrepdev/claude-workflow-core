#!/usr/bin/env bats
# covers: scripts/cr/thread-reply.sh
#
# (#2548) The stage that closes the cycle's oldest gap: a CR thread that is
# verified-fixed, a false positive, or a deliberate rejection had no defined
# action. The standing rule says do NOT resolve it by hand — and nothing said
# what to do instead, so the cycle stalled at merge-gate with non-zero threads.
# Observed on PR #2540 (5 threads, 1 fixable by code) and again on #2635, where
# both replies were posted by hand.
#
# Drives the REAL script against a tmp git repo with a PATH-stubbed `gh`, so
# the GraphQL read/classify/reply paths are exercised without the network.
#
# The properties that matter, and why each is here:
#   * resolveReviewThread is NEVER emitted — that is the standing rule, and a
#     regression would silently start closing threads the reviewer owns.
#   * verified-fixed is gated on `git show HEAD:<path>`. On #2540 a commit
#     message claimed a fix that had been lost from the tree; CR was right to
#     keep flagging it. "Verify against the committed file, not memory" has to
#     be a command, not a habit.
#   * actionable is refused for reply — a real defect must not leave the cycle
#     with prose attached instead of a code change.
#   * reply_state is read SERVER-SIDE, so it survives a session reset.

# Per-test STUB exports feed PATH-stubbed children within the same test
# (SC2030/SC2031 false positives — same as the sibling cr suites).
# shellcheck disable=SC2030,SC2031

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	TR="$PLUGIN/scripts/cr/thread-reply.sh"
	[ -x "$TR" ]
	command -v git >/dev/null
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t cr-threadreply.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		mkdir -p bin .claude/logs
		printf 'committed\n' >tracked.txt
		git add tracked.txt
		git -c user.email=t@t -c user.name=t commit -q -m init
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
	GH_CALLS="$TEST_TMP/gh-calls.log"
	: >"$GH_CALLS"
}

teardown() {
	case "${TEST_TMP:-}" in
	*/cr-threadreply.*) rm -rf "$TEST_TMP" ;;
	esac
}

# Stub `gh`: records every invocation, answers `repo view` and the
# reviewThreads query from $1, and echoes a reply mutation result.
_stub_gh() { # $1 = threads JSON array (the .nodes payload)
	local nodes="$1"
	printf '%s' "$nodes" >"$TEST_TMP/nodes.json"
	cat >"$TEST_TMP/bin/gh" <<-'STUB'
		#!/bin/bash
		printf '%s\n' "$*" >>"$GH_CALLS"
		case "$*" in
		*"repo view"*) printf 'o/r\n'; exit 0 ;;
		esac
		case "$*" in
		*addPullRequestReviewThreadReply*)
			printf '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"C_1","url":"https://example/c/1"}}}}\n'
			exit 0
			;;
		*reviewThreads*)
			nodes=$(cat "$NODES_FILE")
			printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}}}}\n' "$nodes"
			exit 0
			;;
		esac
		printf '{}\n'
	STUB
	chmod +x "$TEST_TMP/bin/gh"
	export GH_CALLS
	export NODES_FILE="$TEST_TMP/nodes.json"
}

# Args are forwarded through "$@", NOT interpolated into a `bash -c` string:
# a `--body "two words"` collapses under $* and the second word arrives as a
# stray argument.
_run_tr() { # remaining args passed to thread-reply.sh
	run env PATH="$TEST_TMP/bin:$PATH" GH_CALLS="$GH_CALLS" NODES_FILE="$TEST_TMP/nodes.json" \
		bash -c 'cd "$1" || exit 9; shift; exec "$@"' _ "$TEST_TMP" "$TR" "$@"
}

# One unaddressed thread (only CR has spoken) + one replied (a human answered).
_two_threads() {
	cat <<-'J'
		[
		 {"id":"T_un","isResolved":false,"isOutdated":false,"path":"a.sh","line":10,
		  "comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"first finding"}]}},
		 {"id":"T_rep","isResolved":false,"isOutdated":false,"path":"b.sh","line":20,
		  "comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"second finding"},
		                       {"author":{"login":"someone"},"body":"here is the disproof"}]}},
		 {"id":"T_done","isResolved":true,"isOutdated":false,"path":"c.sh","line":30,
		  "comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"already resolved"}]}}
		]
	J
}

@test "classifies unaddressed vs replied-awaiting-CR from SERVER state" {
	# The distinction the merge gate depends on. Read from the thread's own
	# comments — not a local log — so it survives a session reset and cannot
	# drift from the real PR.
	_stub_gh "$(_two_threads)"
	_run_tr 7 --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.unaddressed')" = "1" ]
	[ "$(printf '%s' "$output" | jq -r '.replied_awaiting_cr')" = "1" ]
	# The RESOLVED thread is out of scope entirely — 3 nodes, 2 unresolved.
	[ "$(printf '%s' "$output" | jq -r '.unresolved')" = "2" ]
	[ "$(printf '%s' "$output" | jq -r '.threads[] | select(.id=="T_un") | .reply_state')" = "unaddressed" ]
	[ "$(printf '%s' "$output" | jq -r '.threads[] | select(.id=="T_rep") | .reply_state')" = "replied-awaiting-CR" ]
}

@test "a STRANDED thread gets its own bucket, not 'unaddressed'" {
	# isResolved=false + isOutdated=true. Bucketed as `unaddressed`, the stage
	# held and told the operator to REPLY — while this script's header, the
	# merge gate and the gate deny text all say a stranded thread is the ONE
	# case where manual resolution IS correct, via resolve-stranded.sh. Wrong
	# remedy, and the same stall-with-no-defined-action the stage removes.
	_stub_gh '[{"id":"T_str","isResolved":false,"isOutdated":true,"path":"a.sh","line":1,
	            "comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"old finding"}]}}]'
	_run_tr 7 --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.stranded')" = "1" ]
	[ "$(printf '%s' "$output" | jq -r '.unaddressed')" = "0" ]
	[ "$(printf '%s' "$output" | jq -r '.threads[0].reply_state')" = "stranded" ]
	# ...and --count must not hold the stage on it, since replying is not the
	# remedy.
	_run_tr 7 --count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "--list names resolve-stranded.sh when a stranded thread exists" {
	# A bucket the operator cannot act on is as bad as no bucket. The list
	# must point at the right tool.
	_stub_gh '[{"id":"T_str","isResolved":false,"isOutdated":true,"path":"a.sh","line":1,
	            "comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"old finding"}]}}]'
	_run_tr 7 --list
	[ "$status" -eq 0 ]
	case "$output" in
	*resolve-stranded.sh*) ;;
	*)
		echo "expected the stranded remedy to be named; got: $output"
		return 1
		;;
	esac
}

@test "--count reports UNADDRESSED only, not total unresolved" {
	# The stage advances on unaddressed==0. If --count returned total
	# unresolved, a PR whose threads were all answered would never advance.
	_stub_gh "$(_two_threads)"
	_run_tr 7 --count
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "NEVER emits resolveReviewThread — the standing rule, mechanically" {
	# The reply is the action; CR resolving is the outcome. A regression here
	# would start closing threads the reviewer owns.
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class false-positive --body "disproof here"
	[ "$status" -eq 0 ]
	run grep -c 'resolveReviewThread' "$GH_CALLS"
	[ "$output" = "0" ] || {
		echo "resolveReviewThread was emitted: $(cat "$GH_CALLS")"
		return 1
	}
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" -ge 1 ] || {
		echo "no reply mutation was sent"
		return 1
	}
}

@test "verified-fixed is REFUSED when the path is not in the committed tree" {
	# The #2540 case made mechanical: a commit message claimed a fix that had
	# been lost from the working tree, and CR was right to keep flagging it.
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class verified-fixed --path missing.txt --body "fixed in abc123"
	[ "$status" -eq 3 ]
	case "$output" in
	*REFUSING*) ;;
	*)
		echo "expected an explicit refusal; got: $output"
		return 1
		;;
	esac
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" = "0" ] || {
		echo "a reply was posted despite the evidence gate failing"
		return 1
	}
}

@test "verified-fixed PASSES when the path IS committed" {
	# The counterpart: the gate must not reject a legitimate claim, or the
	# class becomes unusable and the operator routes around it.
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class verified-fixed --path tracked.txt --body "fixed in abc123"
	[ "$status" -eq 0 ]
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" -ge 1 ]
}

@test "verified-fixed without --path is refused before any network call" {
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class verified-fixed --body "fixed"
	[ "$status" -ne 0 ]
	# The reason, not just a nonzero exit. This script's `cd` wrapper exits 9,
	# an absent lib exits 2, and a bash syntax error exits 2 as well — all of
	# which satisfy "nonzero and posted nothing" while proving nothing about
	# the evidence gate this test is named for.
	case "$output" in
	*"requires --path"*) ;;
	*)
		echo "refused, but not for the missing --path; got: $output"
		return 1
		;;
	esac
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" = "0" ]
}

@test "class 'actionable' is refused — fix it, do not explain it" {
	# An actionable finding is closed by CHANGING THE CODE. Replying would let
	# a real defect leave the cycle with prose attached.
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class actionable --body "acknowledged"
	[ "$status" -eq 2 ]
	case "$output" in
	*autofix*) ;;
	*)
		echo "expected the refusal to route back to autofix; got: $output"
		return 1
		;;
	esac
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" = "0" ]
}

@test "an unknown class is refused rather than posted" {
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class whatever --body "x"
	[ "$status" -ne 0 ]
	# Naming the four valid classes is the whole value of this refusal — a
	# bare nonzero exit leaves the operator guessing which word was wrong.
	case "$output" in
	*"--class must be one of"*) ;;
	*)
		echo "refused, but without naming the valid classes; got: $output"
		return 1
		;;
	esac
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" = "0" ]
}

@test "--dry-run posts nothing" {
	_stub_gh "$(_two_threads)"
	_run_tr 7 --thread T_un --class false-positive --body "would say this" --dry-run
	[ "$status" -eq 0 ]
	case "$output" in
	*"dry-run"*) ;;
	*)
		echo "expected dry-run output; got: $output"
		return 1
		;;
	esac
	run grep -c 'addPullRequestReviewThreadReply' "$GH_CALLS"
	[ "$output" = "0" ]
}

@test "a GraphQL .errors payload FAILS CLOSED — never reads as zero threads" {
	# This feeds the merge gate. An error that reported 0 unaddressed would
	# advance a PR whose findings were never read.
	cat >"$TEST_TMP/bin/gh" <<-'STUB'
		#!/bin/bash
		case "$*" in
		*"repo view"*) printf 'o/r\n'; exit 0 ;;
		esac
		printf '{"errors":[{"message":"rate limited"}]}\n'
	STUB
	chmod +x "$TEST_TMP/bin/gh"
	run env PATH="$TEST_TMP/bin:$PATH" bash -c "cd '$TEST_TMP' && '$TR' 7 --count"
	[ "$status" -ne 0 ] || {
		echo "a GraphQL error reported success: $output"
		return 1
	}
	case "$output" in
	*0*)
		# A bare "0" on stdout would be read by the stage as "nothing to do".
		[ "$(printf '%s' "$output" | tr -d '[:space:]')" != "0" ] || {
			echo "an error path printed a bare 0 count"
			return 1
		}
		;;
	esac
}

@test "zero unresolved threads is a clean, quiet answer" {
	_stub_gh '[]'
	_run_tr 7 --count
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}
