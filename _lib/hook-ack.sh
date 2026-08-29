#!/bin/bash
set -u
# v4.28-W3-C — universal hook-output acknowledgment helper.
#
# Every hook (PreToolUse / PostToolUse / pre-commit / pre-push /
# SessionStart / UserPromptSubmit / Stop / PreCompact) that wants the
# operator to ACKNOWLEDGE its output sources this lib + calls
# `hook_ack_append <hook_name> <reason> [file_path]`.
#
# Sentinel file: .claude/.session-state/hook-output-pending.txt
# Format per line: <ts>\t<hook>\t<reason>\t<file_path-or-empty>
#
# Reading mechanism:
#   - PreToolUse Bash/Edit/Write/MultiEdit gates read the sentinel; if
#     non-empty, BLOCK with deny-JSON listing the un-acknowledged events.
#     (stale-state-gate.sh has matcher 'Bash|Edit|Write|MultiEdit').
#   - PostToolUse Read clears entries whose file_path matches the file
#     just Read (proves operator saw the actual content + hook context).
#   - Wholesale clear: HOOK_ACK_CLEAR=1 <cmd> (audit-logged bypass).

# v4.30.A #796: detect bats-test invocation. Bats sets BATS_TEST_NAME +
# BATS_RUN_TMPDIR for every test, and these env vars can only originate
# from a real `bats` ancestor process — they cannot leak into a normal
# Claude session. When detected, hooks SKIP the universal-sentinel
# write (which would pollute the operator's real-session ack queue with
# test side effects) while STILL emitting deny-JSON and writing the
# per-instance diagnostic file so bats tests can assert on the
# gate-fail behavior.
#
# Override: HOOK_ACK_BATS_SKIP=0 forces the non-skip path even under
# bats — used by hook-ack-dedup.bats tests that need to verify the
# sentinel-write behavior itself.
_hook_ack_in_bats_context() {
	[ "${HOOK_ACK_BATS_SKIP:-1}" = "1" ] || return 1
	# Both vars required to confirm bats — single-env-var match could
	# theoretically false-positive on a user shell that happened to
	# set BATS_TEST_NAME manually.
	[ -n "${BATS_TEST_NAME:-}" ] && [ -n "${BATS_RUN_TMPDIR:-}" ]
}

hook_ack_append() {
	# $1 = hook name (e.g. "lint-dispatch", "bats-gate")
	# $2 = reason (short, < 80 chars)
	# $3 = file path that the operator should Read to acknowledge (optional)
	#
	# v4.30.A #796: short-circuit when invoked from inside a bats test.
	# Per-instance diagnostic via hook_ack_diagnostic_write still fires
	# (tests can assert) — only the universal sentinel append is skipped.
	if _hook_ack_in_bats_context; then
		return 0
	fi
	#
	# v4.28-W5 #773 dedup: when an entry with the same (hook, reason)
	# tuple already exists in the sentinel, replace the old line in-place
	# rather than appending a duplicate. CR PR #790: file_path is
	# INTENTIONALLY EXCLUDED from the dedup key — the awk filter at
	# the dedup pass below matches only (hook, reason), so different
	# diagnostic file paths for the same gate-event collapse into ONE
	# sentinel entry with the newest file_path preserved.
	local hook=${1:-unknown}
	local reason=${2:-no-reason}
	local file=${3:-}
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	local sentinel="$repo_root/.claude/.session-state/hook-output-pending.txt"
	mkdir -p "$(dirname "$sentinel")" 2>/dev/null || {
		echo "hook_ack_append: cannot create sentinel dir" >&2
		return 1
	}
	# CR PR #790: serialize read-modify-write + append across concurrent
	# hook invocations. mkdir is atomic on POSIX; two simultaneous hooks
	# without the lock would race on the awk→mv dedup pass and could clobber
	# each other's pending entries. ~2s budget (200 × 10ms) before fail-loud.
	local lockdir="${sentinel}.lockdir"
	local _lock_tries=0
	while ! mkdir "$lockdir" 2>/dev/null; do
		_lock_tries=$((_lock_tries + 1))
		[ "$_lock_tries" -lt 200 ] || {
			echo "hook_ack_append: lock acquisition failed after 2s — another hook may be stuck holding $lockdir" >&2
			return 1
		}
		sleep 0.01
	done
	# CR PR #790 r2 MAJOR: avoid process-wide RETURN trap. The library
	# is sourced into hooks that may have their own RETURN traps; a
	# function-level RETURN trap here would clobber theirs. Use explicit
	# cleanup at each return path instead (clean exit + every error
	# branch below).
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	# Filter existing entries: drop any with matching (hook, reason). file_path
	# field is intentionally NOT matched — different timestamps point at
	# distinct diagnostic files, and dedup-by-(hook,reason) collapses the
	# common "same gate firing multiple times" pattern. The latest entry wins.
	if [ -s "$sentinel" ]; then
		local tmp
		tmp=$(mktemp -t hook-ack-dedup.XXXXXX) || {
			echo "hook_ack_append: mktemp failed" >&2
			rmdir "$lockdir" 2>/dev/null || true
			return 1
		}
		# awk: emit lines whose (hook, reason) tuple does NOT match the incoming pair.
		# Tab-separated fields: $1=ts, $2=hook, $3=reason, $4=file.
		# `if`, not `A && B || C`. The chained form runs the handler when A
		# succeeds and B fails AND when A fails — which happens to be the
		# intent here, since both are errors, but it reads as if-then-else
		# and is not one. Latent until this file was next staged, because
		# the lint only sees files in the commit.
		local _dedup_ok=1
		if awk -F'\t' -v h="$hook" -v r="$reason" '!($2 == h && $3 == r)' "$sentinel" >"$tmp"; then
			mv -f "$tmp" "$sentinel" || _dedup_ok=0
		else
			_dedup_ok=0
		fi
		if [ "$_dedup_ok" -eq 0 ]; then
			echo "hook_ack_append: dedup rewrite failed" >&2
			rm -f "$tmp"
			rmdir "$lockdir" 2>/dev/null || true
			return 1
		fi
	fi
	printf '%s\t%s\t%s\t%s\n' "$ts" "$hook" "$reason" "$file" \
		>>"$sentinel" || {
		echo "hook_ack_append: cannot write sentinel" >&2
		rmdir "$lockdir" 2>/dev/null || true
		return 1
	}
	rmdir "$lockdir" 2>/dev/null || true
}

# v4.28-W3-C r7 (Option E — per-ack diagnostic artifact). Writes a
# per-instance diagnostic file at a known location under
# .claude/.session-state/hook-ack/<hook>/ and emits the absolute path
# on stdout. Caller passes that path to hook_ack_append as file_path.
#
# Why: pre-push-pipeline-gate had a self-referential paradox where it
# wrote ack with file_path = review-log/<sha>.jsonl that DID NOT exist
# (because "log missing" was the failure mode). Read tool can't open
# missing files → PostToolUse Read never fires → entry deadlocks until
# HOOK_ACK_CLEAR=1 bypass. Per-ack diagnostic guarantees the file
# exists at write time + carries the diagnostic the operator needs.
#
# Args:
#   $1 = hook name (used as subdir)
#   $2 = reason (short, used as part of filename for legibility)
#   $3 = body (multi-line diagnostic + remediation hints)
# Stdout: absolute path of the diagnostic file written.
# Returns: 0 on success, 1 on write failure.
hook_ack_diagnostic_write() {
	local hook=${1:-unknown}
	local reason=${2:-no-reason}
	local body=${3:-}
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	# r8 PTA #5 (path traversal): sanitize $hook arg before using as
	# directory component. basename strips leading dirs; tr drops any
	# remaining path-separator/dot-dot chars. Reject empty result.
	local safe_hook
	safe_hook=$(printf '%s' "${hook##*/}" | tr -c '[:alnum:]_.-' '-')
	[ -n "$safe_hook" ] && [ "$safe_hook" != ".." ] && [ "$safe_hook" != "." ] || return 1
	local diag_dir="$repo_root/.claude/.session-state/hook-ack/$safe_hook"
	mkdir -p "$diag_dir" 2>/dev/null || {
		echo "hook_ack_diagnostic_write: cannot create $diag_dir" >&2
		return 1
	}
	# r8 PTA #7 (ts collision on rapid calls): seconds resolution let two
	# calls in the same second clobber each other (real path: dogfood-gate
	# loop over multiple drift targets). Append a 6-char random suffix so
	# rapid back-to-back calls produce distinct paths even at same ts.
	#
	# (#2641) THE SUFFIX NEVER WORKED. It was:
	#
	#     rand_suffix=$(... </dev/urandom | head -c 6) || rand_suffix="$$"
	#
	# `head -c 6` exits as soon as it has six bytes and SIGPIPEs `tr`. Under
	# `set -o pipefail` — which EVERY caller of this library sets — the
	# pipeline therefore reports failure and the fallback always fires. All
	# 511 diagnostics on disk at the time of this fix carried a `$$` suffix;
	# not one had a random one. And `$$` is the process id, stable across
	# subshells, so two calls in the same second from one process produced
	# the SAME path and clobbered each other — precisely the collision the
	# suffix was added to prevent, with the real trigger (a gate looping over
	# several targets) already named in the comment above.
	#
	# Verified: without pipefail the original returns a random string; with
	# it, always the pid. That is why this was invisible to a shell test run
	# by hand.
	#
	# No pipeline now, so there is no SIGPIPE to mis-report. `$RANDOM` is a
	# bash builtin present in 3.2, and two draws give 8 hex chars, trimmed to
	# 6. This is filename disambiguation, not cryptography.
	local ts rand_suffix
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	rand_suffix=$(printf '%04x%04x' "$RANDOM" "$RANDOM")
	rand_suffix=${rand_suffix:0:6}
	# Sanitize reason for use in filename: replace non-alnum with `-`,
	# truncate to 60 chars to prevent excessive filenames.
	local safe_reason
	safe_reason=$(printf '%s' "$reason" | tr -c '[:alnum:]_.-' '-' | cut -c1-60)
	local diag_path="$diag_dir/${ts}-${safe_reason}-${rand_suffix}.txt"
	{
		printf 'Hook:      %s\n' "$hook"
		printf 'Reason:    %s\n' "$reason"
		printf 'Timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '\n'
		printf '%s\n' "$body"
	} >"$diag_path" 2>/dev/null || {
		echo "hook_ack_diagnostic_write: cannot write $diag_path" >&2
		return 1
	}
	printf '%s\n' "$diag_path"
}
