#!/usr/bin/env bats
# covers: scripts/cr/local-review.sh
#
# #234 (v0.32.x): local-review.sh gained CR-review timeout handling — a
# client-side `timeout` wrapper + exit-4 SSOT contract (sibling to the
# rate_limit exit-3). Before this the script had NO bats coverage at all; the
# new logic is the first thing tested here. Drives the REAL local-review.sh
# against a tmp git repo with a PATH-stubbed `coderabbit` (and, for the
# client-kill case, a stubbed `timeout`) and `--force` to skip the budget /
# phase1 / phase0.5 preflight gates. Outcomes covered:
#   * CR emits a server-side {"errorType":"timeout"} event → exit 4
#   * client-side `timeout` kills the review (rc 124) → exit 4
#   * normal review with findings (no timeout) → exit 1, NOT 4 (baseline that
#     the wrapper/detection didn't break the happy path)

# Per-test STUB exports feed PATH-stubbed children within the same test
# (SC2030/SC2031 false positives — same as the ship-pr-cycle suites).
# shellcheck disable=SC2030,SC2031

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LR="$PLUGIN/scripts/cr/local-review.sh"
	[ -x "$LR" ]
	command -v git >/dev/null
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t cr-localrev.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Tmp git repo: local-review.sh derives REPO_ROOT via git rev-parse, and
	# scm_log / cr-budget logging write under $REPO_ROOT/.claude/. A real HEAD
	# is needed for scm_log's `git rev-parse --short HEAD`.
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p bin .claude/logs .claude/review-log
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164 # best-effort; rm guarded below
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cr-localrev.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Write a `coderabbit` stub that prints $1 (a JSON line) to stdout and exits $2.
_stub_coderabbit() {
	{
		echo '#!/usr/bin/env bash'
		printf 'printf "%%s\\n" %q\n' "$1"
		printf 'exit %s\n' "$2"
	} >"$TEST_TMP/bin/coderabbit"
	chmod +x "$TEST_TMP/bin/coderabbit"
}

@test "local-review: CR server-side timeout event → exit 4 (#234)" {
	# CR_LOCAL_REVIEW_TIMEOUT=0 disables the client-side wrapper so this isolates
	# the EVENT-detection path: CR emits its own timeout event then exits 0, and
	# the grep-on-TEE_OUT detection must still raise exit 4.
	_stub_coderabbit '{"type":"error","errorType":"timeout","recoverable":false}' 0
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 4 ]
	[[ $output == *"timed out"* ]]
}

@test "local-review: client-side timeout kill (rc 124) → exit 4 (#234)" {
	# Stub `timeout` to exit 124 (its SIGTERM convention) so the wrapper path is
	# exercised without a real wall-clock wait. coderabbit is stubbed too so the
	# `command -v coderabbit` preflight passes (the timeout stub exits before
	# ever exec'ing it).
	_stub_coderabbit '{"type":"complete","findings":0}' 0
	{
		echo '#!/usr/bin/env bash'
		echo 'exit 124'
	} >"$TEST_TMP/bin/timeout"
	chmod +x "$TEST_TMP/bin/timeout"
	cd "$TEST_TMP" || return 1
	# CR_LOCAL_REVIEW_TIMEOUT>0 + the stubbed `timeout` on PATH → wrapper used.
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=600 run "$LR" --force --base main
	[ "$status" -eq 4 ]
	[[ $output == *"timed out"* ]]
}

@test "local-review: normal review with findings → exit 1, not 4 (#234)" {
	# Baseline: a complete review with findings exits 1 (CR's findings convention)
	# and must NOT be misclassified as a timeout. Proves the wrapper + detection
	# left the happy path intact. findings>0 also skips the 0-findings cache
	# block (which would need a `main` ref in the tmp repo).
	_stub_coderabbit '{"type":"complete","findings":2}' 1
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 1 ]
	[[ $output != *"timed out"* ]]
}
