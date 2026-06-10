#!/usr/bin/env bats
# covers: scripts/cr/watch-until-done.sh
#
# #2332: the CR-in-CI watcher must treat a path-filtered PR (CodeRabbit posts
# no check) as TERMINAL (exit 3) instead of polling to the timeout — but only
# when CR is NOT a required check and every other check is terminal. When CR
# IS required, it must keep waiting (never prematurely skip a required review).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/cr/watch-until-done.sh"
	TEST_TMP=$(mktemp -d -t watchdone.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/fakebin"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */watchdone.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Write a fake `gh` serving canned responses for the four calls the script
# makes. Scenario is passed to each run via the env (FAKE_CHECKS = gh pr checks
# output, tab-separated; FAKE_CR_REQUIRED = yes|no for CodeRabbit-required).
_make_fake_gh() {
	cat >"$TEST_TMP/fakebin/gh" <<'EOF'
#!/bin/bash
# Route on "$1 $2"; `gh api <path> ...` matches "api "* regardless of the path.
case "$1 $2" in
"pr checks") printf '%s\n' "$FAKE_CHECKS" ;;
"pr view") echo "main" ;;
"repo view") echo "owner/repo" ;;
"api "*) if [ "${FAKE_CR_REQUIRED:-no}" = yes ]; then echo "true"; else echo "false"; fi ;;
*)
	echo "fake-gh: unhandled: $*" >&2
	exit 1
	;;
esac
EOF
	chmod +x "$TEST_TMP/fakebin/gh"
}

@test "path-filtered: CR absent + others terminal + not required → exit 3 (#2332)" {
	local checks=$'gitleaks\tpass\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 3 ]
	[[ $output == *"not applicable"* ]]
}

@test "CR posts a passing check → exit 0" {
	local checks=$'CodeRabbit\tpass\t30s\ngitleaks\tpass\t2s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=no \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 30
	[ "$status" -eq 0 ]
}

@test "CR required + absent → keeps waiting (timeout exit 2), NOT premature exit 3 (#2332)" {
	# CR IS a required check, so even with CR absent + other checks terminal
	# the watcher must NOT exit 3 — it waits (and here times out → exit 2).
	local checks=$'gitleaks\tpass\t2s\nlabel\tpass\t1s'
	_make_fake_gh
	run env FAKE_CHECKS="$checks" FAKE_CR_REQUIRED=yes \
		PATH="$TEST_TMP/fakebin:$PATH" bash "$SCRIPT" 999 --interval 1 --timeout 3
	[ "$status" -eq 2 ]
}
