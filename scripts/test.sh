#!/bin/bash
# bats-required: 0  # Self-referential: this IS the bats runner.
set -euo pipefail
# v4.19 (#517) + v4.23-H (#554): run bats test suite + emit per-file
# JSONL results to .claude/logs/bats-run.jsonl.
#
# Usage:
#   scripts/test.sh                         # run all tests, log results
#   scripts/test.sh <path>                  # run specific bats file or dir
#   scripts/test.sh --coverage              # summarize .sh vs .bats ratio
#   scripts/test.sh --no-log                # skip JSONL logging
#
# Log schema (one line per file, one run = N lines):
#   { ts, sha, file, passed, failed, status }
#     status ∈ { "pass", "fail", "error" }
#
# Prerequisites:
#   v4.23-I blocking enforcement (commit-gate) reads this log to verify
#   bats ran at HEAD for touched .sh. v4.23-J push-gate check #5 reads
#   this log to verify bats ran since last push.

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
# TEST_REPO_ROOT overrides REPO_ROOT for the bats regression suite, which
# exercises --coverage against fixture trees (missing roots, etc.) without
# recompiling the script. Production callers never set it. Distinguish
# 'set + empty' (refuse — caller probably had a failed $(mktemp ...) sub)
# from 'unset' (fall back silently — the production path).
if [ "${TEST_REPO_ROOT+set}" = "set" ]; then
	if [ -z "$TEST_REPO_ROOT" ]; then
		echo "ERROR: TEST_REPO_ROOT is set but empty — refusing to silently fall back" >&2
		exit 2
	fi
	if [ ! -d "$TEST_REPO_ROOT" ]; then
		echo "ERROR: TEST_REPO_ROOT='$TEST_REPO_ROOT' is not a directory" >&2
		exit 2
	fi
	echo "NOTE: TEST_REPO_ROOT override active (target=$TEST_REPO_ROOT)" >&2
	REPO_ROOT="$TEST_REPO_ROOT"
fi

if ! command -v bats >/dev/null 2>&1; then
	echo "ERROR: bats not installed. Install: brew install bats-core" >&2
	exit 2
fi

# --- harness trust gate (#2631 follow-up) --------------------------------
#
# bats reports a failed test through an ERR trap. On bash 3.2 — the 2007
# build macOS ships at /bin/bash and can never update, because bash 4.0
# relicensed to GPLv3 — a failing `[[ ]]` fires NEITHER that trap NOR
# `set -e`, so the script simply continues and the test PASSES. Demonstrate
# it in one line:
#
#   /bin/bash -c 'set -eET; trap "echo TRAP" ERR; [[ a == b ]]; echo REACHED'
#   → REACHED        (with bash 5: TRAP, and the script stops)
#
# Consequence: every `[[ ]]` assertion that is not a test's LAST command is
# a silent no-op. Measured at 749 across 96 files when this was found. A
# green run under 3.2 therefore proves only that the single-bracket `[ ]`
# assertions held — which is not what "green" is read to mean.
#
# `bats` is `#!/usr/bin/env bash`, so it runs under the FIRST bash on PATH.
# That is what we inspect — not this script's own interpreter, which may
# differ. Installing Homebrew's bash is the entire fix; /opt/homebrew/bin
# already precedes /bin, so nothing else has to change.
_harness_bash=$(command -v bash 2>/dev/null || echo /bin/bash)
_harness_major=$("$_harness_bash" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)
if [ "${_harness_major:-0}" -lt 4 ]; then
	_harness_ver=$("$_harness_bash" -c 'echo "$BASH_VERSION"' 2>/dev/null || echo unknown)
	if [ "${TEST_HARNESS_ALLOW_BASH32:-0}" = "1" ]; then
		echo "WARN: bats will run under $_harness_bash ($_harness_ver)." >&2
		echo '      Mid-test `[[ ]]` assertions CANNOT FAIL there — a green run' >&2
		echo '      only proves the single-bracket `[ ]` assertions held.' >&2
		echo "      Proceeding because TEST_HARNESS_ALLOW_BASH32=1 (audit-logged)." >&2
		mkdir -p "$REPO_ROOT/.claude/logs" 2>/dev/null || true
		printf '{"ts":"%s","kind":"bash32-harness-allowed","bash":"%s","version":"%s"}\n' \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_harness_bash" "$_harness_ver" \
			>>"$REPO_ROOT/.claude/logs/pipeline-skip.jsonl" 2>/dev/null || true
	else
		echo "ERROR: bats would run under $_harness_bash ($_harness_ver)." >&2
		echo "" >&2
		echo '  On bash 3.x a failing `[[ ]]` fires neither errexit nor the ERR' >&2
		echo '  trap, so any mid-test `[[ ]]` assertion silently passes. Results' >&2
		echo "  from this harness cannot be trusted, and refusing is cheaper than" >&2
		echo "  a green suite that proves less than it claims." >&2
		echo "" >&2
		echo "  Fix (one command — /opt/homebrew/bin already precedes /bin, so" >&2
		echo "  bats picks it up with no further change):" >&2
		echo "      brew install bash" >&2
		echo "" >&2
		echo "  Deliberate override (audit-logged):" >&2
		echo "      TEST_HARNESS_ALLOW_BASH32=1 scripts/test.sh ..." >&2
		exit 2
	fi
fi

LOG_FILE="${BATS_LOG:-$REPO_ROOT/.claude/logs/bats-run.jsonl}"
mkdir -p "$(dirname "$LOG_FILE")"

DO_LOG=1
TARGET=""
MODE="run"
BASELINE=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--no-log)
		DO_LOG=0
		shift
		;;
	--coverage)
		MODE="coverage"
		shift
		;;
	--baseline)
		# v4.23-V (#591): mark this run as a weekly-cron baseline. Each
		# JSONL entry gets `baseline: true` so push-time gate's 7-day
		# staleness fallback can accept these as trusted recent state.
		BASELINE=1
		shift
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	-*)
		echo "error: unknown flag '$1'" >&2
		exit 2
		;;
	*)
		[ -z "$TARGET" ] || {
			echo "error: only one target allowed" >&2
			exit 2
		}
		TARGET="$1"
		shift
		;;
	esac
done

cd "$REPO_ROOT" || exit 2

# --coverage: inventory mode, doesn't run tests.
if [ "$MODE" = "coverage" ]; then
	echo "=== bats coverage inventory ==="
	# v0.9.4 (#53): filter roots to those that exist first. `find` returns
	# rc=1 on any missing starting path; under `set -o pipefail` the
	# `find | wc -l` pipeline inherits that rc=1 and `set -e` aborts the
	# script. CR-CLI flagged this on #51 (plugin root ships no .claude/
	# scripts or .claude/hooks).
	_existing_sh_roots=()
	for r in .claude/scripts .claude/hooks .claude/skills .claude/local-backups scripts; do
		[ -d "$r" ] && _existing_sh_roots+=("$r")
	done
	if [ "${#_existing_sh_roots[@]}" -gt 0 ]; then
		sh_count=$(find "${_existing_sh_roots[@]}" -name "*.sh" | wc -l | tr -d ' ')
	else
		sh_count=0
	fi
	if [ -d .claude/tests ]; then
		bats_count=$(find .claude/tests -name "*.bats" | wc -l | tr -d ' ')
		# Scan bats files for explicit "# covers: <path>" declarations (SSOT).
		# Trailing `|| true` is belt-and-suspenders. The CURRENT pipeline
		# is already safe because `find ... -exec grep ... \;` (note: `\;`
		# semicolon form, one grep invocation per file) does NOT propagate
		# per-invocation rc to find's exit. Verified on BSD/macOS + GNU
		# findutils: `find . -exec false {} \;` returns rc=0. The guard
		# remains in case a future refactor swaps to `find -exec ... +`
		# (aggregated grep) or `find | xargs grep` / `find | grep`, where
		# grep's rc=1 on no-match WOULD propagate under set -o pipefail.
		COVERED_PATHS=$(find .claude/tests -name "*.bats" -exec grep -hE '^#[[:space:]]*covers:' {} \; | sed -E 's/^#[[:space:]]*covers:[[:space:]]*//' | tr ' ' '\n' | sort -u || true)
	else
		bats_count=0
		COVERED_PATHS=""
	fi
	echo "Shell scripts in scope: $sh_count"
	echo "Bats test files:        $bats_count"
	echo ""
	covered=0
	uncovered=0
	if [ "${#_existing_sh_roots[@]}" -gt 0 ]; then
		while IFS= read -r sh; do
			[ -z "$sh" ] && continue
			# Normalize to relative path matching covers: declarations
			if printf '%s\n' "$COVERED_PATHS" | grep -qxF "$sh"; then
				covered=$((covered + 1))
			else
				uncovered=$((uncovered + 1))
			fi
		done < <(find "${_existing_sh_roots[@]}" -name "*.sh")
	fi
	echo "Covered (referenced in some .bats): $covered"
	echo "Uncovered:                           $uncovered"
	if [ "$sh_count" -eq 0 ]; then
		echo "Coverage: N/A (no .sh files found)"
	else
		pct=$((covered * 100 / sh_count))
		echo "Coverage: ${pct}%"
	fi
	exit 0
fi

# Figure out which files to run.
TARGET_PATH="${TARGET:-.claude/tests/}"
if [ ! -e "$TARGET_PATH" ]; then
	echo "error: target '$TARGET_PATH' does not exist" >&2
	exit 2
fi

SHA=$(git rev-parse HEAD 2>/dev/null || echo "no-head")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# v4.23-H: per-file logging. We run bats once per file (not one big sweep)
# so each file's pass/fail is recorded distinctly. Slower for huge suites
# but this repo's suite is small enough that the overhead is negligible
# and per-file granularity is what v4.23-I blocking-enforcement needs.
#
# v4.23-H.2 (#v4.23-H.2): also record tested_files with content hashes.
# Lets the future enforcement gate (v4.23-I/J/K) skip re-runs when a
# touched .sh has the SAME content hash as a prior pass-logged run — so
# editing file A doesn't invalidate file B's prior test state. Source:
# `# covers: <path1> <path2>` header in the .bats file (explicit-only —
# basename-grep fallback was dropped to avoid false positives; see
# _tested_files_json comment).
# Hashing uses sha256sum (linux) / shasum -a 256 (macos).

_sha256() {
	local file=$1
	# v4.30.B #802: prefer semantic hash (shfmt -mn normalized) so the
	# read side (bats-gate) and write side (this) agree on what counts
	# as "same content". Falls back to byte-exact when shfmt is missing
	# or the file isn't recognized as shell.
	# CR PR #803 r2 MAJOR: use script-level $REPO_ROOT (BASH_SOURCE-
	# derived at line 21) instead of re-deriving via git rev-parse;
	# that handles installer/non-repo contexts correctly.
	local repo_root="$REPO_ROOT"
	# Probe consumer layout first (.claude/_lib/) then plugin layout (_lib/).
	# Consumers install the helper under .claude/_lib via bootstrap-repo.sh;
	# the plugin's own repo keeps it at top-level _lib/. Without this fallback
	# the plugin can't dogfood semantic-hash on its own files — scripts/test.sh
	# silently writes byte-hash entries that bats-gate (semantic-hash reader)
	# can't match.
	local sem_lib=""
	if [ -r "$repo_root/.claude/_lib/semantic-hash.sh" ]; then
		sem_lib="$repo_root/.claude/_lib/semantic-hash.sh"
	elif [ -r "$repo_root/_lib/semantic-hash.sh" ]; then
		sem_lib="$repo_root/_lib/semantic-hash.sh"
	fi
	if [ -n "$sem_lib" ]; then
		# shellcheck disable=SC1090  # path resolved at runtime per repo layout
		. "$sem_lib"
		# CR PR #803 r2 MAJOR: capture rc per AGENTS.md rule. Bare
		# `h=$(...)` under set -e exits before the byte-exact fallback
		# below can run.
		local h="" sem_rc=0
		h=$(compute_semantic_hash "$file" 2>/dev/null) || sem_rc=$?
		[ "$sem_rc" -eq 0 ] || h=""
		if [ -n "$h" ]; then
			printf '%s' "$h"
			return 0
		fi
	fi
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" 2>/dev/null | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
	else
		if [ -z "${SHA256_WARNED:-}" ]; then
			echo "WARNING: no sha256 tool found (sha256sum or shasum) — content hashing disabled" >&2
			export SHA256_WARNED=1
		fi
		echo ""
	fi
}

# Parse `# covers:` header directive from a bats file. Returns space-
# separated paths on stdout. Empty if none declared.
_covers_from_header() {
	local bats=$1
	grep -m1 -E '^#[[:space:]]*covers:' "$bats" 2>/dev/null |
		sed -E 's/^#[[:space:]]*covers:[[:space:]]*//'
}

# Build tested_files JSON array for a bats file. Each entry: {path, hash}.
# If the file under `path` doesn't exist or can't be hashed, the entry is
# skipped — don't fail the log write, but record the fact via empty array
# if no files hashable.
_tested_files_json() {
	local bats=$1
	local covers
	covers=$(_covers_from_header "$bats")
	# If no header, we don't infer — explicit-only avoids false positives
	# where a bats file happens to mention a .sh filename in a test string.
	if [ -z "$covers" ]; then
		echo "[]"
		return
	fi
	local entries="[]"
	# Split `covers` on whitespace into an array — safe even if a path
	# contained spaces (paths in this repo don't, but `for x in $var`
	# relies on default IFS which is brittle to shell-level setup).
	local -a paths
	# shellcheck disable=SC2206
	paths=($covers)
	for path in "${paths[@]}"; do
		# Resolve relative paths against REPO_ROOT.
		local abs="$REPO_ROOT/$path"
		[ -f "$abs" ] || continue
		local hash
		hash=$(_sha256 "$abs")
		[ -n "$hash" ] || continue
		entries=$(printf '%s' "$entries" |
			jq --arg p "$path" --arg h "$hash" '. + [{path: $p, hash: $h}]')
	done
	printf '%s\n' "$entries"
}

log_one() {
	local file=$1 rc=$2 passed=$3 failed=$4 status
	if [ "$rc" -eq 0 ]; then
		status="pass"
	elif [ "$rc" -eq 1 ]; then
		status="fail"
	else
		status="error"
	fi
	if [ "$DO_LOG" = "1" ]; then
		local tested_files
		tested_files=$(_tested_files_json "$file")
		jq -nc --arg ts "$TS" --arg sha "$SHA" --arg file "$file" \
			--argjson passed "$passed" --argjson failed "$failed" \
			--arg status "$status" --argjson tested_files "$tested_files" \
			--argjson baseline "$BASELINE" \
			'{ts: $ts, sha: $sha, file: $file, passed: $passed, failed: $failed, status: $status, tested_files: $tested_files, baseline: ($baseline == 1)}' \
			>>"$LOG_FILE"
		# v4.28-W3-C (#671): also record per-covered-file entries in the
		# unified content-hash cache so other reviewers (Phase 1, CR,
		# prove-yourself) can query "has this file passed bats lately?"
		# via the same primitives. Cache is best-effort; failures here
		# don't fail the bats run. Reviewer ID = "bats". On bats failure
		# we explicitly DON'T record (cache_record requires status=ok).
		# Skip silently when no covers header — the no-cache case for
		# untagged bats files is already exercised by tested_files=[].
		local cache_lib="$REPO_ROOT/.claude/_lib/content-hash-cache.sh"
		local covers
		# `|| true` defends against set -o pipefail tripping on the inner
		# grep|sed pipeline when no covers line is found (grep rc=1).
		covers=$(_covers_from_header "$file" || true)
		if [ "$status" = "pass" ] && [ -f "$cache_lib" ] && [ -n "$covers" ]; then
			# shellcheck source=/dev/null
			source "$cache_lib" 2>/dev/null || return 0
			# `for x in $covers` (unquoted) splits on whitespace without
			# triggering bash 3.2's "${arr[@]}" empty-array unbound error
			# under set -u. Paths with whitespace would break this, but
			# the bats `# covers:` header SSOT is already space-separated.
			# shellcheck disable=SC2086
			for path in $covers; do
				[ -f "$REPO_ROOT/$path" ] || continue
				cache_record "bats" "$path" ok 2>/dev/null || true
			done
		fi
	fi
}

if [ -f "$TARGET_PATH" ]; then
	FILES=("$TARGET_PATH")
else
	# Bash 3.2 (macOS default) has no `mapfile` — use a read-loop.
	# Observed 2026-04-22 during v4.23-L.2 dogfood: mapfile silently
	# broke test.sh on stock macOS. Replaced with portable form.
	FILES=()
	while IFS= read -r f; do FILES+=("$f"); done < <(find "$TARGET_PATH" -name "*.bats" 2>/dev/null | sort)
fi

[ "${#FILES[@]}" -gt 0 ] || {
	echo "error: no .bats files found under $TARGET_PATH" >&2
	exit 2
}

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_FILES=0
FAIL_FILES=0

for f in "${FILES[@]}"; do
	TOTAL_FILES=$((TOTAL_FILES + 1))
	rc=0
	out=$(bats --tap "$f" 2>&1) || rc=$?
	passed=$(printf '%s\n' "$out" | grep -cE '^ok ' || true)
	failed=$(printf '%s\n' "$out" | grep -cE '^not ok ' || true)
	TOTAL_PASS=$((TOTAL_PASS + passed))
	TOTAL_FAIL=$((TOTAL_FAIL + failed))
	[ "$rc" -ne 0 ] && FAIL_FILES=$((FAIL_FILES + 1))
	log_one "$f" "$rc" "$passed" "$failed"
	if [ "$rc" -eq 0 ]; then
		echo "✓ $f ($passed passed)"
	else
		echo "✗ $f ($failed failed, rc=$rc)"
		# v4.28-W3-C: include TAP `# ` diagnostic lines alongside `not ok`
		# so test-side `printf "..." >&2` debug output reaches the operator.
		# Without this, the TAP comments are captured into $out but never
		# printed, leaving failures opaque ("not ok 4 — and that's it").
		# v0.9.4 (#53): || true on the grep pipeline. grep returns rc=1
		# when no lines match; under set -euo pipefail that aborts the
		# whole script, truncating the summary. CR-CLI flagged this on #51.
		printf '%s\n' "$out" | grep -E '^(not ok |# )' | head -30 | sed 's/^/    /' || true
		# Record full failure block for the bottom-of-run summary so a
		# single `tail -N` captures everything.
		FAIL_DETAILS="${FAIL_DETAILS:-}✗ $f ($failed failed, rc=$rc)
$(printf '%s\n' "$out" | grep -E '^(not ok |# )' | head -30 | sed 's/^/    /' || true)

"
	fi
done

echo ""
echo "=== Summary ==="
echo "Files:  $TOTAL_FILES total, $FAIL_FILES with failures"
echo "Tests:  $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [ "$DO_LOG" = "1" ]; then
	echo "Log:    $LOG_FILE (+$TOTAL_FILES entries)"
fi

# v4.28-W3-C: bottom-of-run failure summary — duplicates per-file
# output but groups all failures at the end so `tail -50` captures
# the complete picture in one invocation.
if [ "$FAIL_FILES" -gt 0 ]; then
	echo ""
	echo "=== FAILURE DETAILS (recap) ==="
	printf '%s' "${FAIL_DETAILS:-}"
fi

# v4.28-W3-C: per-run summary log so the operator can `tail -1` to
# see the prior run's outcome without re-executing.
SUMMARY_LOG="$REPO_ROOT/.claude/logs/test-run-summary.jsonl"
mkdir -p "$(dirname "$SUMMARY_LOG")" 2>/dev/null || true
# `|| true` defends against pipefail tripping when FAIL_DETAILS is empty
# (grep returns 1 → set -o pipefail propagates → cmd-sub fails under set -e).
FAIL_FILES_LIST=$(printf '%s' "${FAIL_DETAILS:-}" | grep -E '^✗' | sed 's/✗ //' | awk '{print $1}' | jq -R . | jq -s . 2>/dev/null || echo "[]")
jq -nc \
	--arg ts "$TS" --arg sha "$SHA" \
	--argjson files "$TOTAL_FILES" \
	--argjson fail_files "$FAIL_FILES" \
	--argjson passed "$TOTAL_PASS" \
	--argjson failed "$TOTAL_FAIL" \
	--argjson fail_list "${FAIL_FILES_LIST:-[]}" \
	'{ts:$ts, sha:$sha, files:$files, fail_files:$fail_files, tests_passed:$passed, tests_failed:$failed, fail_list:$fail_list}' \
	>>"$SUMMARY_LOG" 2>/dev/null || true

[ "$FAIL_FILES" -eq 0 ] || exit 1
