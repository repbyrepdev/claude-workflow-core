#!/usr/bin/env bats
# covers: skills/github-pr-merge/run.sh
# shellcheck disable=SC2030,SC2031,SC2089,SC2090  # bats runs each @test in a
# subshell (2030/2031 are that, by design); FAKE_* hold literal JSON handed to
# the gh shim via env — the embedded quotes are intended bytes (2089/2090).
# #2487 --auto arm-mode. The refuse/verify branches are the security value
# and real usage rarely exercises them (an armed PR just merges) — so each
# outcome branch gets a fixture: tag-conflict, non-OPEN refusal, armed
# happy-path (exact gh args), --no-delete-branch, clean-status-fallback
# immediate merge, neither-armed-nor-merged hard error, failed-check warn.

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
	cd /tmp || return 0
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
	*autoMergeRequest*) printf '%s\n' "$FAKE_POST" ;;
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
*)
	exit 0
	;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
}

_state() { # $1=state $2=failed_count
	local failed=""
	[ "${2:-0}" -gt 0 ] && failed='{"context":"ci","state":"FAILURE"}'
	printf '{"state":"%s","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","checks":[%s]}' "$1" "$failed"
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
	FAKE_POST='{"state":"OPEN","armed":true,"head":"abc1234"}'
	FAKE_DEL=true
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	grep -qx "pr merge 55 --squash --auto --delete-branch" "$GH_ARGS_LOG"
	[[ $output == *"Auto-merge armed for PR #55"* ]]
}

@test "--auto --no-delete-branch omits the flag from gh args" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":true,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto --no-delete-branch </dev/null"
	[ "$status" -eq 0 ]
	grep -qx "pr merge 55 --squash --auto" "$GH_ARGS_LOG"
}

@test "--auto clean-status fallback: reports IMMEDIATE merge, not armed (rc 0)" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"MERGED","armed":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"merged it IMMEDIATELY"* ]]
	[[ $output != *"Auto-merge armed"* ]]
}

@test "--auto neither-armed-nor-merged is a hard error (rc 2)" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 0)
	FAKE_POST='{"state":"OPEN","armed":false,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 2 ]
	[[ $output == *"neither merged nor armed"* ]]
}

@test "--auto warns on currently-FAILED checks before arming" {
	_install_gh_shim
	export FAKE_STATE FAKE_POST
	FAKE_STATE=$(_state OPEN 1)
	FAKE_POST='{"state":"OPEN","armed":true,"head":"abc1234"}'
	run bash -c "APPROVE=1 bash '$SCRIPT' --pr 55 --auto </dev/null"
	[ "$status" -eq 0 ]
	[[ $output == *"currently FAILED"* ]]
}
