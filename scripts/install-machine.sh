#!/bin/bash
set -euo pipefail
# v0.9.5 (#71) — operator-time machine setup wrapper.
#
# Single entry point for setting up a machine after plugin install or
# upgrade. Composes the three existing pieces:
#   1. install-register-hook-permissions.sh — verifies the classifier
#      allowlist is in place (operator pastes the snippet once if not)
#   2. hooks/install-hooks.sh — frontmatter-scanning installer that
#      registers every hook with `# event:` + `# auto-register: true`
#      into ~/.claude/settings.json. Additive — preserves operator-
#      customized entries.
#   3. (optional) scripts/migrate-settings.sh — bumps existing
#      version-pinned paths to the current plugin version. Skipped
#      when --no-migrate is passed.
#
# Usage:
#   scripts/install-machine.sh                  # full setup
#   scripts/install-machine.sh --check          # verify-only, no writes
#   scripts/install-machine.sh --no-migrate     # skip step 3
#   scripts/install-machine.sh --help
#
# Acceptance criteria from #71:
#   - No manual ~/.claude/settings.json edit needed for default hook set
#   - Operator-customized entries preserved (additive register only)
#   - One-shot migration story via migrate-settings.sh (step 3)
#
# Exit codes:
#   0 — full setup succeeded (or --check found everything in place)
#   1 — --check found drift (classifier allowlist missing, OR hooks
#       discovered that are not yet registered)
#   2 — usage / precondition error (missing jq, missing sibling script,
#       classifier allowlist not yet installed and operator needs to
#       paste the snippet manually before this script can write
#       settings.json autonomously)
#   3 — settings.json malformed or write failed mid-install

CHECK_ONLY=0
SKIP_MIGRATE=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--check)
		CHECK_ONLY=1
		shift
		;;
	--no-migrate)
		SKIP_MIGRATE=1
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
	-*)
		echo "install-machine.sh: unknown flag '$1'" >&2
		exit 2
		;;
	*)
		echo "install-machine.sh: unexpected positional '$1'" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PERMS_SCRIPT="$SCRIPT_DIR/install-register-hook-permissions.sh"
HOOKS_INSTALLER="$REPO_ROOT/hooks/install-hooks.sh"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate-settings.sh"

for sibling in "$PERMS_SCRIPT" "$HOOKS_INSTALLER"; do
	if [ ! -x "$sibling" ]; then
		echo "install-machine.sh: required sibling script not found or not executable: $sibling" >&2
		echo "  Reinstall the plugin or check file mode." >&2
		exit 2
	fi
done

# Step 1: classifier-allowlist readiness check
echo "=== Step 1: classifier allowlist (PR #72) ==="
if "$PERMS_SCRIPT" --check >/dev/null 2>&1; then
	echo "  ✓ Allowlist patterns present"
else
	if [ "$CHECK_ONLY" = "1" ]; then
		echo "  ✗ Allowlist patterns missing (--check)" >&2
		"$PERMS_SCRIPT" --check >&2 || true
		exit 1
	fi
	echo "  ✗ Allowlist patterns missing." >&2
	echo "" >&2
	echo "  ONE-TIME setup required. Run:" >&2
	echo "    $PERMS_SCRIPT --json" >&2
	echo "" >&2
	echo "  Then paste the printed snippet into ~/.claude/settings.json's" >&2
	echo "  .permissions.allow array, save, and re-run this script." >&2
	echo "" >&2
	echo "  Why: the auto-mode classifier hard-blocks programmatic edits" >&2
	echo "  to settings.json. The allowlist authorizes the install steps" >&2
	echo "  below to write autonomously thereafter." >&2
	exit 2
fi

# Step 2: hook registration
echo ""
echo "=== Step 2: register plugin hooks (hooks/install-hooks.sh) ==="
if [ "$CHECK_ONLY" = "1" ]; then
	# install-hooks.sh is itself additive + idempotent; --check mode is
	# not provided. Approximation: run register-hook.sh --check via the
	# sibling script if available, otherwise just report invocation.
	REGISTER_HOOK="$SCRIPT_DIR/register-hook.sh"
	if [ -x "$REGISTER_HOOK" ]; then
		if ! "$REGISTER_HOOK" --check; then
			echo "  ✗ register-hook --check found drift" >&2
			exit 1
		fi
		echo "  ✓ register-hook --check clean"
	else
		echo "  (skipping — install-hooks.sh has no --check mode and register-hook.sh not found)"
	fi
else
	"$HOOKS_INSTALLER"
fi

# Step 3: version path migration (optional)
if [ "$SKIP_MIGRATE" = "1" ]; then
	echo ""
	echo "=== Step 3: SKIPPED via --no-migrate ==="
elif [ -x "$MIGRATE_SCRIPT" ]; then
	echo ""
	echo "=== Step 3: bump stale path versions (scripts/migrate-settings.sh) ==="
	if [ "$CHECK_ONLY" = "1" ]; then
		"$MIGRATE_SCRIPT" --dry-run
	else
		"$MIGRATE_SCRIPT"
	fi
else
	echo ""
	echo "=== Step 3: SKIPPED (migrate-settings.sh not present) ==="
fi

echo ""
echo "✓ install-machine.sh complete."
