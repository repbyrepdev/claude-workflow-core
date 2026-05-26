#!/bin/bash
set -euo pipefail
# v0.9.5 (#73) — one-time migration of ~/.claude/settings.json.
#
# What it does:
#   1. Bumps plugin-cache version segments in any hook command path
#      from --from <ver> to --to <ver> (defaults: 0.8.5 → latest installed
#      cache version under ~/.claude/plugins/cache/claude-workflow-core/).
#   2. Registers the three new v0.8.8 hooks via the sibling
#      register-hook.sh wrapper (cr-auto-parse-poll, phase1-directive-
#      pending-guard, ship-cycle-director-gate).
#
# Why this script exists:
# Plugin version bumps that add new hooks or move hook paths require
# operator action on every consumer machine. Without this script the
# operator hand-edits settings.json — error-prone, drift-prone, and the
# auto-mode classifier blocks programmatic edits without an allowlist
# (lifted by #72: `install-register-hook-permissions.sh`). This script
# composes the two: bump existing refs + register new hooks via the
# sanctioned wrapper path.
#
# Usage:
#   migrate-settings.sh                          # bump 0.8.5 → latest, register 3 new hooks
#   migrate-settings.sh --from 0.8.5 --to 0.8.8  # explicit version bump
#   migrate-settings.sh --dry-run                # show plan, no writes
#   migrate-settings.sh --help
#
# Exit codes:
#   0 — migration succeeded (or --dry-run shows clean plan)
#   2 — usage / precondition error (missing jq, missing settings.json,
#       missing register-hook.sh, classifier-allowlist not installed)
#   3 — settings.json malformed / write failure

DRY_RUN=0
FROM_VER=""
TO_VER=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--from)
		if [ -z "${2:-}" ] || [[ ${2:-} == -* ]]; then
			echo "migrate-settings.sh: --from requires a version value" >&2
			exit 2
		fi
		FROM_VER=$2
		shift 2
		;;
	--to)
		if [ -z "${2:-}" ] || [[ ${2:-} == -* ]]; then
			echo "migrate-settings.sh: --to requires a version value" >&2
			exit 2
		fi
		TO_VER=$2
		shift 2
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
		echo "migrate-settings.sh: unknown flag '$1'" >&2
		exit 2
		;;
	*)
		echo "migrate-settings.sh: unexpected positional '$1'" >&2
		exit 2
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "migrate-settings.sh: jq required but not installed" >&2
	exit 2
fi

SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
PLUGIN_CACHE_BASE="${PLUGIN_CACHE_BASE:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REGISTER_HOOK="$SCRIPT_DIR/register-hook.sh"

if [ ! -f "$SETTINGS" ]; then
	echo "migrate-settings.sh: $SETTINGS does not exist" >&2
	exit 2
fi
if ! jq empty "$SETTINGS" 2>/dev/null; then
	echo "migrate-settings.sh: $SETTINGS is malformed JSON — refusing to migrate" >&2
	exit 3
fi
if [ ! -x "$REGISTER_HOOK" ]; then
	echo "migrate-settings.sh: sibling register-hook.sh not found or not executable: $REGISTER_HOOK" >&2
	echo "  Reinstall the plugin or check file mode (chmod +x)." >&2
	exit 2
fi

# Auto-detect the latest installed plugin cache version when --to is not given.
if [ -z "$TO_VER" ]; then
	if [ ! -d "$PLUGIN_CACHE_BASE" ]; then
		echo "migrate-settings.sh: plugin cache base not found: $PLUGIN_CACHE_BASE" >&2
		echo "  Specify --to <version> explicitly or install the plugin first." >&2
		exit 2
	fi
	# List dirs under the cache base, pick the highest semver-like name.
	# `sort -V` puts 0.8.10 after 0.8.9 which is what we want.
	TO_VER=$(find "$PLUGIN_CACHE_BASE" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; |
		sort -V | tail -1)
	if [ -z "$TO_VER" ]; then
		echo "migrate-settings.sh: no cache dirs found under $PLUGIN_CACHE_BASE" >&2
		exit 2
	fi
fi

# Auto-detect the from version when --from not given. The most common
# stale version is the one currently referenced most in settings.json.
# The plugin-cache path shape has TWO `claude-workflow-core/` segments
# (package + manifest names), so we capture the semver-shaped segment
# that follows them rather than the manifest name.
if [ -z "$FROM_VER" ]; then
	FROM_VER=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| capture("/claude-workflow-core/(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)/").v]
		| group_by(.) | map({v: .[0], n: length}) | sort_by(.n) | reverse | .[0].v // empty
	' "$SETTINGS")
	if [ -z "$FROM_VER" ]; then
		echo "migrate-settings.sh: no claude-workflow-core version refs found in $SETTINGS — nothing to bump" >&2
		# Continue to hook registration anyway — paths may already be current.
		FROM_VER="$TO_VER"
	fi
fi

# The three v0.8.8 hooks added since the last migration.
NEW_HOOKS=(
	"$SCRIPT_DIR/../hooks/cr-auto-parse-poll.sh"
	"$SCRIPT_DIR/../hooks/phase1-directive-pending-guard.sh"
	"$SCRIPT_DIR/../hooks/ship-cycle-director-gate.sh"
)

# Filter to existing files only — the migration is forward-compatible
# (newer plugin versions may have already dropped some of these in favor
# of a different mechanism).
present_hooks=()
for h in "${NEW_HOOKS[@]}"; do
	if [ -f "$h" ]; then
		present_hooks+=("$h")
	fi
done

echo "=== Migration plan ==="
echo "  Settings file:    $SETTINGS"
echo "  Version bump:     $FROM_VER → $TO_VER"
echo "  New hooks:        ${#present_hooks[@]} of ${#NEW_HOOKS[@]} present"
for h in "${present_hooks[@]}"; do
	echo "    - $h"
done

# Count how many path refs would be bumped.
bump_count=$(jq --arg from "$FROM_VER" '
	[.. | .command? // empty | select(type == "string")
		| select(contains("/claude-workflow-core/" + $from + "/"))] | length
' "$SETTINGS")
echo "  Refs to bump:     $bump_count"

if [ "$DRY_RUN" = "1" ]; then
	echo ""
	echo "(dry-run — no writes)"
	exit 0
fi

# Step 1: version bump in-place via jq walk. Only replace within the
# specific `/claude-workflow-core/<from>/` segment to avoid touching
# unrelated paths that happen to contain the version string.
parent=$(dirname "$SETTINGS")
tmp=$(mktemp "$parent/.settings.XXXXXX") || {
	echo "migrate-settings.sh: cannot create tmp file in $parent" >&2
	exit 3
}
trap 'rm -f "$tmp"' EXIT

if ! jq --arg from "$FROM_VER" --arg to "$TO_VER" '
	walk(
		if type == "string" and contains("/claude-workflow-core/" + $from + "/")
		then gsub("/claude-workflow-core/" + $from + "/"; "/claude-workflow-core/" + $to + "/")
		else . end
	)
' "$SETTINGS" >"$tmp"; then
	echo "migrate-settings.sh: jq walk failed — refusing to overwrite $SETTINGS" >&2
	exit 3
fi
if ! jq empty "$tmp" 2>/dev/null; then
	echo "migrate-settings.sh: post-walk validation failed — refusing to overwrite $SETTINGS" >&2
	exit 3
fi
if ! mv "$tmp" "$SETTINGS"; then
	echo "migrate-settings.sh: mv failed ($tmp → $SETTINGS) — possibly cross-filesystem" >&2
	echo "  If you are invoking this via the agent and see classifier blocks, run:" >&2
	echo "    $SCRIPT_DIR/install-register-hook-permissions.sh" >&2
	echo "  to print the one-time allowlist entries the operator adds to settings.json." >&2
	exit 3
fi
trap - EXIT
echo ""
echo "✓ Version bump applied: $FROM_VER → $TO_VER ($bump_count refs)"

# Step 2: register the new hooks via the sanctioned wrapper. Each
# register-hook.sh call is idempotent — already-present hooks are a no-op.
if [ "${#present_hooks[@]}" -eq 0 ]; then
	echo "  No new hooks to register."
else
	echo ""
	echo "=== Registering ${#present_hooks[@]} new hook(s) ==="
	"$REGISTER_HOOK" "${present_hooks[@]}"
fi

echo ""
echo "✓ Migration complete."
