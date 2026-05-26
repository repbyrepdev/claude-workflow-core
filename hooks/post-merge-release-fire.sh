#!/bin/bash
set -euo pipefail
# event: git-post-merge
# auto-register: false
# Introduced in #88 (released as v0.9.7) — post-merge auto-fire of
# scripts/release.sh when .claude-plugin/plugin.json.version changed
# in the merge.
#
# Why: prior to #88, operator had to remember to run scripts/release.sh
# after every plugin-version-bumping PR merge. Forgetting meant
# consumers never saw the new content (cache dir for the new version
# never created) even though source had it.
#
# Wiring (one-time per clone — git's post-merge is local-only):
#   cat >> .git/hooks/post-merge <<'EOF'
#   if [ -x "$(dirname "$0")/../../hooks/post-merge-release-fire.sh" ]; then
#       "$(dirname "$0")/../../hooks/post-merge-release-fire.sh" || true
#   fi
#   EOF
#
# Auto-wiring via scripts/install-machine.sh is TBD (deferred to a
# follow-up). For now wire by hand using the snippet above.
#
# Worktree caveat: git worktrees share .git/hooks/ with the main repo;
# this snippet resolves the hook script via the main checkout's
# hooks/ directory. Worktree releases need direct invocation.
#
# Behavior:
#   1. Read ACTIONS_MODE via hooks/_read-actions-mode.sh.
#      - remote: a .github/workflows/release.yml workflow IS expected
#        to handle releases on tag push (per Epic #58); the hook
#        no-ops to avoid duplicate releases. The workflow itself
#        lands separately — until it exists, ACTIONS_MODE=remote
#        means NO release at all, by design (operators in remote
#        mode have opted out of local release packaging).
#      - local: continue to version-diff check.
#   2. Compare HEAD's plugin.json.version against the first parent
#      (HEAD~1). For merge commits HEAD~1 is the first parent (the
#      target-branch tip pre-merge); only linear/squash/merge-commit
#      workflows are supported. Rebase-merge with concurrent version
#      bumps may need manual release.sh invocation.
#      - Same version → log status=no-version-change + exit 0.
#      - Different version → validate both as X.Y.Z semver, then fire
#        scripts/release.sh detached so the post-merge hook returns
#        immediately.
#   3. Log every invocation outcome to .claude/logs/release-auto-fire.jsonl
#      via `jq -cn` (proper JSON escaping; raw printf would corrupt
#      the log on malicious/buggy version strings).
#
# Bypass (audit-trail to stderr):
#   POST_MERGE_RELEASE_FIRE_SKIP=1 — skip without firing release.sh.
#
# Exit codes:
#   0 — fired, skipped intentionally, version unchanged, or no
#       plugin.json (not a plugin repo) / no .version field
#   2 — toolchain/invariant violation (jq missing, plugin.json
#       malformed JSON, _read-actions-mode.sh missing/non-exec,
#       release.sh missing/non-exec, log dir uncreatable, malformed
#       version string in plugin.json that the upstream gates should
#       have caught)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$REPO_ROOT"

if [ "${POST_MERGE_RELEASE_FIRE_SKIP:-0}" = "1" ]; then
	echo "post-merge-release-fire: POST_MERGE_RELEASE_FIRE_SKIP=1 — skipping" >&2
	exit 0
fi

PLUGIN_JSON=".claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
	# Not a plugin repo — hook is a no-op.
	exit 0
fi

# Read ACTIONS_MODE BEFORE jq check — remote-mode operators may not
# have jq installed locally because remote workflows handle releases.
READER="$REPO_ROOT/hooks/_read-actions-mode.sh"
if [ ! -x "$READER" ]; then
	echo "post-merge-release-fire: $READER missing or not executable" >&2
	exit 2
fi
ACTIONS_MODE=$("$READER" 2>&1) || {
	echo "post-merge-release-fire: $READER failed: $ACTIONS_MODE" >&2
	exit 2
}
case "$ACTIONS_MODE" in
remote)
	echo "post-merge-release-fire: ACTIONS_MODE=remote — release.yml workflow authoritative; hook no-op" >&2
	exit 0
	;;
local) ;;
*)
	echo "post-merge-release-fire: unexpected ACTIONS_MODE='$ACTIONS_MODE' — refusing to fire" >&2
	exit 2
	;;
esac

if ! command -v jq >/dev/null 2>&1; then
	echo "post-merge-release-fire: jq required but not installed" >&2
	exit 2
fi
if ! jq_err=$(jq empty "$PLUGIN_JSON" 2>&1); then
	echo "post-merge-release-fire: $PLUGIN_JSON failed jq validation: $jq_err" >&2
	exit 2
fi

NEW_VER=$(jq -r '.version // ""' "$PLUGIN_JSON")
if [ -z "$NEW_VER" ]; then
	echo "post-merge-release-fire: $PLUGIN_JSON has no .version field" >&2
	exit 0
fi

# Validate NEW_VER as strict semver X.Y.Z before using it in path
# construction or shell expansion. The upstream gates (#74, #87)
# enforce this on commit; defense-in-depth here keeps a corrupted
# manifest from injecting path-traversal or shell metacharacters
# into LOG_DIR/RELEASE_LOG construction.
if ! [[ $NEW_VER =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "post-merge-release-fire: $PLUGIN_JSON .version='$NEW_VER' is not X.Y.Z — refusing to fire" >&2
	exit 2
fi

# Resolve OLD_VER from HEAD~1's plugin.json. Three possible outcomes:
#   - HEAD~1 doesn't have the file (first-time introduction): OLD_VER=""
#     → log first-introduction + still fire (release.sh handles tag-
#     exists idempotency).
#   - HEAD~1 has malformed plugin.json: hard fail (exit 2). Pre-#88
#     plugin.json is well-formed; a corrupted historical commit means
#     bigger trouble than this hook should silently paper over.
#   - HEAD~1 has the file: extract .version. Empty .version → OLD_VER="".
OLD_VER=""
if old_raw=$(git show "HEAD~1:$PLUGIN_JSON" 2>/dev/null); then
	if printf '%s' "$old_raw" | jq empty 2>/dev/null; then
		OLD_VER=$(printf '%s' "$old_raw" | jq -r '.version // ""')
	else
		echo "post-merge-release-fire: HEAD~1:$PLUGIN_JSON is malformed — refusing to compare" >&2
		exit 2
	fi
fi

# Validate OLD_VER if non-empty (the empty case = first introduction
# is handled below).
if [ -n "$OLD_VER" ] && ! [[ $OLD_VER =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "post-merge-release-fire: HEAD~1 .version='$OLD_VER' is not X.Y.Z — refusing to compare" >&2
	exit 2
fi

LOG_DIR="$REPO_ROOT/.claude/logs"
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
	echo "post-merge-release-fire: cannot create $LOG_DIR — run scripts/release.sh manually" >&2
	exit 2
fi
LOG_FILE="$LOG_DIR/release-auto-fire.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SHA=$(git rev-parse HEAD 2>/dev/null) || SHA="unknown"

_log_jsonl() {
	# Construct JSONL via jq for proper escaping. Args: status [pid] [log].
	local status=$1 pid=${2:-} log=${3:-}
	if [ -n "$pid" ]; then
		jq -cn --arg ts "$TS" --arg sha "$SHA" --arg from "$OLD_VER" \
			--arg to "$NEW_VER" --arg status "$status" \
			--argjson pid "$pid" --arg log "$log" \
			'{ts:$ts,sha:$sha,from:$from,to:$to,status:$status,pid:$pid,log:$log}' \
			>>"$LOG_FILE"
	else
		jq -cn --arg ts "$TS" --arg sha "$SHA" --arg from "$OLD_VER" \
			--arg to "$NEW_VER" --arg status "$status" \
			'{ts:$ts,sha:$sha,from:$from,to:$to,status:$status}' \
			>>"$LOG_FILE"
	fi
}

if [ "$NEW_VER" = "$OLD_VER" ]; then
	# Log every invocation outcome so operators can grep the SHA and
	# confirm the hook ran (even when it correctly no-ops).
	_log_jsonl "no-version-change"
	exit 0
fi

RELEASE_SH="$REPO_ROOT/scripts/release.sh"
if [ ! -x "$RELEASE_SH" ]; then
	_log_jsonl "missing-release-sh"
	echo "post-merge-release-fire: $RELEASE_SH missing — cannot fire release" >&2
	exit 2
fi

# NEW_VER is now validated as ^[0-9]+\.[0-9]+\.[0-9]+$ so it is safe
# to use in the log filename without further sanitization.
RELEASE_LOG="$LOG_DIR/release-auto-fire-$NEW_VER.log"

# Detach via setsid (Linux) or fall back to nohup-only (macOS BSD).
# Both forms redirect stdin/stdout/stderr so the spawn doesn't hold
# fds back to git, and `&` returns control immediately.
if command -v setsid >/dev/null 2>&1; then
	setsid nohup "$RELEASE_SH" >"$RELEASE_LOG" 2>&1 </dev/null &
else
	nohup "$RELEASE_SH" >"$RELEASE_LOG" 2>&1 </dev/null &
fi
SPAWNED_PID=$!
disown "$SPAWNED_PID" 2>/dev/null || true

if [ -z "$OLD_VER" ]; then
	_log_jsonl "fired-first-introduction" "$SPAWNED_PID" "$RELEASE_LOG"
	echo "post-merge-release-fire: first-introduction of plugin.json → $NEW_VER; release.sh spawned (pid $SPAWNED_PID, log $RELEASE_LOG)" >&2
else
	_log_jsonl "fired" "$SPAWNED_PID" "$RELEASE_LOG"
	echo "post-merge-release-fire: version bump $OLD_VER → $NEW_VER detected; release.sh spawned (pid $SPAWNED_PID, log $RELEASE_LOG)" >&2
fi
exit 0
