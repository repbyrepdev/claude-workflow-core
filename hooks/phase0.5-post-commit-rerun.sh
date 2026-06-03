#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# v4.28-W3-C — auto-fire phase0.5-copilot-prefilter.sh after every
# `git commit` so the next round/CR-CLI/launcher invocation isn't
# blocked by phase0.5-before-phase1.sh / phase0.5-before-cr.sh demanding
# a Phase 0.5 log entry at the new HEAD sha.
#
# WHY: Phase 0.5 is logged per-SHA. Every commit changes HEAD → prior
# Phase 0.5 log no longer matches. Without auto-rerun, every fix-commit
# cycle requires the operator to remember to re-run phase0.5 manually
# before launching the next Phase 1 round. Observed mid-PR #635 (this
# Wave 1) when launcher round 3 was blocked after the r2 fix commit.
#
# PostToolUse Bash hook. Inspects the prior command + the tool_response
# exit_code, fires only on `git commit` SUCCESS (exit_code==0). r3
# comment-analyzer #1+#2: prior version claimed to fire only on
# success but didn't actually check exit_code — fixed.
# Best-effort — failures here don't block subsequent operations (the
# pre-Phase-1 gate will still block if prefilter genuinely couldn't
# run, surfacing the real error then).

# v4.28-W4 #851 r1 (#705 Phase 2): payload parsing + commit detection +
# exit_code gate extracted to .claude/_lib/post-commit-detect.sh.
# `post_commit_detect_init` exports PAYLOAD/CMD/EXIT_CODE on success;
# returns 1 to skip (non-commit, empty CMD, or failed commit). PostToolUse
# hooks are best-effort — propagate skip as exit 0.
# shellcheck source=../_lib/post-commit-detect.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/post-commit-detect.sh"
post_commit_detect_init || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
PREFILTER="$(dirname "$0")/phase0.5-copilot-prefilter.sh"
[ -x "$PREFILTER" ] || exit 0

HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || exit 0

# v4.29 #792 — branch-graduation short-circuit. Once a branch has graduated
# past Phase 0.5/1 (one clean Phase 1 round), further commits don't need to
# re-run the prefilter. Phase 2/3 cover whatever changed.
# CR Phase 2 MAJOR: don't swallow git rev-parse errors with || echo "";
# capture stderr + fail-closed so a broken repo state doesn't silently
# fall through to "treat as ungraduated" (which then runs the prefilter
# in an already-broken environment).
GRAD_LIB="$(dirname "$0")/../_lib/phase-graduation.sh"
if [ -r "$GRAD_LIB" ]; then
	if ! GRAD_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>&1); then
		echo "phase0.5-post-commit-rerun: graduation branch resolution failed: $GRAD_BRANCH" >&2
		exit 1
	fi
	if [ -n "$GRAD_BRANCH" ]; then
		# shellcheck source=/dev/null
		. "$GRAD_LIB"
		if graduation_check "$GRAD_BRANCH"; then
			exit 0
		fi
	fi
fi

# Idempotent: skip if Phase 0.5 already logged at this exact HEAD.
LOG="$REPO_ROOT/.claude/logs/phase0.5-run.jsonl"
if [ -f "$LOG" ] && jq -e --arg sha "$HEAD_SHA" \
	'select(.sha == $sha)' "$LOG" >/dev/null 2>&1; then
	exit 0
fi

# v4.28-W4 (#678): read base_ref from review-config.yml SSOT instead
# of hardcoding `main`. Falls back to "main" if review-config is missing
# or doesn't declare base_ref — preserving prior behavior for installs
# that haven't migrated to v4.28-W4 review-config yet.
REVIEW_CONFIG="$REPO_ROOT/.claude/review-config.yml"
BASE_REF="main"
if [ -f "$REVIEW_CONFIG" ] && command -v yq >/dev/null 2>&1; then
	cfg_base=$(yq -r '.base_ref // "main"' "$REVIEW_CONFIG" 2>/dev/null || echo "main")
	[ -n "$cfg_base" ] && [ "$cfg_base" != "null" ] && BASE_REF="$cfg_base"
fi

# v4.28-W5 (#788 follow-up) — content-aware short-circuit. When the
# new commit only touches audit/logs/memory/non-code files (no file
# matches any agent's required_extensions or required_paths), no
# Phase 0.5 agent has work to do. Write a synthetic carried-forward
# entry from PREV_SHA's most recent entries so the per-SHA gate
# accepts; skip the prefilter detach entirely. This is the routing
# decision that breaks the "every commit restarts Phase 0.5" loop.
ARF="$(dirname "$0")/agent-relevant-files.sh"
# Phase 1 r1 silent-failure-hunter: surface rev-parse failure (shallow
# clone / corrupt refs) so future debugging has signal. Defensive
# `|| true` keeps the hook from aborting the commit; capture err so
# operator sees the real cause if PREV_SHA ends up empty.
prev_rp_err=$(mktemp 2>/dev/null) || prev_rp_err=/dev/null
PREV_SHA=$(git -C "$REPO_ROOT" rev-parse "${HEAD_SHA}^" 2>"$prev_rp_err" || true)
if [ -z "$PREV_SHA" ] && [ "$prev_rp_err" != /dev/null ] && [ -s "$prev_rp_err" ]; then
	echo "phase0.5-post-commit-rerun: NOTE: rev-parse ${HEAD_SHA}^ failed (likely initial commit or shallow): $(head -c 200 "$prev_rp_err")" >&2
fi
[ "$prev_rp_err" != /dev/null ] && rm -f "$prev_rp_err"
if [ -x "$ARF" ] && [ -n "$PREV_SHA" ]; then
	# rc=1 = no agent-relevant files between prev and head → carry forward.
	# rc=2 = tooling broken (yq missing, config corrupt, bad ref). Capture
	# stderr so a regression in review-config.yml or yq doesn't silently
	# disable the content-aware optimization across the whole repo —
	# operator sees the real cause instead of running 25 phase-1 rounds
	# again (Phase 1 r1 silent-failure-hunter HIGH conf 9).
	# set -e + bare-command pattern aborts when ARF exits non-zero (which is
	# exactly the rc=1 carry-forward case). Use ||-rc-capture per
	# feedback_rc_capture_set_e.md memory.
	arf_err=$(mktemp 2>/dev/null) || arf_err=/dev/null
	arf_rc=0
	"$ARF" "$PREV_SHA" "$HEAD_SHA" >/dev/null 2>"$arf_err" || arf_rc=$?
	if [ "$arf_rc" -eq 2 ]; then
		stderr_snippet=""
		[ "$arf_err" != /dev/null ] && [ -s "$arf_err" ] && stderr_snippet=$(head -c 400 "$arf_err")
		echo "phase0.5-post-commit-rerun: WARN: CONTENT-AWARE GATE BROKEN — agent-relevant-files.sh rc=2: ${stderr_snippet:-<no stderr>}" >&2
		echo "  Content-aware short-circuit DISABLED for this commit; falling through to normal prefilter detach." >&2
	fi
	[ "$arf_err" != /dev/null ] && rm -f "$arf_err"
	if [ "$arf_rc" -eq 1 ]; then
		# Carry-forward Phase 0.5 entries from PREV_SHA → HEAD_SHA. Reuse
		# the prev-sha entries' (cli, agent) tuples; mark each with the
		# source sha for audit-traceability. If no prev entries exist
		# (first commit, log fresh), fall through to the normal detach.
		# Phase 1 r1 silent-failure-hunter MED (conf 8): capture jq stderr so
		# a malformed PREV_SHA log line (corruption / partial-write race)
		# surfaces instead of silently falling through.
		if [ -f "$LOG" ] && command -v jq >/dev/null 2>&1; then
			TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
			cf_jq_err=$(mktemp 2>/dev/null) || cf_jq_err=/dev/null
			CARRIED=$(jq -c --arg ps "$PREV_SHA" --arg hs "$HEAD_SHA" --arg ts "$TS" '
				select(.sha == $ps)
				| .sha = $hs
				| .ts = $ts
				| .carried_forward_from = $ps
			' "$LOG" 2>"$cf_jq_err") || {
				stderr_snippet=""
				[ "$cf_jq_err" != /dev/null ] && [ -s "$cf_jq_err" ] && stderr_snippet=$(head -c 200 "$cf_jq_err")
				echo "phase0.5-post-commit-rerun: WARN: jq carry-forward transform failed: ${stderr_snippet:-<no stderr>}" >&2
				CARRIED=""
			}
			[ "$cf_jq_err" != /dev/null ] && rm -f "$cf_jq_err"
			if [ -n "$CARRIED" ]; then
				printf '%s\n' "$CARRIED" >>"$LOG"
				echo "phase0.5-post-commit-rerun: content-aware carry-forward — no agent-relevant files between ${PREV_SHA:0:8}..${HEAD_SHA:0:8}; skipping prefilter detach" >&2
				exit 0
			fi
		fi
	fi
fi

# v4.28-W4 (#711-bundled): detach the prefilter so it can outlive the
# PostToolUse 15s hook timeout. Prior synchronous invocation timed out
# regularly mid-run, leaving phase0.5-run.jsonl with no entry for the
# new HEAD — every commit cycle then required a manual fire of the
# prefilter as gate-directed recovery. setsid+nohup mirrors pr-trigger.sh
# autofix-cycle background detach. Output goes to a per-SHA log so a
# failed run is debuggable.
LOG_DIR="$REPO_ROOT/.claude/logs"
# r1 SFH #4 fix: surface mkdir failure so operator knows the per-SHA
# detach log won't appear (a downstream phase1-before-cr.sh failure
# would otherwise look mysterious). Don't `|| true` — let the WARN
# reach stderr; redirect-side failure below is then explicable.
# r2 SFH fix: mkdir_err falls back to /dev/null when mktemp itself fails
# (TMPDIR full / unwriteable). Without this, an empty mkdir_err yields
# a `2>""` ambiguous-redirect — under set -e the script aborts before
# the WARN fires, defeating the SFH #4 capture in the very scenario
# most likely to hit (TMPDIR-full + LOG_DIR-unwriteable share an
# underlying disk).
mkdir_err=$(mktemp 2>/dev/null) || mkdir_err=/dev/null
if ! mkdir -p "$LOG_DIR" 2>"$mkdir_err"; then
	if [ "$mkdir_err" != /dev/null ]; then
		echo "phase0.5-post-commit-rerun: WARN: cannot create $LOG_DIR — detached prefilter output will be lost: $(head -c 200 "$mkdir_err")" >&2
	else
		echo "phase0.5-post-commit-rerun: WARN: cannot create $LOG_DIR (mktemp also failed; stderr unavailable)" >&2
	fi
fi
[ "$mkdir_err" != /dev/null ] && rm -f "$mkdir_err"
DETACH_LOG="$LOG_DIR/phase0.5-post-commit-rerun-${HEAD_SHA:0:8}.log"
# r1 SFH #5 fix: don't add `2>/dev/null` on the subshell — the inner
# `>"$DETACH_LOG" 2>&1` already captures the detached process's runtime
# output. Note: the `||` clause only fires on subshell-fork failure
# (fork EAGAIN at the parent shell level). Runtime errors INSIDE the
# subshell get captured to DETACH_LOG, not surfaced via this WARN —
# this includes race-window failures between the pre-checks (`[ -x
# "$PREFILTER" ]` at line 42, `command -v setsid` below) and exec
# (the file could be deleted/PATH could change in that window).
# Operator should tail DETACH_LOG when investigating phase0.5 misses.
# stdin MUST be /dev/null: the detached prefilter calls scripts/copilot/try-free.sh,
# whose `if [ ! -t 0 ]; then CONTEXT=$(cat); fi` blocks on an unbounded `cat` read
# until COPILOT_TIMEOUT_SEC fires (rc=124) when stdin is an open non-tty pipe with
# no data (the detached git-hook stdin). The prefilter passes its prompt as $1 and
# pipes NO context, so closing stdin here is correct + is the root-cause fix for the
# recurring phase0.5 prefilter timeouts (#223 CR-CLI).
if command -v setsid >/dev/null 2>&1; then
	(setsid nohup "$PREFILTER" --base "$BASE_REF" --sha "$HEAD_SHA" </dev/null >"$DETACH_LOG" 2>&1 &) ||
		echo "phase0.5-post-commit-rerun: WARN: failed to detach prefilter via setsid+nohup" >&2
else
	# setsid is GNU/coreutils only — fall back to plain nohup on systems
	# without it (rare but defensive).
	(nohup "$PREFILTER" --base "$BASE_REF" --sha "$HEAD_SHA" </dev/null >"$DETACH_LOG" 2>&1 &) ||
		echo "phase0.5-post-commit-rerun: WARN: failed to detach prefilter via nohup fallback" >&2
fi

exit 0
