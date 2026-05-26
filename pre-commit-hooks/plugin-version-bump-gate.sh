#!/bin/bash
set -euo pipefail
# (#87) Pre-commit gate: hook add must bump plugin.json version.
#
# Catches the gap where a PR adds a file under hooks/ but doesn't
# bump .claude-plugin/plugin.json.version. Without the version bump,
# the new hook ships in source but never reaches consumer machines
# (plugin-cache directory selection on the consumer side is keyed on
# version — until consumers pin the new version, the new hook is
# unreachable).
#
# Detects both:
#   - A new hook file added (status A in `git diff --cached --name-status`)
#   - An existing hook file modified (status M) IF the modification
#     changes behavior — heuristically: any non-comment line change
#     in a hooks/*.sh file requires a bump.
#
# Fires when:
#   - At least one staged file matches `^hooks/.*\.sh$`
#   - AND .claude-plugin/plugin.json is NOT in the staged set, OR
#     plugin.json IS staged but the `version` field didn't change.
#
# Bypass: PLUGIN_VERSION_BUMP_SKIP=1 (audit-logged via stderr).
# Use for hot-fixes / doc-only hook edits that genuinely don't need
# a version bump. Bypass leaves a trail so misuse is auditable.
#
# Exit codes:
#   0 — gate passed (no hooks staged, or hooks staged + plugin.json bumped, or bypass)
#   1 — gate failed (hooks staged without corresponding plugin.json bump)
#   2 — usage / precondition error (jq missing, plugin.json missing/malformed)
#
# Bonus #74-adjacent check: if the staged plugin.json's version field
# is being set to a value LESS THAN the current main-branch value,
# also fail (catches accidental downgrade). This is the #74 contract
# in reverse — same gate, different direction.

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

# Find staged hook files (matches hooks/*.sh — single-level only;
# nested subdirs are out of scope per current plugin layout).
hooks_staged=$(git diff --cached --name-status | awk '$2 ~ /^hooks\/[^\/]+\.sh$/ {print $0}')
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
staged_ver=$(git show ":$PLUGIN_JSON" 2>/dev/null | jq -r '.version // ""')
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
	echo "Bump the patch version (e.g. $head_ver → $(printf '%s' "$head_ver" | awk -F. '{printf "%s.%s.%d\n", $1, $2, $3+1}'))." >&2
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
