#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# enforcement: inform — state persistence infrastructure, no verdicts
# v4.26 (#626) — PostToolUse hook: persist mid-PR state for compaction resilience.
#
# Maintains .claude/.session-state/ (gitignored) so a post-compact session can
# re-orient instantly instead of re-deriving "which PR / which round / what
# was I doing" from gh + review-log + scrollback.
#
# Files written:
#   current-pr.txt       — PR # tied to the current branch (latest gh observation)
#   last-tool-cmd.txt    — last meaningful Bash command (gh/git/cr/test/bats)
#   cr-round-state.jsonl — append-only {ts, pr, branch, cmd} snapshots
#
# Drift guard: bats `persist-session-state.bats`. New behavior in this hook
# (added matched commands, new state files, etc.) needs corresponding test
# cases — the `# covers:` header lists this script path, not file types.
#
# Registration: this is a USER-SCOPE PostToolUse hook — Claude Code only
# loads PreToolUse/PostToolUse handlers from `~/.claude/settings.json`, not
# project-scope `.claude/settings.json`. Run
# `.claude/hooks/install-session-state-hook.sh` once on a fresh clone to wire
# this script into your user settings.

_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$REPO_ROOT/.claude/.session-state"
mkdir -p "$STATE_DIR"

PAYLOAD=$(cat 2>/dev/null || echo '{}')
# Malformed JSON → empty TOOL/CMD → bail. Hook MUST NOT crash on bad payloads
# because it fires on every Bash tool call.
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || true)
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

# Only act on Bash calls — Edit/Write don't carry routing info we care about
# for "where am I in the workflow".
[ "$TOOL" = "Bash" ] || exit 0
[ -n "$CMD" ] || exit 0

# Resolve current PR via `gh pr view` (the only mechanism — there is no
# branch-name → PR shortcut). The branch value plays two roles: (1) skip-on-
# main guard, since `gh pr view` on main has no PR to resolve, and (2) cache
# invalidation key so we don't re-hit gh on every Bash call.
BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
PR_NUM=""
if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ]; then
	CACHE="$STATE_DIR/current-pr.txt"
	# Cache hit when the recorded branch matches AND the record is < 10 min
	# old. Reuse session_state_read from _lib.sh — single SSOT for the
	# `key=value` parser shared by persist / restore / pre-compact-flush.
	CACHED_BRANCH=$(session_state_read branch "$STATE_DIR")
	CACHED_PR=$(session_state_read pr "$STATE_DIR")
	CACHED_TS=$(session_state_read ts "$STATE_DIR")
	NOW=$(date +%s)
	AGE=$((NOW - ${CACHED_TS:-0}))
	if [ -f "$CACHE" ] && [ "$CACHED_BRANCH" = "$BRANCH" ] && [ "$AGE" -lt 600 ]; then
		# Cache fresh — reuse the recorded PR for the JSONL append below.
		PR_NUM="$CACHED_PR"
	else
		PR_NUM=$(cd "$REPO_ROOT" && gh pr view --json number -q '.number' 2>/dev/null || echo "")
		if [ -n "$PR_NUM" ]; then
			{
				echo "pr=$PR_NUM"
				echo "branch=$BRANCH"
				echo "ts=$NOW"
			} >"$CACHE"
		fi
	fi
fi

# Record the last meaningful tool command. Allowlist of workflow-relevant
# commands (gh / git mutations / cr / test runners). Anything else — reads
# (cat/ls/grep), edits, file probes — is dropped because none of those move
# the workflow forward in a way a post-compact session needs to resume.
case "$CMD" in
*"gh "* | *"git commit"* | *"git push"* | *"git checkout -b"* | \
	*"cr-cli "* | *"local-review.sh"* | *"phase1-launcher"* | \
	*"test-touched.sh"* | *"scripts/test.sh"* | *"bats "*)
	# Trim to first 200 chars — full HEREDOC commit messages aren't useful here.
	# Use Python for UTF-8-safe character truncation (not byte truncation).
	SHORT_CMD=$(printf '%s' "$CMD" | python3 -c 'import sys; s = sys.stdin.read().replace("\n", " "); print(s[:200])' 2>/dev/null || printf '%s' "$CMD" | head -c 200 | tr '\n' ' ')
	printf '%s\n' "$SHORT_CMD" >"$STATE_DIR/last-tool-cmd.txt"
	# Append to the rolling shared action log (PR field tagged per-row, not
	# per-file partitioned). PR_NUM was set above when the cache resolved or
	# was refreshed; empty string is fine and is what jq --arg expects.
	# v0.30.A (#187): capture jq output to var so a jq failure can't leave
	# a partial line — the guarded printf below only writes when jq
	# succeeded fully. PostToolUse fires per tool call (highest race risk
	# of the three JSONL writers). Shell `>>` opens the fd with O_APPEND;
	# POSIX guarantees the kernel atomically positions to current EOF on
	# every write, so concurrent writers don't overwrite each other's
	# bytes. POSIX does NOT mandate a PIPE_BUF-style atomic-size limit for
	# regular files (that guarantee is for pipes/FIFOs only); behavior can
	# differ on network filesystems (e.g. NFS without atomic-append wire
	# support). The jq-success-only contract is what carries the load.
	_pss_line=$(jq -nc \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg pr "${PR_NUM:-}" \
		--arg branch "$BRANCH" \
		--arg cmd "$SHORT_CMD" \
		'{ts: $ts, pr: $pr, branch: $branch, cmd: $cmd}' 2>/dev/null) || _pss_line=""
	[ -n "$_pss_line" ] && printf '%s\n' "$_pss_line" >>"$STATE_DIR/cr-round-state.jsonl" 2>/dev/null
	;;
esac

exit 0
