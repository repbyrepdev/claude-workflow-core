#!/bin/bash
set -euo pipefail
# event: none
# auto-register: false
# v0.18.0 (#139) — plugin-repo-only git-hook installer.
#
# Wires `.git/hooks/post-merge` to invoke `hooks/post-merge-release-fire.sh`
# inside the plugin repo. Without this, `plugin.json` version bumps merge to
# main but never tag / release / refresh consumer caches — exactly the bug
# that left v0.9 through v0.17 untagged for weeks.
#
# Composes with `scripts/install-machine.sh`: that wrapper now calls this
# one as Step 4 when run inside the plugin checkout (detected via
# `.claude-plugin/plugin.json` presence). No-op outside the plugin repo.
#
# Usage:
#   scripts/install-plugin-git-hooks.sh           # install (idempotent)
#   scripts/install-plugin-git-hooks.sh --check   # verify-only
#   scripts/install-plugin-git-hooks.sh --uninstall
#   scripts/install-plugin-git-hooks.sh --help
#
# Exit codes:
#   0 — installed (or --check found everything in place)
#   1 — --check detected drift (hook missing OR wraps wrong target)
#   2 — precondition error (not a plugin repo, git not initialized,
#       source hook script missing or non-executable)

MODE=install

while [ "$#" -gt 0 ]; do
	case "$1" in
	--check)
		MODE=check
		shift
		;;
	--uninstall)
		MODE=uninstall
		shift
		;;
	-h | --help)
		awk '
			NR == 1 { next }
			/^set / { next }
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }
			in_header { exit }
		' "$0"
		exit 0
		;;
	*)
		echo "install-plugin-git-hooks.sh: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Plugin-repo guard: refuse to run anywhere else. Other repos may also have
# `.git/hooks/post-merge` for their own purposes; we won't trample.
if [ ! -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
	echo "install-plugin-git-hooks: not inside the plugin repo (no .claude-plugin/plugin.json)" >&2
	echo "  This installer only runs inside repbyrepdev/claude-workflow-core." >&2
	exit 2
fi

# CR-in-CI #154 r1 MAJOR: `.git` is a FILE (not directory) in linked
# worktrees. Using `git rev-parse --git-dir` is the portable check.
if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
	echo "install-plugin-git-hooks: $REPO_ROOT is not inside a git repository" >&2
	exit 2
fi

SOURCE_HOOK="$REPO_ROOT/hooks/post-merge-release-fire.sh"
if [ ! -x "$SOURCE_HOOK" ]; then
	echo "install-plugin-git-hooks: source hook missing or non-exec: $SOURCE_HOOK" >&2
	exit 2
fi

# Single-target wrapper. Use a wrapper (not a symlink) so the operator can
# add other post-merge handlers later without losing release-fire.
HOOK_PATH="$REPO_ROOT/.git/hooks/post-merge"

case "$MODE" in
check)
	if [ ! -x "$HOOK_PATH" ]; then
		echo "install-plugin-git-hooks: ✗ .git/hooks/post-merge missing" >&2
		exit 1
	fi
	if [ ! -r "$HOOK_PATH" ]; then
		echo "install-plugin-git-hooks: ✗ $HOOK_PATH exists but is unreadable — fix perms and re-run" >&2
		exit 2
	fi
	# Sentinel marker for stronger drift detection. A comment in a hand-
	# written hook mentioning "post-merge-release-fire.sh" should NOT
	# false-pass; only a wrapper installed by this script will contain
	# `# wired-by: install-plugin-git-hooks` at the top.
	# code-reviewer #139 r1 IMPORTANT: prior loose grep matched any
	# substring including comments.
	if ! grep -Fq "# wired-by: install-plugin-git-hooks" "$HOOK_PATH" 2>/dev/null; then
		echo "install-plugin-git-hooks: ✗ .git/hooks/post-merge exists but isn't the canonical wrapper (missing sentinel)" >&2
		exit 1
	fi
	echo "install-plugin-git-hooks: ✓ post-merge wired"
	exit 0
	;;
uninstall)
	if [ -e "$HOOK_PATH" ]; then
		rm -f "$HOOK_PATH"
		echo "install-plugin-git-hooks: removed $HOOK_PATH"
	else
		echo "install-plugin-git-hooks: nothing to uninstall"
	fi
	exit 0
	;;
install)
	# Idempotent: if already wired correctly, no-op. Sentinel-marker
	# check (instead of substring grep) prevents false-positive on
	# hand-written hooks that mention the source script in a comment.
	if [ -x "$HOOK_PATH" ] && grep -Fq "# wired-by: install-plugin-git-hooks" "$HOOK_PATH" 2>/dev/null; then
		echo "install-plugin-git-hooks: ✓ already installed at $HOOK_PATH"
		exit 0
	fi

	# Preserve any prior content via a timestamped backup so re-running
	# the installer after operator-edits or a regenerated wrapper doesn't
	# clobber the FIRST install's backup of the original operator hook.
	# silent-failure-hunter #139 r1 MED: original .pre-v0.18.0.bak was a
	# hardcoded name that any re-install would silently overwrite.
	if [ -e "$HOOK_PATH" ]; then
		_ts=$(date -u +%Y%m%dT%H%M%SZ)
		BACKUP="${HOOK_PATH}.bak.${_ts}"
		if ! cp "$HOOK_PATH" "$BACKUP"; then
			echo "install-plugin-git-hooks: failed to back up $HOOK_PATH → $BACKUP — refusing to overwrite" >&2
			exit 2
		fi
		echo "install-plugin-git-hooks: backed up prior $HOOK_PATH → $BACKUP"
	fi

	# Write a stable wrapper that resolves the source via the repo root.
	# Sentinel marker enables stricter idempotency + --check detection.
	# Failures from the source hook are logged to a JSONL audit trail in
	# the operator's home (not the repo's .claude/logs — REPO_ROOT may
	# be unresolvable in degraded states). silent-failure-hunter #139
	# r1 CRIT: prior `|| true` silently swallowed release-fire exit 2.
	cat >"$HOOK_PATH" <<'WRAPPER'
#!/bin/bash
# wired-by: install-plugin-git-hooks (v0.18.0, #139)
# Installed by scripts/install-plugin-git-hooks.sh. DO NOT EDIT inline —
# re-run the installer to refresh. Pre-existing operator content is
# preserved in a timestamped .bak file alongside this file.
set -u
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	_ts=$(date -u +%FT%TZ)
	_home_log="$HOME/.claude/logs/post-merge-wrapper-failures.jsonl"
	mkdir -p "$(dirname "$_home_log")" 2>/dev/null || true
	printf '{"ts":"%s","hook":"post-merge-wrapper","status":"git-rev-parse-failed","cwd":"%s"}\n' \
		"$_ts" "$PWD" >>"$_home_log" 2>/dev/null || true
	exit 0
}
TARGET="$REPO_ROOT/hooks/post-merge-release-fire.sh"
if [ -x "$TARGET" ]; then
	# Capture rc BEFORE the conditional — `if ! cmd; then $?` resets to
	# the `!` operator's exit (which is 0 when it successfully inverts),
	# masking cmd's real rc.
	_rc=0
	"$TARGET" || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		_ts=$(date -u +%FT%TZ)
		_log="$REPO_ROOT/.claude/logs/post-merge-wrapper-failures.jsonl"
		mkdir -p "$(dirname "$_log")" 2>/dev/null || true
		printf '{"ts":"%s","hook":"post-merge-release-fire","rc":%d}\n' \
			"$_ts" "$_rc" >>"$_log" 2>/dev/null || true
		echo "post-merge-wrapper: release-fire exited rc=$_rc — see .claude/logs/post-merge-wrapper-failures.jsonl" >&2
	fi
fi
WRAPPER
	chmod +x "$HOOK_PATH"
	echo "install-plugin-git-hooks: ✓ wired $HOOK_PATH → hooks/post-merge-release-fire.sh"
	exit 0
	;;
esac
