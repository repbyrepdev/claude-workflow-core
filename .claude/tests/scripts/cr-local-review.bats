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

@test "local-review: findings count uses the textual hash-filter (survives noisy TEE_OUT) (#2249)" {
	# Wiring + false-clean regression: local-review.sh must source canonical-
	# review-exclude.sh and tally finding LINES via canonical_review_filtered_
	# finding_count — NOT a whole-stream jq -rs slurp that a banner-interleaved
	# TEE_OUT would fail on → silent 0. Stub coderabbit with realistic noise
	# around the finding lines; the LOGGED count (what the pre-push gate reads)
	# must be 2, not 0.
	{
		echo '#!/usr/bin/env bash'
		echo 'echo "=== Running coderabbit review --agent -t committed --base main ==="'
		printf 'printf "%%s\\n" %q\n' '{"type":"finding","fileName":"README.md"}'
		echo 'echo "CodeRabbit: heartbeat reviewing..."'
		printf 'printf "%%s\\n" %q\n' '{"type":"finding","fileName":"src/x.sh"}'
		printf 'printf "%%s\\n" %q\n' '{"type":"complete","findings":2}'
		echo 'exit 1'
	} >"$TEST_TMP/bin/coderabbit"
	chmod +x "$TEST_TMP/bin/coderabbit"
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 1 ] # CR exits 1 on findings
	# Neither file is a canonical mirror in this tmp repo → both kept → 2.
	# The old jq -rs slurp would have failed on the banner lines → 0 (false-clean).
	logged=$(jq -rs 'map(select(.findings != null)) | .[-1].findings' "$TEST_TMP/.claude/logs/cr-local-review.jsonl" 2>/dev/null || echo "")
	[ "$logged" = "2" ]
}

@test "local-review: findings>0 persists detail JSONL per sha (#2484)" {
	# The tee tmpfile dies with the process and the orchestrator truncates
	# stdout, so findings detail repeatedly evaporated (6 occurrences). The
	# script must copy the tee to .claude/logs/cr-local-review-<sha7>-detail
	# .jsonl BEFORE exit when findings>0.
	{
		echo '#!/usr/bin/env bash'
		printf 'printf "%%s\\n" %q\n' '{"type":"finding","fileName":"a.sh","severity":"minor"}'
		printf 'printf "%%s\\n" %q\n' '{"type":"complete","findings":1}'
		echo 'exit 1'
	} >"$TEST_TMP/bin/coderabbit"
	chmod +x "$TEST_TMP/bin/coderabbit"
	cd "$TEST_TMP" || return 1
	# core.abbrev=12 makes bare --short diverge from --short=7 here, so this
	# test DISCRIMINATES: the detail filename must use the same bare --short
	# derivation scm_log keys the jsonl on, or the per-sha join breaks.
	git config core.abbrev 12
	sha_key=$(git rev-parse --short HEAD)
	[ "${#sha_key}" -eq 12 ]
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 1 ]
	detail="$TEST_TMP/.claude/logs/cr-local-review-${sha_key}-detail.jsonl"
	[ -f "$detail" ]
	grep -q '"type":"finding"' "$detail"
	[[ $output == *"findings detail persisted"* ]]
}

@test "local-review: mark-exhausted resolves rate-budget.sh next to ITSELF (#2519)" {
	# The old $REPO_ROOT/.claude/scripts/cr/rate-budget.sh form broke in
	# consumers without the mirror (mark-exhausted WARN, budget tracker
	# drift). Every mark-exhausted call site must use the SCRIPT_DIR
	# sibling — same resolution as the --check preflight.
	run grep -c 'SCRIPT_DIR/rate-budget.sh' "$LR"
	[ "$status" -eq 0 ]
	[ "$output" -ge 3 ]
	run grep -c 'REPO_ROOT/.claude/scripts/cr/rate-budget.sh' "$LR"
	[ "$output" -eq 0 ]
}

@test "local-review: rate_limit event marks budget exhausted via SIBLING path -> exit 3 (#2519)" {
	# Behavior companion to the text-pin above: a JSON rate_limit event
	# must (a) exit 3 per the SSOT contract, (b) append the exhausted
	# marker to THIS repo's ledger via the script-sibling rate-budget.sh,
	# (c) emit no mark-exhausted WARN. Pre-fix code in a consumer without
	# the .claude/scripts/cr mirror hit rc=127 + WARN and wrote no marker.
	{
		echo '#!/usr/bin/env bash'
		printf 'printf "%%s\\n" %q\n' '{"type":"error","errorType":"rate_limit","message":"Rate limit exceeded","recoverable":true}'
		echo 'exit 1'
	} >"$TEST_TMP/bin/coderabbit"
	chmod +x "$TEST_TMP/bin/coderabbit"
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 3 ]
	[[ $output != *"mark-exhausted failed"* ]]
	[ -f "$TEST_TMP/.claude/review-log/cr-budget.jsonl" ]
	grep -q 'exhausted' "$TEST_TMP/.claude/review-log/cr-budget.jsonl"
}
