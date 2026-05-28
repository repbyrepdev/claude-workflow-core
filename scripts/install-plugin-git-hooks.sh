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

if [ ! -d "$REPO_ROOT/.git" ]; then
	echo "install-plugin-git-hooks: $REPO_ROOT/.git not found (git not initialized?)" >&2
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
	# The expected wrapper contains the source-hook invocation. Match
	# loosely so future composition with other handlers doesn't false-trip.
	if ! grep -Fq "post-merge-release-fire.sh" "$HOOK_PATH" 2>/dev/null; then
		echo "install-plugin-git-hooks: ✗ .git/hooks/post-merge exists but doesn't invoke release-fire" >&2
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
	# Idempotent: if already wired correctly, no-op.
	if [ -x "$HOOK_PATH" ] && grep -Fq "post-merge-release-fire.sh" "$HOOK_PATH" 2>/dev/null; then
		echo "install-plugin-git-hooks: ✓ already installed at $HOOK_PATH"
		exit 0
	fi

	# Preserve any prior content via a one-shot backup if the file
	# exists but doesn't yet wire release-fire. Operators with their
	# own post-merge logic can manually compose afterward.
	if [ -e "$HOOK_PATH" ]; then
		BACKUP="${HOOK_PATH}.pre-v0.18.0.bak"
		cp "$HOOK_PATH" "$BACKUP"
		echo "install-plugin-git-hooks: backed up prior $HOOK_PATH → $BACKUP"
	fi

	# Write a stable wrapper that resolves the source via the repo root.
	# Single-file edit; chmod +x; done.
	cat >"$HOOK_PATH" <<'WRAPPER'
#!/bin/bash
# Installed by scripts/install-plugin-git-hooks.sh (v0.18.0, #139).
# DO NOT EDIT inline — re-run the installer or compose around this snippet.
set -u
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
TARGET="$REPO_ROOT/hooks/post-merge-release-fire.sh"
if [ -x "$TARGET" ]; then
	"$TARGET" || true
fi
WRAPPER
	chmod +x "$HOOK_PATH"
	echo "install-plugin-git-hooks: ✓ wired $HOOK_PATH → hooks/post-merge-release-fire.sh"
	exit 0
	;;
esac
