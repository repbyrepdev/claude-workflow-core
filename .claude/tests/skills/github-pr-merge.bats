#!/usr/bin/env bats
# covers: skills/github-pr-merge/run.sh
# shellcheck disable=SC2030,SC2031,SC2089,SC2090  # bats runs each @test in a
# subshell (2030/2031 are that, by design); FAKE_* hold literal JSON handed to
# the gh shim via env — the embedded quotes are intended bytes (2089/2090).
# #2487 --auto arm-mode. The refuse/verify branches are the security value
# and real usage rarely exercises them (an armed PR just merges) — so each
# outcome branch gets a fixture: tag-conflict, non-OPEN refusal, armed
# happy-path (exact gh args incl. the --match-head-commit pin),
# --no-delete-branch, clean-status-fallback immediate merge,
# neither-armed-merged-nor-queued hard error, merge-queue membership
# success, failed-check warn.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/skills/github-pr-merge/run.sh"
	TEST_TMP=$(mktemp -d -t gh-pr-merge-auto.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	export GH_ARGS_LOG="$TEST_TMP/gh-args.log"
}

teardown() {
	# Leave TEST_TMP before deleting it; fall back through TMPDIR/HOME so a
	# missing /tmp cannot skip the cleanup below.
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */gh-pr-merge-auto.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Fake gh dispatching on subcommand + --json field list. Reads canned JSON
# from env: FAKE_STATE (pre-merge fetch), FAKE_POST (post-arm verification),
# FAKE_DEL (repo delete-branch-on-merge). `pr merge` appends its args.
_install_gh_shim() {
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
"pr view")
	case "$*" in
	*statusCheckRollup*) printf '%s\n' "$FAKE_STATE" ;;
	*autoMergeRequest*)
		if [ "${FAKE_POST_FAIL:-0}" = "1" ]; then
			echo "Unknown JSON field: \"bogus\"" >&2
			exit 1
		fi
		[ "${FAKE_STDERR_NOISE:-0}" = "1" ] && echo "! gh update available" >&2
		printf '%s\n' "$FAKE_POST"
		;;
	*) echo "{}" ;;
	esac
	;;
"pr merge")
	printf '%s\n' "$*" >>"$GH_ARGS_LOG"
	exit 0
	;;
"repo view")
	printf '%s\n' "${FAKE_DEL:-false}"
	;;
"api graphql")
	if [ "${FAKE_QUEUE_FAIL:-0}" = "1" ]; then
		echo "GraphQL: Could not resolve to a Repository" >&2
		exit 1
	fi
	[ "${FAKE_STDERR_NOISE:-0}" = "1" ] && echo "! gh update available" >&2
	printf '%s\n' "${FAKE_QUEUED:-false}"
	;;
*)
	exit 0
	;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
}

_state() { # $1=state $2=failed_count $3=mergeable(default MERGEABLE)
	local failed=""
	[ "${2:-0}" -gt 0 ] && failed='{"context":"ci","state":"FAILURE"}'
	printf '{"state":"%s","mergeable":"%s","mergeStateStatus":"BLOCKED","head":"headsha1","checks":[%s]}' "$1" "${3:-MERGEABLE}" "$failed"
}

@test "--auto with --tag refuses (rc 2) before any gh call" {
	run bash "$SCRIPT" --pr 55 --auto --tag v1.0.0
	[ "$status" -eq 2 ]
	[[ $output == *"incompatible with --auto"* ]]
}

@test "--auto on a CLOSED PR refuses deterministically before the approval gate (rc 2)" {
	_install_gh_shim
	export FAKE_STATE
	FAKE_STATE=$(_state CLOSED 0)
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 2 ]
	[[ $output == *"cannot arm auto-merge"* ]]
}

@test "--auto armed happy path: exact gh args + armed message (rc 0)" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST FAKE_DEL
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":true,"queued":false,"head":"abc1234"}'
	FAKE_DEL=true
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	grep -qx "pr merge 55 --squash --auto --match-head-commit headsha1 --delete-branch" "$GH_ARGS_LOG"
	[[ $output == *"Auto-merge armed for PR #55"* ]]
}

@test "--auto --no-delete-branch omits the flag from gh args" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":true,"queued":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto --no-delete-branch </dev/null"
	[ "$status" -eq 0 ]
	grep -qx "pr merge 55 --squash --auto --match-head-commit headsha1" "$GH_ARGS_LOG"
	[[ $output == *"Auto-merge armed for PR #55"* ]]
}

@test "--auto clean-status fallback: reports IMMEDIATE merge, not armed (rc 0)" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"MERGED","armed":false,"queued":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"merged it IMMEDIATELY"* ]]
	[[ $output != *"Auto-merge armed"* ]]
}

@test "--auto neither-armed-merged-nor-queued is a hard error (rc 2)" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":false,"queued":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 2 ]
	[[ $output == *"neither merged, armed, nor queued"* ]]
}

@test "--auto merge-queue membership is a success outcome (rc 0)" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST FAKE_QUEUED
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":false,"head":"abc1234"}'
	FAKE_QUEUED=true
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"entered the merge queue"* ]]
}

@test "--auto queue-probe failure yields UNKNOWN + WARN exit 0, not the exit-2 hard error" {
	# A probe blip after a successful enqueue must not report failure — the
	# side effect already happened (same posture as the POST-failure WARN).
	_install_gh_shim
	export FAKE_STATE FAKE_POST FAKE_QUEUE_FAIL
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":false,"head":"abc1234"}'
	FAKE_QUEUE_FAIL=1
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"queue state UNKNOWN"* ]]
	# The probe's stderr must surface in the WARN (captured separately, not
	# discarded and not mixed into the parsed payload).
	[[ $output == *"Could not resolve to a Repository"* ]]
	[[ $output != *"neither merged, armed, nor queued"* ]]
}

@test "--auto stderr noise on SUCCESS does not pollute the parsed payloads" {
	# A stray gh notice on stderr (update nag, deprecation warning) used to be
	# 2>&1-merged into POST/post_queued, corrupting the jq parse / the string
	# compare. With stderr captured separately, a noisy-but-successful gh must
	# still land in the armed-outcome branch.
	_install_gh_shim
	export FAKE_STATE FAKE_POST FAKE_STDERR_NOISE
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":true,"head":"abc1234"}'
	FAKE_STDERR_NOISE=1
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"Auto-merge armed for PR #55"* ]]
	[[ $output != *"queue state UNKNOWN"* ]]
}

@test "--auto POST verification failure degrades to WARN, never dies post-merge (rc 0)" {
	# #2489: the merge/arm side effect already happened - a failing verify
	# query must not kill the wrapper (observed live: invalid --json field).
	_install_gh_shim
	export FAKE_STATE FAKE_POST_FAIL
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST_FAIL=1
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"outcome verification unavailable"* ]]
	# The failed query's stderr must surface in the WARN (separate capture).
	[[ $output == *"Unknown JSON field"* ]]
}

@test "--auto arms even when mergeable=CONFLICTING (skips the immediate-path gate)" {
	# The immediate path refuses non-MERGEABLE PRs; --auto deliberately does
	# not (the platform holds the merge until the ruleset is satisfied).
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0 CONFLICTING)
	FAKE_POST='{"state":"OPEN","armed":true,"queued":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"Auto-merge armed for PR #55"* ]]
}

@test "--auto warns when --delete-branch is armed but repo auto-delete is OFF" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST FAKE_DEL
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":true,"queued":false,"head":"abc1234"}'
	FAKE_DEL=false
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"--delete-branch has no effect on an ARMED merge"* ]]
}

@test "--auto warns on currently-FAILED checks before arming" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 1)
	FAKE_POST='{"state":"OPEN","armed":true,"queued":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"currently FAILED"* ]]
}
