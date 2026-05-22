#!/bin/bash
set -euo pipefail
# event: PreCompact
# Strict mode + per-call defense. PreCompact is non-blocking advisory — same
# contract as renovate-post-merge-deploy.sh. We previously used `set -u` only
# because grep-no-match / jq-parse-failure / transient stat failures would
# otherwise abort the snapshot mid-way. Now risky calls are individually
# defended where pipefail propagation matters (git pipe wrapped with `|| true`,
# `wc -l` pipe with `|| echo 0`); calls protected by `if`/`[ -f ]` guards rely
# on the guard rather than redundant `|| true`. Either way the exit-0 contract
# is preserved. Existing bats tests (#10/#26/#27 of v4.26) lock that invariant.
# PreCompact hook — flush meta-learning signals before Claude Code compacts
# the session context. Without this, long sessions lose correction/positive
# signal correlation when summarized away.
#
# Part of v3.19 meta-learning infrastructure (#237).

# Telemetry: log hook run at exit (from _lib.sh)
_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

LOG_FILE=".claude/session-log.jsonl"
ARCHIVE_DIR=".claude/session-log-archive"
SNAPSHOT_DIR=".claude/compact-snapshots"
DRAFT_DIR=".claude/retro-drafts"
SESSION_STATE_DIR=".claude/.session-state"

mkdir -p "$ARCHIVE_DIR" "$SNAPSHOT_DIR" "$DRAFT_DIR"

ts=$(date -u +%Y-%m-%dT%H%M%S)
input=$(cat 2>/dev/null || echo '{}')
# `|| true`: line above defaults $input to '{}' when stdin is missing, BUT a
# non-empty malformed payload (not '{}') would make jq fail. Under set -euo
# pipefail, that aborts the hook BEFORE archiving the session log + writing
# the snapshot — defeating the whole pre-compact archive flow.
session_id=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -z "$session_id" ] && session_id="${CLAUDE_SESSION_ID:-$$}"

# 1. Archive the current session log if present (do NOT truncate — /retro
#    may still be reading it post-compact). Copy-and-timestamp.
archive_written=false
if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
	cp "$LOG_FILE" "$ARCHIVE_DIR/${session_id}-pre-compact-${ts}.jsonl"
	archive_written=true
fi

# 2. Snapshot env context to a markdown file for post-compact reference
snap="$SNAPSHOT_DIR/${session_id}-${ts}.md"
{
	echo "# Pre-compact snapshot — $ts"
	echo ""
	echo "**Session:** $session_id"
	echo "**Reason:** $(echo "$input" | jq -r '.reason // .compact_reason // "unknown"' 2>/dev/null || echo "unknown")"
	echo ""
	echo "## Git state"
	echo '```'
	git branch --show-current 2>/dev/null || true
	git log --oneline -3 2>/dev/null || true
	{ git status --short 2>/dev/null || true; } | head -10
	echo '```'
	echo ""
	echo "## Recent signals (last 20)"
	echo '```jsonl'
	[ -f "$LOG_FILE" ] && tail -20 "$LOG_FILE"
	echo '```'
	# v4.26 (#626): also include in-flight session state so the post-compact
	# session can re-orient on PR/branch/last-cmd without re-deriving from gh.
	if [ -d "$SESSION_STATE_DIR" ] && [ -n "$(ls -A "$SESSION_STATE_DIR" 2>/dev/null)" ]; then
		echo ""
		echo "## In-flight session state (#626)"
		for f in current-pr.txt last-tool-cmd.txt; do
			if [ -f "$SESSION_STATE_DIR/$f" ]; then
				echo ""
				echo "### $f"
				echo '```'
				head -20 "$SESSION_STATE_DIR/$f"
				echo '```'
			fi
		done
		if [ -f "$SESSION_STATE_DIR/cr-round-state.jsonl" ]; then
			echo ""
			echo "### cr-round-state.jsonl (last 10)"
			echo '```jsonl'
			tail -10 "$SESSION_STATE_DIR/cr-round-state.jsonl"
			echo '```'
		fi
	fi
} >"$snap" 2>/dev/null

# 2b. v4.26 (#626): also tarball the session-state dir alongside the markdown
# snapshot. The .session-state/ dir itself stays in place — the next session's
# restore-session-state.sh reads it directly and never touches the tarball.
# This frozen .tar.gz is purely a forensics + manual-restore artifact.
if [ -d "$SESSION_STATE_DIR" ] && [ -n "$(ls -A "$SESSION_STATE_DIR" 2>/dev/null)" ]; then
	tar -czf "$SNAPSHOT_DIR/${session_id}-${ts}-session-state.tar.gz" \
		-C "$(dirname "$SESSION_STATE_DIR")" \
		"$(basename "$SESSION_STATE_DIR")" 2>/dev/null || true
fi

# 3. Emit a summary Claude can see post-compact.
# Pass LOG_FILE as `wc -l <FILE>` argument (not `<"$LOG_FILE"` redirect) so
# wc's own stderr is suppressed by `2>/dev/null` — input redirection lets
# the SHELL print "No such file or directory" before wc even runs.
signal_count=$(wc -l "$LOG_FILE" 2>/dev/null | awk '{print $1}' | tr -d ' ' || echo 0)
signal_count="${signal_count:-0}"
state_note=""
# Reuse the SSOT KV reader (_lib.sh) — same parser as persist + restore.
pr_snap=$(session_state_read pr "$SESSION_STATE_DIR")
[ -n "$pr_snap" ] && state_note=" Session-state captured for PR=#$pr_snap."
if [ "$archive_written" = true ]; then
	summary="📦 Pre-compact flush: $signal_count signals archived to ${ARCHIVE_DIR}/${session_id}-pre-compact-${ts}.jsonl. Snapshot: $snap.${state_note} Run /retro to analyze."
else
	summary="📦 Pre-compact flush: no active session log to archive. Snapshot: $snap.${state_note}"
fi

# r5-followup: PreCompact specifically lacks a valid `hookSpecificOutput`
# shape in the harness schema (the documented shapes cover PreToolUse /
# UserPromptSubmit / PostToolUse / PostToolBatch — Stop and SessionStart
# also accept hookSpecificOutput.additionalContext but PreCompact does
# not). Prior `{hookSpecificOutput: {hookEventName: "PreCompact",
# additionalContext: ...}}` was rejected with "Hook JSON output validation
# failed" — side-effects (snapshot + archive + .session-state writes)
# succeeded but the cross-session breadcrumb was lost. Use top-level
# `systemMessage` (valid for any event) for current-turn operator
# visibility; next-session continuity flows via SessionStart →
# restore-session-state.sh which reads .claude/.session-state/ + the
# snapshot from disk. Single source of truth: disk.
jq -nc --arg msg "$summary" '{systemMessage: $msg}'

exit 0
