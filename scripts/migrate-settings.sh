#!/bin/bash
set -euo pipefail
# v0.9.5 (#73) — one-time migration of ~/.claude/settings.json.
#
# What it does:
#   1. Bumps plugin-cache version segments in any hook command path
#      from --from <ver> to --to <ver>. Defaults: most-referenced semver
#      segment in settings.json → highest installed cache dir under
#      ~/.claude/plugins/cache/claude-workflow-core/.
#   2. Registers the three plugin-v0.8.8 hooks via the sibling
#      register-hook.sh wrapper (cr-auto-parse-poll, phase1-directive-
#      pending-guard, ship-cycle-director-gate). Idempotent — already-
#      present entries are no-ops.
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
#   migrate-settings.sh                          # auto-detect from/to
#   migrate-settings.sh --from 0.8.5 --to 0.8.8  # explicit version bump
#   migrate-settings.sh --dry-run                # show plan, no writes
#   migrate-settings.sh --help
#
# Environment overrides (used by tests + advanced operators):
#   CLAUDE_SETTINGS_FILE — path to settings.json (default ~/.claude/settings.json)
#   PLUGIN_CACHE_BASE    — plugin-cache root for TO_VER auto-detect
#                          (default ~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core)
#
# Exit codes:
#   0 — migration succeeded (or --dry-run shows clean plan)
#   2 — usage / precondition error (missing jq, missing settings.json,
#       missing register-hook.sh, no cache dirs to detect TO_VER from)
#   3 — settings.json malformed / write failure / hook registration failed
#       AFTER the version bump landed (partial-success state)

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
	# List dirs under the cache base, FILTER to semver-shaped names only
	# (X.Y.Z), then pick the highest. Without the filter a stray dir like
	# `tmp` or `current` could win `sort -V | tail -1` and produce
	# invalid paths after the jq walk.
	TO_VER=$(find "$PLUGIN_CACHE_BASE" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; |
		grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
	if [ -z "$TO_VER" ]; then
		echo "migrate-settings.sh: no semver cache dirs (X.Y.Z) found under $PLUGIN_CACHE_BASE" >&2
		exit 2
	fi
fi

# Auto-detect the from version when --from not given. The most common
# stale version is the one currently referenced most in settings.json.
# The plugin-cache path shape has TWO `claude-workflow-core/` segments
# (package + manifest names), so we capture the semver-shaped segment
# that follows them rather than the manifest name.
SKIP_BUMP=0
if [ -z "$FROM_VER" ]; then
	FROM_VER=$(jq -r '
		[.. | .command? // empty | select(type == "string")
			| capture("/claude-workflow-core/(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)/").v]
		| group_by(.) | map({v: .[0], n: length}) | sort_by(.n) | reverse | .[0].v // empty
	' "$SETTINGS")
	if [ -z "$FROM_VER" ]; then
		echo "migrate-settings.sh: NOTE: no claude-workflow-core version refs found in $SETTINGS" >&2
		echo "  — skipping Step 1 (version bump). Continuing to Step 2 (hook registration)." >&2
		SKIP_BUMP=1
		FROM_VER="$TO_VER" # placeholder; Step 1 is skipped via SKIP_BUMP
	fi
fi

# The three hooks introduced in plugin v0.8.8 that need explicit
# registration in settings.json. NEW_HOOKS is version-pinned data — if a
# future plugin version adds different hooks, edit this list.
NEW_HOOKS=(
	"$SCRIPT_DIR/../hooks/cr-auto-parse-poll.sh"
	"$SCRIPT_DIR/../hooks/phase1-directive-pending-guard.sh"
	"$SCRIPT_DIR/../hooks/ship-cycle-director-gate.sh"
)

# Filter to existing files. Partial-missing is OK (forward-compat: a
# future plugin version may drop one of these in favor of a different
# mechanism). ALL-missing is NOT ok — it likely means $SCRIPT_DIR/../hooks
# doesn't resolve to the plugin's hooks dir (wrong checkout, broken
# symlink, plugin layout changed). Surface that loudly.
present_hooks=()
for h in "${NEW_HOOKS[@]}"; do
	if [ -f "$h" ]; then
		present_hooks+=("$h")
	fi
done
if [ "${#present_hooks[@]}" -eq 0 ]; then
	echo "migrate-settings.sh: WARNING: none of the ${#NEW_HOOKS[@]} expected hook files exist" >&2
	echo "  Expected under: $(cd "$SCRIPT_DIR/.." && pwd)/hooks/" >&2
	echo "  Either the plugin layout has changed, this script lives outside the plugin," >&2
	echo "  or the operator deleted them. Step 2 (hook registration) will be skipped." >&2
fi

echo "=== Migration plan ==="
echo "  Settings file:    $SETTINGS"
if [ "$SKIP_BUMP" = "1" ]; then
	echo "  Version bump:     SKIPPED (no refs found)"
	bump_count=0
else
	echo "  Version bump:     $FROM_VER → $TO_VER"
	bump_count=$(jq --arg from "$FROM_VER" '
		[.. | .command? // empty | select(type == "string")
			| select(contains("/claude-workflow-core/" + $from + "/"))] | length
	' "$SETTINGS")
fi
echo "  New hooks:        ${#present_hooks[@]} of ${#NEW_HOOKS[@]} present"
# Empty-array iteration under `set -u` errors on bash 3.2 — guard with
# length check rather than the `${arr[@]+"${arr[@]}"}` idiom (clearer
# and avoids shellcheck's SC2068 warnings).
if [ "${#present_hooks[@]}" -gt 0 ]; then
	for h in "${present_hooks[@]}"; do
		echo "    - $h"
	done
fi
echo "  Refs to bump:     $bump_count"

if [ "$DRY_RUN" = "1" ]; then
	echo ""
	echo "(dry-run — no writes)"
	exit 0
fi

# Step 1: version bump in-place via jq walk. Only replace within the
# specific `/claude-workflow-core/<from>/` segment to avoid touching
# unrelated paths that happen to contain the version string. Skipped
# entirely when no matching refs exist (a no-op write would still rename
# the inode + reset mtime — not worth the side-effect).
if [ "$SKIP_BUMP" = "0" ]; then
	parent=$(dirname "$SETTINGS")
	tmp=$(mktemp "$parent/.settings.XXXXXX") || {
		echo "migrate-settings.sh: cannot create tmp file in $parent" >&2
		exit 3
	}
	trap 'rm -f "$tmp"' EXIT

	# jq `gsub` is regex-based — escape dots in $from before interpolation
	# so '0.8.5' matches literally instead of allowing '0a8b5' etc.
	# `contains()` is a literal substring check; gsub still needs the
	# escape to avoid replacing regex-coincidental matches elsewhere in
	# the same string.
	if ! jq --arg from "$FROM_VER" --arg to "$TO_VER" '
		def escape_dots: gsub("\\."; "\\.");
		walk(
			if type == "string" and contains("/claude-workflow-core/" + $from + "/")
			then gsub("/claude-workflow-core/" + ($from | escape_dots) + "/"; "/claude-workflow-core/" + $to + "/")
			else . end
		)
	' "$SETTINGS" >"$tmp"; then
		echo "migrate-settings.sh: jq walk failed — refusing to overwrite $SETTINGS" >&2
		exit 3
	fi
	if ! mv "$tmp" "$SETTINGS"; then
		echo "migrate-settings.sh: mv failed ($tmp → $SETTINGS)" >&2
		echo "  Likely causes: cross-filesystem move, read-only mount, permission" >&2
		echo "  denied, or disk full. Check the parent directory ($parent)." >&2
		exit 3
	fi
	trap - EXIT
	echo ""
	echo "✓ Version bump applied: $FROM_VER → $TO_VER ($bump_count refs)"
fi

# Step 2: register the new hooks via the sanctioned wrapper. Each
# register-hook.sh call is idempotent — already-present hooks are a no-op.
# Step 1 has already committed the bump, so a Step 2 failure leaves
# settings.json in a partial state — wrap with an explicit error handler
# so the operator knows which step failed + how to retry only Step 2.
if [ "${#present_hooks[@]}" -gt 0 ]; then
	echo ""
	echo "=== Registering ${#present_hooks[@]} new hook(s) ==="
	if ! "$REGISTER_HOOK" "${present_hooks[@]}"; then
		echo "" >&2
		echo "migrate-settings.sh: hook registration FAILED." >&2
		if [ "$SKIP_BUMP" = "0" ]; then
			echo "  Version bump (Step 1) HAS been applied — settings.json is in a" >&2
			echo "  partial-migration state. Retry hook registration manually:" >&2
		else
			echo "  Retry hook registration manually:" >&2
		fi
		echo "    $REGISTER_HOOK ${present_hooks[*]}" >&2
		echo "" >&2
		echo "  If you see classifier blocks from the agent, run" >&2
		echo "  $SCRIPT_DIR/install-register-hook-permissions.sh" >&2
		echo "  first to install the one-time allowlist (PR #72)." >&2
		exit 3
	fi
fi

echo ""
echo "✓ Migration complete."
