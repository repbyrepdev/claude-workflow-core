#!/bin/bash
set -euo pipefail
# v4.23-I (#555): commit-time bats-gate with assertion-weakening detection.
# Absorbs v4.23-K (#557) scope.
#
# LAYER 1 (staged .sh files): refuse commit unless content has been
# exercised by matching bats within last 1h at current content hash.
#
# LAYER 2 (staged .bats files): refuse commit on net-negative assertion
# changes OR new `skip "..."` without a #NNN ref in the skip message.
#
# Bypass:
#   TEST_GATE_SKIP=1 TEST_GATE_SKIP_REASON="<text>" git commit ...
#     — full bypass, reason required, logged + counted
#   TEST_GATE_WEAKEN_OK=1 git commit ...
#     — allow assertion-weakening specifically (legit spec changes)
#   BATS_GATE_AUTORUN=0 git commit ... (v4.30.C #798)
#     — refuse on drift instead of auto-running scripts/test.sh inside
#       the gate. Default (=1) auto-runs missing test + accepts on pass.
#
# Both bypasses log to .claude/logs/test-gate-skip.jsonl.
# session-start-report surfaces >3/day routine use.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT" || exit 2

# v0.6.2 (#35): graceful no-op for consumers without bats infra.
# Detect by presence of .claude/tests/ OR scripts/test.sh. If neither
# exists, the gate doesn't apply — consumer hasn't adopted bats yet.
# Honor BATS_GATE_OPTIONAL=0 to force the gate even without infra (for
# operators who want the gate as a forcing function to set up bats).
if [ "${BATS_GATE_OPTIONAL:-1}" = "1" ]; then
	if [ ! -d "$REPO_ROOT/.claude/tests" ] && [ ! -x "$REPO_ROOT/scripts/test.sh" ]; then
		exit 0
	fi
fi

# v4.28-W3-C r5 (#676 expansion): every gate appends to the universal
# acknowledgment sentinel on FAIL so a single `cat hook-output-pending.txt`
# surfaces all blockers (bats + dogfood + lint + prove-yourself) in one
# place instead of per-gate jsonl walks.
LIB_HOOK_ACK="$(dirname "$0")/../_lib/hook-ack.sh"
# shellcheck source=../_lib/hook-ack.sh
[ -f "$LIB_HOOK_ACK" ] && source "$LIB_HOOK_ACK"
# v0.34.31 (#2235): consumer-aware canonical-skip — no-op in the plugin itself.
LIB_CCS="$(dirname "$0")/../_lib/canonical-consumer-skip.sh"
# shellcheck source=../_lib/canonical-consumer-skip.sh
[ -f "$LIB_CCS" ] && source "$LIB_CCS"
_bats_gate_ack() {
	command -v hook_ack_append >/dev/null 2>&1 &&
		hook_ack_append "bats-gate" "$1" "$2"
}

# Full-bypass path — log + allow.
if [ "${TEST_GATE_SKIP:-0}" = "1" ]; then
	reason="${TEST_GATE_SKIP_REASON:-}"
	if [ -z "$reason" ]; then
		echo 'bats-gate: TEST_GATE_SKIP=1 requires TEST_GATE_SKIP_REASON="<text>"' >&2
		exit 2
	fi
	SKIP_LOG="$REPO_ROOT/.claude/logs/test-gate-skip.jsonl"
	mkdir -p "$(dirname "$SKIP_LOG")" 2>/dev/null || true
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" \
		--arg kind "full-skip" \
		'{ts: $ts, kind: $kind, reason: $reason}' \
		>>"$SKIP_LOG" 2>/dev/null || true
	echo "bats-gate: TEST_GATE_SKIP=1 — bypassing (reason: $reason)" >&2
	exit 0
fi

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)
[ -z "$STAGED" ] && exit 0

BATS_LOG="$REPO_ROOT/.claude/logs/bats-run.jsonl"
GATE_SKIP_LOG="$REPO_ROOT/.claude/logs/test-gate-skip.jsonl"
FAIL=0

# ---------- LAYER 1: staged .sh gate ----------

check_sh_gate() {
	local sh=$1

	# v0.34.31 (#2235): canonical .sh in a consumer is validated upstream +
	# byte-identity-enforced by hash-drift — don't require a local bats pass.
	if command -v canonical_consumer_skip >/dev/null 2>&1 && canonical_consumer_skip "$sh"; then
		return 0
	fi

	# Opt-out: `# bats-required: 0` header. Scan the full file — a long
	# shebang/license block before the directive would hide it from the
	# prior `head -5` scan. grep -m1 short-circuits on the first match
	# so full-file scan has negligible cost on typical scripts.
	if git show ":$sh" 2>/dev/null | grep -m1 -qE '^#[[:space:]]*bats-required:[[:space:]]*0\b'; then
		return 0
	fi

	# Only gate scripts in scope (same dirs as --coverage counts)
	case "$sh" in
	.claude/scripts/* | .claude/hooks/* | .claude/skills/* | .claude/local-backups/* | scripts/*) ;;
	*)
		return 0
		;;
	esac

	# Find a .bats that `# covers:` this script. -print0/NUL-delimited
	# read so filenames containing newlines don't break the loop.
	local matching_bats=""
	while IFS= read -r -d '' b; do
		hdr=$(git show ":$b" 2>/dev/null | grep -m1 -E '^#[[:space:]]*covers:' | sed -E 's/^#[[:space:]]*covers:[[:space:]]*//' || true)
		for p in $hdr; do
			if [ "$p" = "$sh" ]; then
				matching_bats="$b"
				break 2
			fi
		done
	done < <(find .claude/tests -name "*.bats" -print0 2>/dev/null)

	if [ -z "$matching_bats" ]; then
		echo "bats-gate: $sh has no matching .bats (no 'covers: $sh' header)" >&2
		echo "  Write a bats file or mark this script '# bats-required: 0' with justification" >&2
		_bats_gate_ack "no-matching-bats" "$sh"
		FAIL=$((FAIL + 1))
		return
	fi

	# Compute current content hash from the STAGED blob, not working tree.
	# v4.30.B #802: semantic hash via shfmt -mn (comment + whitespace
	# stripped) so comment-only edits don't invalidate recent passes.
	# Falls back to byte-exact when shfmt is unavailable or rejects input.
	local hash=""
	if [ -r "$(dirname "$0")/../_lib/semantic-hash.sh" ]; then
		# shellcheck source=../_lib/semantic-hash.sh
		. "$(dirname "$0")/../_lib/semantic-hash.sh"
		# CR PR #803 r2 MAJOR: capture rc with `|| sem_rc=$?` per
		# AGENTS.md rule. Bare `hash=$(...)` under set -euo pipefail
		# exits the script when the function returns non-zero,
		# bypassing the documented byte-exact fallback below.
		local sem_rc=0
		hash=$(compute_semantic_hash_staged "$sh" 2>/dev/null) || sem_rc=$?
		[ "$sem_rc" -eq 0 ] || hash=""
	fi
	if [ -z "$hash" ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			hash=$(git show ":$sh" 2>/dev/null | sha256sum | awk '{print $1}')
		elif command -v shasum >/dev/null 2>&1; then
			hash=$(git show ":$sh" 2>/dev/null | shasum -a 256 | awk '{print $1}')
		fi
	fi
	[ -n "$hash" ] || {
		echo "bats-gate: cannot compute hash for $sh (no sha256sum/shasum)" >&2
		_bats_gate_ack "no-hash-tool" "$sh"
		FAIL=$((FAIL + 1))
		return
	}

	# Look for recent (< 1h) pass log with matching path+hash
	if [ ! -f "$BATS_LOG" ]; then
		# v4.30.C #798: auto-run on no-log path too (not just hash-drift).
		# Same accept/refuse pattern as below.
		if [ "${BATS_GATE_AUTORUN:-1}" = "1" ]; then
			echo "bats-gate: $sh edited but no bats log yet — auto-running scripts/test.sh $matching_bats" >&2
			if scripts/test.sh "$matching_bats" >&2; then
				echo "bats-gate: auto-run completed for $sh (log seeded)" >&2
				# CR PR #799 r3 MAJOR: defensively verify the log was
				# actually written. A stub or partial auto-run can exit 0
				# without seeding the log; falling through to jq under
				# set -euo pipefail would terminate the hook on jq's
				# read-of-missing-file rc, bypassing FAIL+=1 accounting.
				if [ ! -f "$BATS_LOG" ]; then
					echo "bats-gate: auto-run completed but did not write $BATS_LOG" >&2
					_bats_gate_ack "autorun-missing-log" "$sh"
					FAIL=$((FAIL + 1))
					return
				fi
				# Fall through to the hash-match check below; if scripts/
				# test.sh seeded a matching entry the next jq query passes.
			else
				echo "bats-gate: auto-run FAILED for $matching_bats — fix the failure above + retry" >&2
				_bats_gate_ack "autorun-failed" "$sh"
				FAIL=$((FAIL + 1))
				return
			fi
		else
			echo "bats-gate: $sh edited but .claude/logs/bats-run.jsonl doesn't exist yet" >&2
			echo "  Run: scripts/test.sh $matching_bats" >&2
			_bats_gate_ack "no-bats-log" "$sh"
			FAIL=$((FAIL + 1))
			return
		fi
	fi

	local now_s cutoff_s
	now_s=$(date -u +%s)
	cutoff_s=$((now_s - 3600))

	# jq filter: entries with matching path+hash, pass, AND ts > cutoff.
	# NOTE: jq precedence — `|` has LOWER precedence than `and`, so the
	# parens around `((...)|any(...))` are required. Without them the
	# filter parses as `(select(A and X)) | any(...)` which tries to
	# iterate a boolean and crashes with "Cannot iterate over boolean".
	local found
	found=$(jq -r --arg p "$sh" --arg h "$hash" --argjson cutoff "$cutoff_s" '
		select(
			.status == "pass" and
			((.tested_files // []) | any(.path == $p and .hash == $h))
		) |
		(.ts | fromdateiso8601? // 0) as $ts |
		select($ts > $cutoff) |
		.ts
	' "$BATS_LOG" 2>/dev/null | tail -1)

	if [ -z "$found" ]; then
		# v4.30.C #798: auto-run the missing test instead of refusing
		# the commit outright. Operator was about to run this manually
		# anyway; doing it inside the gate eliminates the round-trip.
		# Override: BATS_GATE_AUTORUN=0 keeps the old refuse-only path.
		if [ "${BATS_GATE_AUTORUN:-1}" = "1" ]; then
			echo "bats-gate: $sh content not verified — auto-running scripts/test.sh $matching_bats" >&2
			# scripts/test.sh writes to BATS_LOG on success; re-query
			# the same jq filter to confirm a fresh matching entry now
			# exists. Surface auto-run stderr if it fails.
			local autorun_err
			autorun_err=$(mktemp -t bats-gate-autorun.XXXXXX) || autorun_err=/dev/null
			if scripts/test.sh "$matching_bats" >&2 2>"$autorun_err"; then
				# Re-check; auto-run should have added a matching entry.
				now_s=$(date -u +%s)
				cutoff_s=$((now_s - 3600))
				found=$(jq -r --arg p "$sh" --arg h "$hash" --argjson cutoff "$cutoff_s" '
					select(
						.status == "pass" and
						((.tested_files // []) | any(.path == $p and .hash == $h))
					) |
					(.ts | fromdateiso8601? // 0) as $ts |
					select($ts > $cutoff) |
					.ts
				' "$BATS_LOG" 2>/dev/null | tail -1)
				[ "$autorun_err" != /dev/null ] && rm -f "$autorun_err"
				if [ -n "$found" ]; then
					echo "bats-gate: auto-run cleared the drift for $sh" >&2
					return
				fi
				echo "bats-gate: auto-run completed but no matching log entry for $sh — check $matching_bats covers it" >&2
			else
				[ "$autorun_err" != /dev/null ] && [ -s "$autorun_err" ] && head -c 400 "$autorun_err" >&2
				[ "$autorun_err" != /dev/null ] && rm -f "$autorun_err"
				echo "bats-gate: auto-run FAILED for $matching_bats — fix the failure above + retry" >&2
			fi
		fi
		echo "bats-gate: $sh content not verified by recent bats pass" >&2
		echo "  Run: scripts/test.sh $matching_bats" >&2
		_bats_gate_ack "stale-bats-pass" "$sh"
		FAIL=$((FAIL + 1))
		return
	fi
}

# ---------- LAYER 2: staged .bats gate ----------

check_bats_gate() {
	local b=$1
	local added_asserts removed_asserts added_skips_no_ref

	# v4.23-W (#592): file-level opt-out. A bats file that intentionally
	# contains `skip "..."` strings or heredoc assertions as FIXTURE
	# content (e.g., tests that exercise the bats-gate itself) can
	# declare `# bats-gate: fixture-file` in its header. When present,
	# layer-2 checks are relaxed — we still print a note so the opt-out
	# is visible in pre-commit output, but we don't refuse.
	if git show ":$b" 2>/dev/null | head -5 | grep -qE '^#[[:space:]]*bats-gate:[[:space:]]*fixture-file\b'; then
		echo "bats-gate: $b marked 'fixture-file' — skipping assertion/skip checks" >&2
		return
	fi

	# Count added/removed assertion lines. Bats tests commonly have
	# assertions inline inside `{ ... }` blocks, so the regex matches
	# `[ ` / `[[ ` / `run ` / `assert_` ANYWHERE on a diff line, not just
	# at line start. The `|| true` suffixes are required under pipefail
	# because grep returns non-zero on zero matches.
	added_asserts=$(git diff --cached -- "$b" 2>/dev/null |
		grep -v '^+++' | grep -cE '^\+.*([[:space:]]\[[[:space:]]|[[:space:]]\[\[[[:space:]]|[[:space:]]run[[:space:]]|[[:space:]]assert_|\{[[:space:]]*\[[[:space:]])' || true)
	removed_asserts=$(git diff --cached -- "$b" 2>/dev/null |
		grep -v '^---' | grep -cE '^-.*([[:space:]]\[[[:space:]]|[[:space:]]\[\[[[:space:]]|[[:space:]]run[[:space:]]|[[:space:]]assert_|\{[[:space:]]*\[[[:space:]])' || true)

	# Count added `skip "..."` OR `skip '...'` calls WITHOUT a #NNN ref in the message.
	added_skips_no_ref=$(git diff --cached -- "$b" 2>/dev/null |
		grep -E '^\+[[:space:]]*skip[[:space:]]+["\047]' |
		grep -vcE '#[0-9]+' || true)

	# Weakening bypass: allow net-negative asserts + unanchored skips.
	if [ "${TEST_GATE_WEAKEN_OK:-0}" = "1" ]; then
		if [ "$removed_asserts" -gt "$added_asserts" ] || [ "$added_skips_no_ref" -gt 0 ]; then
			mkdir -p "$(dirname "$GATE_SKIP_LOG")" 2>/dev/null || true
			jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg file "$b" \
				--arg kind "weaken-ok" \
				--argjson removed "$removed_asserts" --argjson added "$added_asserts" \
				--argjson skips "$added_skips_no_ref" \
				'{ts: $ts, kind: $kind, file: $file, removed_asserts: $removed, added_asserts: $added, added_skips_no_ref: $skips}' \
				>>"$GATE_SKIP_LOG" 2>/dev/null || true
			echo "bats-gate: TEST_GATE_WEAKEN_OK=1 — allowing weakening in $b" >&2
		fi
		return
	fi

	# Net-negative assertions: refuse
	if [ "$removed_asserts" -gt "$added_asserts" ]; then
		echo "bats-gate: $b removed more assertions ($removed_asserts) than it added ($added_asserts)" >&2
		echo "  Looks like a silent weakening. If the spec genuinely changed, set TEST_GATE_WEAKEN_OK=1" >&2
		_bats_gate_ack "assertion-weakening" "$b"
		FAIL=$((FAIL + 1))
	fi

	# Silent skips (no #NNN tracking)
	if [ "$added_skips_no_ref" -gt 0 ]; then
		echo "bats-gate: $b added $added_skips_no_ref skip(s) without a #NNN sub-issue reference" >&2
		echo '  Tracked skips look like: skip "pending #1234 — reason"' >&2
		echo "  Silent skips are regression rot. If genuinely necessary, set TEST_GATE_WEAKEN_OK=1" >&2
		_bats_gate_ack "untracked-skip" "$b"
		FAIL=$((FAIL + 1))
	fi
}

# ---------- Apply gates ----------

while IFS= read -r f; do
	[ -z "$f" ] && continue
	case "$f" in
	*.sh)
		check_sh_gate "$f"
		;;
	*.bats)
		check_bats_gate "$f"
		;;
	esac
done <<<"$STAGED"

if [ "$FAIL" -gt 0 ]; then
	echo "" >&2
	echo "bats-gate: $FAIL gate violation(s). Emergency bypass:" >&2
	echo '  TEST_GATE_SKIP=1 TEST_GATE_SKIP_REASON="<reason>" git commit ...' >&2
	exit 1
fi

exit 0
