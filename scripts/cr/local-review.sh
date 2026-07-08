#!/bin/bash
set -euo pipefail
# v4.21 (#520): run `coderabbit review` locally with pre-flight checks
# that the `/coderabbit:review` skill + raw CLI call don't enforce:
#
# 1. Budget preflight via rate-budget.sh --check — refuses if the prepaid
#    10/hr bucket is near-exhausted (CR Pro Plus, refill 6min/token).
#    Override with --limit on rate-budget.sh if seat tier changes.
# 2. Phase 1 convergence verification — confirms phase1-before-cr hook
#    won't block (≥5 rounds + 2 clean streak + all agents logged).
# 3. HEAD freshness check — warns if branch head doesn't match the CR
#    invocation's expected `-t committed` base (stale review = wasted
#    budget).
#
# Usage:
#   .claude/scripts/cr/local-review.sh [--base main] [--force]
#
# --force bypasses budget + convergence gates (emergency override).
# Logs invocation to the CR budget log via the existing cr-log-invocation hook.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

BASE="main"
FORCE=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		[ "$#" -ge 2 ] || scm_fail "--base requires a value"
		BASE="$2"
		shift 2
		;;
	--force)
		FORCE=1
		shift
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*) scm_fail "unknown arg: $1" ;;
	esac
done

# Gate 1: budget preflight. `--check` exits 1 when remaining ≤1.
# v4.28-W4 PR #755 r8: the rate-budget banner is informational and goes
# on stderr so local-review.sh's stdout stays a pure CR JSON stream.
# Without this, ship-pr-cycle's `_phase2_run_cr_cli` captures stdout and
# feeds it to `jq -rs '...'`, which dies with "Invalid numeric literal
# at line 1, column 11" because jq tries to parse the "CodeRabbit rate
# budget..." line as JSON.
if [ "$FORCE" = "0" ]; then
	if ! "$SCRIPT_DIR/rate-budget.sh" --check >&2; then
		scm_fail "CR budget near-exhausted (remaining ≤1 of 10/hour Pro Plus cap; refill 6min/token). --force to override or wait for earliest entry to age out."
	fi
fi

# Gate 2: Phase 1 convergence. We re-use the existing phase1-before-cr
# gate logic by running it in check-only mode via PHASE1_CHECK_ONLY=1.
# If the hook isn't present or the guard doesn't support that env, fall
# back to a direct review-log walk. For now: if the hook exists, run it;
# on exit 0 we're converged.
PHASE1_HOOK="$REPO_ROOT/.claude/hooks/phase1-before-cr.sh"
if [ "$FORCE" = "0" ] && [ -x "$PHASE1_HOOK" ]; then
	# v4.24-O2 (#612) FIX: hook correctly emits deny-JSON on stdout at
	# exit 0 (per v4.17.R PreToolUse contract). Prior `if ! … >/dev/null 2>&1`
	# only inspected rc, so deny-JSON at exit 0 was treated as PASS — two
	# PRs in a row (#611, current branch) reached CR CLI with zero Phase 1
	# rounds. Read stdout + match on permissionDecision="deny" + surface the
	# reason so the refusal is actionable.
	hook_out=$(printf '{"tool_input":{"command":"coderabbit review"}}' | "$PHASE1_HOOK" 2>&1 || true)
	if printf '%s' "$hook_out" | grep -q '"permissionDecision":"deny"'; then
		reason=$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || echo "")
		scm_fail "Phase 1 not convergent — ${reason:-see phase1-before-cr.sh}. --force to override."
	fi
fi

# v4.24-O2 (#612) — Phase 0.5 convergence check. Same pattern as Phase 1
# but against phase0.5-run.jsonl. Prevents jumping straight to CR CLI
# without the Copilot prefilter pass (free tokens, often catches easy
# wins before spending CR budget).
PHASE05_HOOK="$REPO_ROOT/.claude/hooks/phase0.5-before-cr.sh"
if [ "$FORCE" = "0" ] && [ -x "$PHASE05_HOOK" ]; then
	hook_out=$(printf '{"tool_input":{"command":"coderabbit review"}}' | "$PHASE05_HOOK" 2>&1 || true)
	if printf '%s' "$hook_out" | grep -q '"permissionDecision":"deny"'; then
		reason=$(printf '%s' "$hook_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || echo "")
		scm_fail "Phase 0.5 (Copilot prefilter) not run for current HEAD — ${reason:-run .claude/hooks/phase0.5-copilot-prefilter.sh first}. --force to override."
	fi
fi

# Gate 3: HEAD freshness — warn (not fail) if there are uncommitted changes
# that won't be in the CR review scope.
if ! git diff --quiet || ! git diff --cached --quiet; then
	scm_warn "uncommitted changes present — they won't be reviewed by 'coderabbit -t committed'"
fi

# Log the invocation to the CR budget log BEFORE running, so a mid-run
# kill still counts against budget (conservative; prevents budget-skirting
# via Ctrl-C).
LOG="$REPO_ROOT/.claude/review-log/cr-budget.jsonl"
mkdir -p "$(dirname "$LOG")"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ts_epoch "$(date +%s)" \
	--arg source local-review-sh --arg base "$BASE" \
	'{ts: $ts, ts_epoch: $ts_epoch, source: $source, base: $base}' >>"$LOG"

# v4.28-W4 PR #755 r8: banner to stderr — same reason as the budget
# banner above. local-review.sh's stdout contract is "JSON-stream only"
# so ship-pr-cycle's _phase2_run_cr_cli can `jq -rs` over it cleanly.
echo "=== Running coderabbit review --agent -t committed --base $BASE ===" >&2
# Preflight: fail loud if CLI missing (otherwise the `|| rc=$?` below
# captures bash's "command not found" 127 with no context).
command -v coderabbit >/dev/null 2>&1 || scm_fail "coderabbit CLI not installed — install via npm i -g @coderabbit/cli or equivalent"
# `|| rc=$?` form required under set -eo pipefail — bare `cmd; rc=$?`
# aborts on non-zero before the capture runs (the feedback_rc_capture_set_e
# memory applies). CR exits non-zero on findings, which is the common case
# this wrapper exists to log against budget; losing that log would defeat
# the purpose. Pre-init rc=0 for set -u safety.
#
# v4.24-Q2 (#609): tee the output to a temp file so we can extract the
# finding count from the trailing `{"type":"complete","findings":N}` line
# and include it in the jsonl log — without the count, phase1-scaler.sh
# can't differentiate "CR CLI converged clean" from "CR CLI never ran."
TEE_OUT=$(mktemp -t cr-local-review.XXXXXX)
trap 'rm -f "$TEE_OUT"' EXIT
# v0.32.x (#234): cap the local review's wall-time. CR's server-side review
# can run ~60min on a large diff before emitting an unrecoverable timeout
# event — wasted wall-clock for a PRE-PUSH convenience whose findings the
# authoritative server-side CR-in-CI re-derives on push anyway. A client-side
# timeout fails fast so ship-pr-cycle can defer to CR-in-CI (the exit-4 SSOT
# contract below). Default 600s (~3x observed clean-run duration); override via
# CR_LOCAL_REVIEW_TIMEOUT (0 disables). Prefer GNU `timeout`, fall back to
# coreutils `gtimeout` (macOS via brew); if neither is present, run un-wrapped
# and rely on CR's own server-side timeout event for the exit-4 signal.
CR_REVIEW_TIMEOUT="${CR_LOCAL_REVIEW_TIMEOUT:-600}"
[[ $CR_REVIEW_TIMEOUT =~ ^[0-9]+$ ]] || CR_REVIEW_TIMEOUT=600
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
# Capture the review command's exit via `rc=0; … || rc=$?`. Under the `set -o
# pipefail` on line 2, $? after a failed pipeline is its last non-zero exit —
# coderabbit's findings-exit (1), or the `timeout` SIGTERM code (124) on a
# client-side kill. The prior `… | tee … || true; rc=${PIPESTATUS[0]}` was
# BUGGY: `|| true` runs `true`, which resets PIPESTATUS to [0], so rc was
# always 0 on a failed pipeline — masking findings-exits AND the 124 timeout
# signal this feature relies on. `|| rc=$?` reads the pipeline exit directly.
rc=0
if [ "$CR_REVIEW_TIMEOUT" -gt 0 ] && [ -n "$TIMEOUT_BIN" ]; then
	"$TIMEOUT_BIN" "$CR_REVIEW_TIMEOUT" coderabbit review --agent -t committed --base "$BASE" 2>&1 | tee "$TEE_OUT" || rc=$?
else
	coderabbit review --agent -t committed --base "$BASE" 2>&1 | tee "$TEE_OUT" || rc=$?
fi

# #778: detect CR's server-side out-of-credits error and update the local
# rate-budget tracker. Without this, the local rolling-window count stays
# "OK" while CR refuses subsequent invocations — operators hit the wall
# mid-pipeline instead of at the budget gate. Pattern matches CR's literal
# error string from the issue repro ("ERROR: You've run out of usage
# credits.").
# code-reviewer Phase 1 r1: case-insensitive match guards against CR
# upstream text drift ("Out of usage credits" / "OUT OF..." variants).
# silent-failure-hunter Phase 1 r1 HIGH: surface mark-exhausted failures
# instead of swallowing via `|| true` + pipe — without this, the banner
# prints "marking budget exhausted" even when the marker actually failed
# to write, and the next invocation still says OK.
#
# v4.28-W5 #837: dual-path rate_limit detection — text grep catches CR's
# server-side "out of credits" error page; JSON path catches the CR CLI
# structured event `{"type":"error","errorType":"rate_limit",...}`. Local-
# review.sh is the SSOT for budget state updates (#830) — either signal
# triggers `rate-budget.sh mark-exhausted` exactly once per run via the
# `_rate_limit_handled` dedup flag.
_rate_limit_handled=0
if [ -f "$TEE_OUT" ] && grep -qE "ERROR:.*[Yy]ou'?ve run out of usage credits" "$TEE_OUT"; then
	echo "" >&2
	echo "local-review: CR rate_limit (text-detect: out-of-credits page) — marking budget exhausted" >&2
	if ! "$REPO_ROOT/.claude/scripts/cr/rate-budget.sh" mark-exhausted >&2; then
		echo "local-review: WARN: rate-budget mark-exhausted failed (text-path) — budget tracker drift will persist" >&2
	fi
	_rate_limit_handled=1
fi
# JSON event detection — CR CLI emits `{"type":"error","errorType":
# "rate_limit","recoverable":true,...}` on per-CLI rate-limit hit (separate
# from the server-side "out of credits" text page). Pre-filter to JSON-
# shaped lines (anchor on leading `{`) first since TEE_OUT contains stderr
# + banner noise that would break a bare `jq -rs` slurp.
if [ "$_rate_limit_handled" -eq 0 ] && [ -f "$TEE_OUT" ]; then
	rl_mktemp_err=$(mktemp -t local-review-rl-mkerr.XXXXXX 2>/dev/null) || rl_mktemp_err="/dev/null"
	rl_json_file=$(mktemp -t local-review-rl-json.XXXXXX 2>"$rl_mktemp_err") || rl_json_file=""
	if [ -z "$rl_json_file" ]; then
		if [ "$rl_mktemp_err" != "/dev/null" ] && [ -s "$rl_mktemp_err" ]; then
			echo "local-review: WARN: mktemp for JSON rate_limit detection failed: $(head -c 200 "$rl_mktemp_err") — JSON detection skipped (text-path still active)" >&2
		else
			echo "local-review: WARN: mktemp for JSON rate_limit detection failed — JSON detection skipped (text-path still active)" >&2
		fi
	fi
	[ "$rl_mktemp_err" != "/dev/null" ] && rm -f "$rl_mktemp_err"
	if [ -n "$rl_json_file" ]; then
		rl_grep_err=$(mktemp -t local-review-rl-gerr.XXXXXX 2>/dev/null) || rl_grep_err="/dev/null"
		grep_rc=0
		grep -E '^\{' "$TEE_OUT" >"$rl_json_file" 2>"$rl_grep_err" || grep_rc=$?
		if [ "$grep_rc" -gt 1 ]; then
			# grep rc>1 = real error (read failure, etc); rc=1 = no
			# match (legit empty). On rc>1 we WARN with captured stderr
			# (operator-visible) and skip JSON detection — text-path
			# already ran above and remains authoritative. This is
			# WARN-and-continue not fail-loud: blocking the whole
			# review on a grep error would lose all detection signal.
			if [ "$rl_grep_err" != "/dev/null" ] && [ -s "$rl_grep_err" ]; then
				echo "local-review: WARN: JSON-line grep failed (rc=$grep_rc): $(head -c 200 "$rl_grep_err") — JSON rate_limit detection skipped" >&2
			else
				echo "local-review: WARN: JSON-line grep failed (rc=$grep_rc) — JSON rate_limit detection skipped" >&2
			fi
			# CR PR #860 belt-and-suspenders: explicit cleanup here too
			# (also runs at the converging cleanup below, but CR's auto-
			# resolve heuristic prefers seeing rm-f inside both branches).
			[ "$rl_grep_err" != "/dev/null" ] && rm -f "$rl_grep_err"
			rm -f "$rl_json_file"
		else
			rl_jq_err=$(mktemp -t local-review-rl-jerr.XXXXXX 2>/dev/null) || rl_jq_err="/dev/null"
			rl_jq_rc=0
			rl_count=$(jq -rs 'map(select(.type == "error" and .errorType == "rate_limit")) | length' "$rl_json_file" 2>"$rl_jq_err") || rl_jq_rc=$?
			if [ "$rl_jq_rc" -ne 0 ]; then
				# jq failed (parse error, binary missing, OOM). Surface
				# the error — silent swallow would mask a real rate_limit
				# signal and miss the exit-3 contract ship-pr-cycle reads.
				if [ "$rl_jq_err" != "/dev/null" ] && [ -s "$rl_jq_err" ]; then
					echo "local-review: WARN: JSON rate_limit jq failed (rc=$rl_jq_rc): $(head -c 200 "$rl_jq_err") — JSON detection skipped (text-path still authoritative)" >&2
				else
					echo "local-review: WARN: JSON rate_limit jq failed (rc=$rl_jq_rc) — JSON detection skipped (text-path still authoritative)" >&2
				fi
				rl_count=""
			fi
			[ "$rl_jq_err" != "/dev/null" ] && rm -f "$rl_jq_err"
			if [ -n "${rl_count:-}" ] && [ "$rl_count" != "0" ]; then
				echo "" >&2
				echo "local-review: CR rate_limit (json-detect: ${rl_count} event(s)) — marking budget exhausted" >&2
				if ! "$REPO_ROOT/.claude/scripts/cr/rate-budget.sh" mark-exhausted >&2; then
					echo "local-review: WARN: rate-budget mark-exhausted failed (json-path) — budget tracker drift will persist" >&2
				fi
				_rate_limit_handled=1
			fi
		fi
		# Cleanup runs unconditionally after EITHER branch (grep_rc>1 WARN
		# or jq-success): the if-else above only differs in how it
		# processes $rl_json_file, both fall through here for cleanup.
		[ "$rl_grep_err" != "/dev/null" ] && rm -f "$rl_grep_err"
		rm -f "$rl_json_file"
	fi
fi

# v4.28-W5 #836 CR-CLI Major: exit 3 IMMEDIATELY on rate_limit detection.
# Prior placement at script end ran findings parsing + scm_log + review-log
# write + cache_record under `set -e` BEFORE the exit — any failure in
# those would abort with rc=1 instead of rc=3, masking the SSOT contract
# ship-pr-cycle reads. Detection is the load-bearing signal; the
# downstream best-effort work is skipped entirely on the rate_limit path.
if [ "$_rate_limit_handled" -eq 1 ]; then
	exit 3
fi

# v0.32.x (#234): timeout detection → exit 4 (SSOT contract, sibling to the
# rate_limit exit-3 above). Either the client-side `timeout` killed CR
# (rc=124 SIGTERM / 137 SIGKILL) OR CR emitted its own server-side
# `{"type":"error","errorType":"timeout"}` event (recoverable:false). Both mean
# the local review could not complete — a transient CR-backend limit on a large
# diff, NOT a code defect. ship-pr-cycle's _phase2_run_cr_cli treats exit 4 as
# "defer to the authoritative server-side CR-in-CI" (which re-reviews on push),
# distinct from a hard failure (auth/malformed) or a findings count. Log the
# attempt first (audit + round visibility), then exit 4.
_timeout_detected=0
if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
	_timeout_detected=1
elif [ -f "$TEE_OUT" ] && grep -qE '"errorType"[[:space:]]*:[[:space:]]*"timeout"' "$TEE_OUT"; then
	_timeout_detected=1
fi
if [ "$_timeout_detected" -eq 1 ]; then
	echo "" >&2
	echo "local-review: CR review timed out (rc=$rc) — local review incomplete; deferring to authoritative server-side CR-in-CI (exit 4)" >&2
	scm_log cr-local-review "$(jq -nc --arg base "$BASE" --argjson force "$FORCE" \
		--argjson rc "$rc" --argjson findings 0 --argjson timeout true \
		'{base: $base, force: $force, rc: $rc, findings: $findings, timeout: $timeout}')" || true
	exit 4
fi

# v0.34.36 (#2249): phase2 hash-filter. Count CR-CLI findings EXCLUDING those on
# canonical-mirror files (byte-identical to the pinned canonical → already
# reviewed upstream + hash-drift-enforced → the verbatim treadmill). This is the
# PRECISE local exclusion the coarse .coderabbit globs cannot express for MIXED
# dirs like .claude/hooks/ (a glob can't tell a mirror from a consumer-authored
# file). Fail-safe: predicate unavailable → nothing excluded → full count. Also
# avoids the CR-CLI complete-event over-count by tallying finding LINES.
_CRE_LIB="$(dirname "${BASH_SOURCE[0]}")/../../_lib/canonical-review-exclude.sh"
if [ -r "$_CRE_LIB" ]; then
	# shellcheck source=../../_lib/canonical-review-exclude.sh
	. "$_CRE_LIB" || true
fi
if command -v canonical_review_filtered_finding_count >/dev/null 2>&1; then
	findings=$(canonical_review_filtered_finding_count "$TEE_OUT")
else
	# Fallback (lib unavailable): prior behavior — complete event, then grep.
	findings=$(jq -rs 'map(select(.type=="complete")) | if length > 0 then .[-1].findings else empty end' <"$TEE_OUT" 2>/dev/null || true)
	[ -n "${findings:-}" ] || findings=$(grep -cE '"type"[[:space:]]*:[[:space:]]*"finding"' "$TEE_OUT" 2>/dev/null || echo 0)
fi
[[ $findings =~ ^[0-9]+$ ]] || findings=0

# #2484: persist the review detail BEFORE the tee tmpfile is trap-removed.
# The orchestrator's bg wrapper truncates stdout to a tail and the tmpfile
# evaporates with the process, so findings>0 repeatedly became "count with
# no detail" (6 occurrences on 2026-07-07/08) — forcing budget-burning
# re-runs or blind converge-rejections. Keep the full JSONL per sha; loud
# WARN (not fatal) if the copy fails.
if [ "$findings" -gt 0 ] && [ -f "$TEE_OUT" ]; then
	# Bare --short (NOT --short=7): scm_log keys its jsonl line on bare
	# --short (auto-abbrev), and consumers reconstruct this path from that
	# sha — the two derivations must stay byte-identical at any repo size.
	_detail_sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
	_detail_dir="$REPO_ROOT/.claude/logs"
	_detail_file="$_detail_dir/cr-local-review-${_detail_sha}-detail.jsonl"
	# Atomic write (temp in the SAME dir + mv): a mid-write failure must
	# never leave a TRUNCATED detail file at the advertised path (or destroy
	# a prior complete one) — partial detail parsed as truth is worse than
	# the missing-detail problem this block fixes. Stderr is captured so the
	# WARN states the actual cause.
	_detail_err=""
	if _detail_err=$(
		mkdir -p "$_detail_dir" &&
			_dtmp=$(mktemp "$_detail_dir/.cr-detail.XXXXXX") &&
			cp "$TEE_OUT" "$_dtmp" &&
			mv -f "$_dtmp" "$_detail_file" 2>&1
	); then
		echo "local-review: findings detail persisted to $_detail_file (#2484)" >&2
	else
		rm -f "$_detail_dir"/.cr-detail.?????? 2>/dev/null || true
		echo "local-review: WARN — could not persist findings detail to $_detail_file (${_detail_err:-no stderr}); the tee tmpfile dies with this process (#2484)" >&2
	fi
fi

# scm_log injects `sha` (bare --short HEAD, auto-abbrev) into the log line — that's the
# key the pre-push gate matches against. This fields object provides the
# NEW fields: base/force/rc (pre-existing) + findings (v4.24-Q2 #609 addition).
scm_log cr-local-review "$(jq -nc --arg base "$BASE" \
	--argjson force "$FORCE" --argjson rc "$rc" --argjson findings "$findings" \
	'{base: $base, force: $force, rc: $rc, findings: $findings}')"

# v4.28-W3-C (#673): also fire review-log.sh phase2 so the SHA-keyed
# review log records Phase 2 ran. Pre-push-pipeline-gate walks this log
# to verify Phase 2 fired before allowing push. Without this auto-log,
# operators had to remember to run `review-log.sh phase2 N <status>`
# manually after every CR-CLI invocation.
REVIEW_LOG="$REPO_ROOT/.claude/hooks/review-log.sh"
if [ -x "$REVIEW_LOG" ]; then
	phase2_status="errored"
	if [ "$rc" = "0" ] && [ "$findings" = "0" ]; then
		phase2_status="clean"
	elif [ "$rc" = "0" ] || [ "$rc" = "1" ]; then
		# CR exits 1 on findings; both 0 and 1 mean "ran cleanly, here's
		# the count". Higher rcs are tooling errors EXCEPT rc=3 which
		# this script reserves as the rate_limit signal (#838). This
		# block is unreachable on rate_limit because the exit-3
		# short-circuit fires earlier (above, right after detection)
		# to keep `set -e` failures from masking the SSOT contract.
		phase2_status="ok"
	fi
	# r5 SFH #2: surface review-log write failures (don't swallow). Earlier
	# 2>/dev/null hid jq/disk/permission errors; pre-push-pipeline-gate
	# would later refuse with "Phase 2 not logged" — operator has no idea
	# the actual cause was a write-failure here.
	# Note: under `set -e` only `cmd || rc=$?` reliably captures the rc;
	# `cmd; rc=$?` would abort and `if ! cmd` returns 0 (per AGENTS.md).
	review_log_rc=0
	"$REVIEW_LOG" phase2 "$findings" "$phase2_status" || review_log_rc=$?
	if [ "$review_log_rc" -ne 0 ]; then
		echo "local-review: WARN: review-log.sh phase2 write failed (rc=$review_log_rc)" >&2
		echo "  pre-push-pipeline-gate will refuse push until this entry exists." >&2
		echo "  Re-run manually: $REVIEW_LOG phase2 $findings $phase2_status" >&2
	fi
fi

# v4.28-W3-C (#671): record per-file cache entries when CR returned 0
# findings. Reviewer ID = "cr-cli". Future CR invocations + the prove-
# yourself audit can query "did CR find anything in this file at this
# blob-sha?" via the same primitives Phase 1 + bats use. Cache is best-
# effort; failures don't fail the review.
CACHE_LIB="$(dirname "${BASH_SOURCE[0]}")/../../_lib/content-hash-cache.sh"
if [ "$findings" = "0" ] && [ "$rc" = "0" ] && [ -f "$CACHE_LIB" ]; then
	# shellcheck source=/dev/null
	source "$CACHE_LIB"
	# Files mirroring the CR-CLI invocation's `-t committed --base $BASE`
	# scope (BASE..HEAD). The git-diff below reproduces that file set so
	# we record a cache row per file CR actually reviewed.
	# r1 follow-up SFH HIGH: prior triple-silencing (git stderr +
	# cache_record stderr + ||true rc-mask) hid all cache breakage.
	# Capture per-record failures + emit a single summary line so cache
	# corruption surfaces without breaking the best-effort contract.
	cache_diag=$(mktemp)
	cache_files=$(mktemp)
	cache_fail=0
	if git_err=$(git diff --name-only "${BASE}..HEAD" 2>&1 1>"$cache_files"); then
		while IFS= read -r f; do
			[ -z "$f" ] && continue
			[ -f "$REPO_ROOT/$f" ] || continue
			if ! cache_record "cr-cli" "$f" ok 2>>"$cache_diag"; then
				cache_fail=$((cache_fail + 1))
			fi
		done <"$cache_files"
		if [ "$cache_fail" -gt 0 ]; then
			echo "local-review: WARN: $cache_fail cache_record write(s) failed (see $cache_diag)" >&2
			# r3 CR fix #5: $cache_files has no diag value after the loop;
			# always clean it up. Only $cache_diag is preserved on failure.
			rm -f "$cache_files"
		else
			rm -f "$cache_diag" "$cache_files"
		fi
	else
		echo "local-review: WARN: git diff for cache scope failed: $git_err" >&2
		rm -f "$cache_diag" "$cache_files"
	fi
fi

# v4.28-W5 #838: rate_limit exit-3 fired earlier (right after detection
# block above) to ensure `set -e` failures in the intermediate findings/
# scm_log/review-log/cache code can't mask the SSOT contract. Reaching
# this line means _rate_limit_handled=0 (clean or non-rate_limit failure).
exit "$rc"
