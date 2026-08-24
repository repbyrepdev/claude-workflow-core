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

# Write a `coderabbit` stub that prints EVERY arg as its own JSON line, then
# exits with the LAST arg. Needed for the streamed-findings-then-timeout case:
# CR emits findings incrementally and the timeout arrives after them.
_stub_coderabbit_lines() {
	local rc="${*: -1}" line
	{
		echo '#!/usr/bin/env bash'
		for line in "${@:1:$#-1}"; do
			printf 'printf "%%s\\n" %q\n' "$line"
		done
		printf 'exit %s\n' "$rc"
	} >"$TEST_TMP/bin/coderabbit"
	chmod +x "$TEST_TMP/bin/coderabbit"
}

@test "local-review: a review that streams findings THEN times out SALVAGES them (#2540)" {
	# The paid-for-then-discarded bug: CR streams each finding as it goes, so a
	# timeout on a large diff means findings ALREADY arrived — but the exit-4 path
	# persisted nothing and logged findings:0, throwing away a review that consumed
	# one of the prepaid 10/hr CR-CLI slots. It must still exit 4 (defer to the
	# authoritative CR-in-CI) while PERSISTING what we bought.
	_stub_coderabbit_lines \
		'{"type":"finding","severity":"major","fileName":"a.sh"}' \
		'{"type":"finding","severity":"minor","fileName":"b.sh"}' \
		'{"type":"error","errorType":"timeout","recoverable":false}' \
		0
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	# still defers to CR-in-CI…
	[ "$status" -eq 4 ] || return 1
	[[ $output == *"timed out"* ]] || return 1
	# …but announces + persists the salvage rather than discarding it
	[[ $output == *"salvaged 2 finding"* ]] || return 1
	local sha detail
	sha=$(git rev-parse --short HEAD)
	detail="$TEST_TMP/.claude/logs/cr-local-review-${sha}-detail.jsonl"
	[ -f "$detail" ] || {
		echo "detail file NOT persisted: $detail"
		return 1
	}
	grep -q '"fileName":"a.sh"' "$detail" || return 1
	grep -q '"fileName":"b.sh"' "$detail" || return 1
	# and the audit log records the REAL partial count, not a lie of 0
	# Target the SPECIFIC ledger, not a glob over every .jsonl in logs/ — a glob
	# can match an unrelated log and make this assertion pass on the wrong file
	# (CR-in-CI #2540 phase2).
	run grep -h 'cr-local-review' "$TEST_TMP/.claude/logs/cr-local-review.jsonl"
	# assert the READ succeeded too — a missing ledger would give status 1 with
	# empty output, and the content checks below would then fail for the wrong
	# reason (CR-in-CI #2540).
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'"findings":2'* ]] || return 1
	[[ $output == *'"partial":true'* ]] || return 1
}

@test "local-review: a timeout with NO findings streamed persists nothing (#2540)" {
	# Guard the other direction: salvage must not invent a detail file when the
	# review timed out before emitting anything.
	_stub_coderabbit '{"type":"error","errorType":"timeout","recoverable":false}' 0
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 4 ] || return 1
	[[ $output != *"salvaged"* ]] || return 1
	local sha
	sha=$(git rev-parse --short HEAD)
	[ ! -f "$TEST_TMP/.claude/logs/cr-local-review-${sha}-detail.jsonl" ] || return 1
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

@test "#2544 DOGFOOD: a CR CRASH writes complete:false to the ledger" {
	# The hole the blocklist missed. Only rc 124/137 and CR's own timeout event
	# reach the flagged writer; an auth failure / rate limit / network error /
	# CLI crash lands in the PLAIN logger. Before #2544 that wrote an unflagged
	# findings:0 which the pre-push gate read as CLEAN.
	# This drives the REAL script — not a fixture — and asserts on what actually
	# lands in the ledger the gate reads.
	_stub_coderabbit '{"type":"error","errorType":"auth","recoverable":false}' 2
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	# Assert the script's OWN outcome before the next `run` clobbers $status.
	# A crashed CR must not exit 0 — otherwise the orchestrator treats the
	# stage as successful regardless of what the ledger says.
	[ "$status" -ne 0 ] || {
		echo "local-review exited 0 on a crashed CR run"
		return 1
	}
	run grep -h 'cr-local-review' "$TEST_TMP/.claude/logs/cr-local-review.jsonl"
	[ "$status" -eq 0 ] || {
		echo "no ledger entry written for a crashed run"
		return 1
	}
	[[ $output == *'"complete":false'* ]] || {
		echo "a CRASHED review was recorded WITHOUT complete:false — the gate would read it as clean. entry: $output"
		return 1
	}
}

@test "#2544 DOGFOOD: a ZERO-finding timeout still writes a valid ledger entry" {
	# CR round 4 caught the twin of the grep -c double-zero: the timeout path
	# had the same `|| echo 0`, rescued only by a regex clamp on the next line.
	# scm_log builds the entry with `--argjson findings`, which REJECTS "0\n0"
	# outright — so a zero-finding timeout would have lost its ledger line
	# entirely, and a SHA with no entry reads as "no review" rather than a
	# recorded incomplete one. Pin both the count and the completeness flag.
	_stub_coderabbit '{"type":"error","errorType":"timeout","recoverable":false}' 0
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 4 ] || return 1
	run grep -h 'cr-local-review' "$TEST_TMP/.claude/logs/cr-local-review.jsonl"
	[ "$status" -eq 0 ] || {
		echo "zero-finding timeout wrote NO ledger entry — the sha would read as 'never reviewed'"
		return 1
	}
	[[ $output == *'"findings":0'* ]] || {
		echo "zero-finding timeout did not record findings:0. entry: $output"
		return 1
	}
	[[ $output == *'"complete":false'* ]] || {
		echo "timeout entry missing complete:false — the gate would read it as clean. entry: $output"
		return 1
	}
}

@test "#2544 DOGFOOD: a genuine 0-findings review writes complete:true" {
	# The other direction, and the one the grep -c double-zero regression broke:
	# a real clean review must still be recorded as COMPLETE, or the gate walls
	# off every good push. Drives the real script end-to-end.
	_stub_coderabbit '{"type":"complete","findings":0}' 0
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	# Assert the script's OWN exit before the next `run` clobbers $status —
	# a genuinely clean review must exit 0.
	[ "$status" -eq 0 ] || {
		echo "local-review did not exit 0 on a clean review. output: $output"
		return 1
	}
	run grep -h 'cr-local-review' "$TEST_TMP/.claude/logs/cr-local-review.jsonl"
	[ "$status" -eq 0 ] || {
		echo "no ledger entry written for a clean run"
		return 1
	}
	[[ $output == *'"complete":true'* ]] || {
		echo "a genuinely CLEAN review was not recorded complete:true — every good push would be refused. entry: $output"
		return 1
	}
	[[ $output == *'"findings":0'* ]] || {
		echo "clean review did not record findings:0 (grep -c double-zero regression?). entry: $output"
		return 1
	}
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

@test "local-review: mark-exhausted ignores a consumer-tree decoy, uses the sibling (#2519)" {
	# Behavior discriminator (CR r3: converted from a static grep pin): a
	# BROKEN rate-budget.sh planted at the old consumer-tree path must be
	# irrelevant — the script resolves its SIBLING copy, so the rate_limit
	# flow still exits 3, writes the marker, and emits no WARN. Pre-fix
	# code called the decoy and failed.
	mkdir -p "$TEST_TMP/.claude/scripts/cr"
	printf '#!/usr/bin/env bash\necho ran >"%s/decoy-ran.log"\nexit 9\n' "$TEST_TMP" \
		>"$TEST_TMP/.claude/scripts/cr/rate-budget.sh"
	chmod +x "$TEST_TMP/.claude/scripts/cr/rate-budget.sh"
	_stub_coderabbit '{"type":"error","errorType":"rate_limit","message":"Rate limit exceeded","recoverable":true}' 1
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 3 ]
	[[ $output == *"rate_limit"* ]]
	[[ $output != *"mark-exhausted failed"* ]]
	# The decoy leaves a sentinel if executed — it must never run.
	[ ! -f "$TEST_TMP/decoy-ran.log" ]
	grep -q 'exhausted' "$TEST_TMP/.claude/review-log/cr-budget.jsonl"
}

@test "local-review: TEXT out-of-credits page hits the same exhausted contract -> exit 3 (#837)" {
	# The dual-path detection's OTHER branch (CR r8): no structured JSON
	# errorType event, just CR's server-side out-of-credits text page. The
	# text grep must trigger the identical SSOT contract as the JSON path:
	# exit 3, exhausted marker via the sibling rate-budget.sh, no WARN.
	_stub_coderabbit "ERROR: You've run out of usage credits" 1
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 3 ]
	[[ $output == *"text-detect"* ]]
	[[ $output != *"mark-exhausted failed"* ]]
	grep -q 'exhausted' "$TEST_TMP/.claude/review-log/cr-budget.jsonl"
}

@test "local-review: rate_limit event marks budget exhausted via SIBLING path -> exit 3 (#2519)" {
	# Primary coverage (CR r2): a JSON
	# rate_limit event must (a) exit 3 per the SSOT contract, (b) append
	# the exhausted marker to THIS repo's ledger via the script-sibling
	# rate-budget.sh, (c) emit no mark-exhausted WARN. Pre-fix code in a
	# consumer without the .claude/scripts/cr mirror hit rc=127 + WARN
	# and wrote no marker.
	_stub_coderabbit '{"type":"error","errorType":"rate_limit","message":"Rate limit exceeded","recoverable":true}' 1
	cd "$TEST_TMP" || return 1
	PATH="$TEST_TMP/bin:$PATH" CR_LOCAL_REVIEW_TIMEOUT=0 run "$LR" --force --base main
	[ "$status" -eq 3 ]
	[[ $output == *"rate_limit"* ]]
	[[ $output != *"mark-exhausted failed"* ]]
	[ -f "$TEST_TMP/.claude/review-log/cr-budget.jsonl" ]
	grep -q 'exhausted' "$TEST_TMP/.claude/review-log/cr-budget.jsonl"
}
