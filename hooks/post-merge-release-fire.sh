#!/bin/bash
set -euo pipefail
# event: git-post-merge
# auto-register: false
# v0.9.6 (#88) — post-merge auto-fire of scripts/release.sh when
# .claude-plugin/plugin.json.version changed in the merge.
#
# Why: prior to #88, operator had to remember to run `scripts/release.sh`
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
# scripts/install-machine.sh installs this wiring automatically when
# present in the repo.
#
# Behavior:
#   1. Read ACTIONS_MODE via hooks/_read-actions-mode.sh.
#      - remote: workflow .github/workflows/release.yml fires on tag
#        push; the hook is a no-op (avoids duplicate releases).
#      - local: continue.
#   2. Compare HEAD's plugin.json.version against HEAD~1 (or HEAD~1
#        from the merge's first parent if a merge commit).
#      - Same version → no-op (typical merge that didn't touch manifest).
#      - Different version → fire `scripts/release.sh` detached (nohup +
#        setsid) so the post-merge hook returns immediately.
#   3. Log invocation to .claude/logs/release-auto-fire.jsonl with
#      timestamp + from→to version + rc.
#
# Bypass (audit-trail to stderr):
#   POST_MERGE_RELEASE_FIRE_SKIP=1 — skip without firing release.sh.
#   Use when amending merges or rebasing where the version "moved" in
#   ways release.sh shouldn't react to.
#
# Exit codes (caller is git's post-merge hook; nonzero won't break the
# merge but is logged):
#   0 — fired, skipped intentionally, or version unchanged
#   2 — precondition (jq missing, malformed plugin.json, not in repo)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -z "$REPO_ROOT" ] && exit 0
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
if ! command -v jq >/dev/null 2>&1; then
	echo "post-merge-release-fire: jq required but not installed" >&2
	exit 2
fi
if ! jq empty "$PLUGIN_JSON" 2>/dev/null; then
	echo "post-merge-release-fire: $PLUGIN_JSON malformed JSON" >&2
	exit 2
fi

READER="$REPO_ROOT/hooks/_read-actions-mode.sh"
if [ ! -x "$READER" ]; then
	echo "post-merge-release-fire: $READER missing or not executable" >&2
	exit 2
fi
ACTIONS_MODE=$("$READER")
if [ "$ACTIONS_MODE" = "remote" ]; then
	echo "post-merge-release-fire: ACTIONS_MODE=remote — release.yml workflow authoritative; hook no-op" >&2
	exit 0
fi

NEW_VER=$(jq -r '.version // ""' "$PLUGIN_JSON")
if [ -z "$NEW_VER" ]; then
	echo "post-merge-release-fire: $PLUGIN_JSON has no .version field" >&2
	exit 0
fi

# Resolve previous version from HEAD~1 (first parent of merge commit).
OLD_VER=""
if git rev-parse --verify -q "HEAD~1:$PLUGIN_JSON" >/dev/null 2>&1; then
	OLD_VER=$(git show "HEAD~1:$PLUGIN_JSON" 2>/dev/null | jq -r '.version // ""' 2>/dev/null || printf '')
fi

if [ "$NEW_VER" = "$OLD_VER" ]; then
	# No version change in this merge — most common case, silent no-op.
	exit 0
fi

LOG_DIR="$REPO_ROOT/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/release-auto-fire.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SHA=$(git rev-parse HEAD)

# Spawn release.sh detached so post-merge returns quickly. Output goes
# to a log file the operator can tail. setsid + nohup detach from the
# git process group so it survives git's exit.
RELEASE_LOG="$LOG_DIR/release-auto-fire-$NEW_VER.log"
RELEASE_SH="$REPO_ROOT/scripts/release.sh"
if [ ! -x "$RELEASE_SH" ]; then
	printf '{"ts":"%s","sha":"%s","from":"%s","to":"%s","status":"missing-release-sh"}\n' \
		"$TS" "$SHA" "$OLD_VER" "$NEW_VER" >>"$LOG_FILE"
	echo "post-merge-release-fire: $RELEASE_SH missing — cannot fire release" >&2
	exit 2
fi

# Detach via setsid (Linux) or fall back to nohup-only (macOS BSD).
if command -v setsid >/dev/null 2>&1; then
	setsid nohup "$RELEASE_SH" >"$RELEASE_LOG" 2>&1 </dev/null &
else
	nohup "$RELEASE_SH" >"$RELEASE_LOG" 2>&1 </dev/null &
fi
SPAWNED_PID=$!

printf '{"ts":"%s","sha":"%s","from":"%s","to":"%s","pid":%d,"log":"%s","status":"fired"}\n' \
	"$TS" "$SHA" "$OLD_VER" "$NEW_VER" "$SPAWNED_PID" "$RELEASE_LOG" >>"$LOG_FILE"
echo "post-merge-release-fire: version bump $OLD_VER → $NEW_VER detected; release.sh spawned (pid $SPAWNED_PID, log $RELEASE_LOG)" >&2
exit 0
