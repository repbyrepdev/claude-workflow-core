#!/bin/bash
set -euo pipefail
# (#87) Pre-commit gate: hook add must bump plugin.json version.
#
# Plugin-cache directory selection on consumer machines is keyed on
# .claude-plugin/plugin.json.version. Without a bump, new hooks ship
# in source but never reach consumer environments.
#
# Fires on ANY staged change (add/modify/rename) to hook files in
# either layout:
#   - `hooks/*.sh` (plugin source-tree, single-level)
#   - `.claude/hooks/*.sh` (consumer layout — also plugin-shipped per
#     plugin.json description)
# No content-aware filtering — comment-only or whitespace-only edits
# also require a bump. Use PLUGIN_VERSION_BUMP_SKIP=1 for genuinely
# no-op edits (audit-logged to stderr — ephemeral, not persistent).
#
# Bonus downgrade catch (#74-adjacent): staged plugin.json version
# strictly less than HEAD's version → also fail. Catches accidental
# regression that breaks consumer pins. Compared via `sort -V` so
# semver-aware (0.10.0 > 0.2.0). Compares against HEAD (previous
# commit) not main — branch divergence is out of scope.
#
# Exit codes:
#   0 — passed (no hook changes staged, or staged + version bumped,
#       or bypass via env, or plugin.json absent (not in plugin repo))
#   1 — failed (hooks staged without plugin.json version bump, or
#       plugin.json downgrade)
#   2 — precondition error (jq missing, plugin.json malformed, staged
#       plugin.json has no .version, not in git repo)

if [ "${PLUGIN_VERSION_BUMP_SKIP:-0}" = "1" ]; then
	echo "plugin-version-bump-gate: PLUGIN_VERSION_BUMP_SKIP=1 — passing through (audit logged)" >&2
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "plugin-version-bump-gate: jq required but not installed" >&2
	exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "plugin-version-bump-gate: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT"

PLUGIN_JSON=".claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
	echo "plugin-version-bump-gate: $PLUGIN_JSON not found (not in plugin repo?) — passing through" >&2
	exit 0
fi
if ! jq empty "$PLUGIN_JSON" 2>/dev/null; then
	echo "plugin-version-bump-gate: $PLUGIN_JSON is malformed JSON" >&2
	exit 2
fi

# Find staged hook files. Matches both layouts (single-level only —
# nested subdirs are out of scope; plugin runtime only loads top-
# level files). Uses --name-only (correct rename handling — unlike
# --name-status whose 3-column rename format would trap awk-on-$2).
# Pathspec `*` in git is path-recursive by default, so we filter
# afterwards with grep for the single-level glob shape.
hooks_staged=$(git diff --cached --name-only --diff-filter=ACMR -- \
	'hooks/' '.claude/hooks/' 2>/dev/null |
	grep -E '^(\.claude/)?hooks/[^/]+\.sh$' || true)
if [ -z "$hooks_staged" ]; then
	# No hook changes staged → gate doesn't fire
	exit 0
fi

# Is plugin.json staged?
plugin_staged=$(git diff --cached --name-only | grep -Fx "$PLUGIN_JSON" || true)
if [ -z "$plugin_staged" ]; then
	echo "plugin-version-bump-gate: FAIL — staged hook(s) without plugin.json bump:" >&2
	printf '%s\n' "$hooks_staged" | sed 's/^/  /' >&2
	echo "" >&2
	echo "Plugin-cache directory selection on consumer machines is keyed" >&2
	echo "on .claude-plugin/plugin.json.version. Without a bump, this new" >&2
	echo "hook ships in source but never reaches consumer environments." >&2
	echo "" >&2
	echo "Fix: bump the patch in $PLUGIN_JSON and stage it with this commit." >&2
	echo "Bypass (sparingly, audit-logged): PLUGIN_VERSION_BUMP_SKIP=1 git commit ..." >&2
	exit 1
fi

# plugin.json IS staged. Did the version field actually change?
# Compare the staged version to the HEAD (committed) version.
# Symmetric || printf '' fallback to head_ver below — set -euo pipefail
# would otherwise abort here when git show fails (e.g. blob missing
# from index for whatever reason). Empty staged_ver flows into the
# next check + emits a clear precondition error.
staged_ver=$(git show ":$PLUGIN_JSON" 2>/dev/null | jq -r '.version // ""' || printf '')
head_ver=$(git show "HEAD:$PLUGIN_JSON" 2>/dev/null | jq -r '.version // ""' || printf '')

if [ -z "$staged_ver" ]; then
	echo "plugin-version-bump-gate: staged $PLUGIN_JSON has no .version field" >&2
	exit 2
fi

if [ "$staged_ver" = "$head_ver" ]; then
	echo "plugin-version-bump-gate: FAIL — staged hook(s) without plugin.json version BUMP:" >&2
	printf '%s\n' "$hooks_staged" | sed 's/^/  /' >&2
	echo "" >&2
	echo "Plugin.json IS staged but .version is still '$head_ver' (unchanged from HEAD)." >&2
	# Only suggest a concrete bump when the version is a 3-part semver
	# we can safely increment. Non-semver schemes get a generic message.
	if [[ $head_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		suggested=$(printf '%s' "$head_ver" | awk -F. '{printf "%s.%s.%d\n", $1, $2, $3+1}')
		echo "Bump the patch version (e.g. $head_ver → $suggested)." >&2
	else
		echo "Bump the version per your versioning scheme." >&2
	fi
	exit 1
fi

# Bonus #74-adjacent: catch downgrade
# Compare staged_ver vs head_ver using sort -V; the higher should come last.
if [ -n "$head_ver" ]; then
	higher=$(printf '%s\n%s\n' "$head_ver" "$staged_ver" | sort -V | tail -1)
	if [ "$higher" = "$head_ver" ] && [ "$head_ver" != "$staged_ver" ]; then
		echo "plugin-version-bump-gate: FAIL — staged plugin.json downgrades version: $head_ver → $staged_ver" >&2
		echo "Downgrades break plugin-cache pinning on consumer machines." >&2
		exit 1
	fi
fi

# All good
exit 0
