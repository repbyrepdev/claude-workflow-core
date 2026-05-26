#!/bin/bash
set -euo pipefail
# (#74) Pre-commit gate: commit subject scope `v<X.Y.Z>` must not
# exceed .claude-plugin/plugin.json.version. Forces version-bump-
# with-commit discipline (you can't claim to be on v0.9.6 in the
# subject line if the manifest still says 0.9.5).
#
# Complements #87 (pre-commit version-bump-gate, which catches
# hook-add without bump). This gate catches the inverse mismatch:
# claiming a version in subject without actually bumping it.
#
# Fires on prepare-commit-msg (pre-commit framework `commit-msg` stage)
# — runs against the staged commit message file. Detects:
#   - Subject contains `<type>(v<X.Y.Z>): ...` scope
#   - Compares the X.Y.Z against staged plugin.json.version (or
#     HEAD's plugin.json.version if not staged)
#   - If subject-version > manifest-version → fail
#
# Ignores:
#   - Non-version scopes (feat(skills): ..., chore: ..., etc.)
#   - Subjects without scope at all
#   - Versions that match or are below manifest
#
# Bypass: COMMIT_SUBJECT_VERSION_SKIP=1 (audit-logged to stderr).
# Use for genuinely pre-bump commits where the scope IS the
# operator's signal of intent before the manifest catches up.
#
# Exit codes:
#   0 — passed (scope-version <= manifest, or non-version scope,
#       or plugin.json absent, or bypass)
#   1 — failed (scope-version > manifest)
#   2 — precondition (jq missing, malformed plugin.json, missing
#       commit-msg-file arg)
#
# Usage: invoked by pre-commit framework as commit-msg stage with
# the path to the commit message file as $1.

if [ "${COMMIT_SUBJECT_VERSION_SKIP:-0}" = "1" ]; then
	echo "commit-subject-version-gate: COMMIT_SUBJECT_VERSION_SKIP=1 — passing through (audit logged)" >&2
	exit 0
fi

if [ "$#" -lt 1 ]; then
	echo "commit-subject-version-gate: expected commit-msg file as positional arg" >&2
	exit 2
fi
COMMIT_MSG_FILE=$1
if [ ! -f "$COMMIT_MSG_FILE" ]; then
	echo "commit-subject-version-gate: commit-msg file not found: $COMMIT_MSG_FILE" >&2
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "commit-subject-version-gate: jq required but not installed" >&2
	exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "commit-subject-version-gate: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT"

PLUGIN_JSON=".claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
	# Not a plugin repo — gate is a no-op.
	exit 0
fi
if ! jq empty "$PLUGIN_JSON" 2>/dev/null; then
	echo "commit-subject-version-gate: $PLUGIN_JSON is malformed JSON" >&2
	exit 2
fi

# Extract subject (first non-comment, non-empty line)
subject=$(grep -m1 -v '^#' "$COMMIT_MSG_FILE" 2>/dev/null | sed -n '/./{p;q;}' || printf '')
if [ -z "$subject" ]; then
	# Empty commit message — bypass (other gates will catch this)
	exit 0
fi

# Match scope of shape `<type>(v<X.Y.Z>): ...`
# Capture the X.Y.Z. The `type` part can be feat/fix/chore/etc.
subject_ver=$(printf '%s' "$subject" |
	sed -nE 's/^[a-z]+\(v([0-9]+\.[0-9]+\.[0-9]+)\).*/\1/p' | head -1)
if [ -z "$subject_ver" ]; then
	# No version scope — non-version commit, gate doesn't fire
	exit 0
fi

# Compare against current plugin.json version (prefer staged if
# present in the working tree; falls back to committed HEAD).
manifest_ver=$(jq -r '.version // ""' "$PLUGIN_JSON" 2>/dev/null || printf '')
if [ -z "$manifest_ver" ]; then
	echo "commit-subject-version-gate: $PLUGIN_JSON has no .version field" >&2
	exit 2
fi

# sort -V to compare (semver-aware)
higher=$(printf '%s\n%s\n' "$subject_ver" "$manifest_ver" | sort -V | tail -1)
if [ "$higher" = "$subject_ver" ] && [ "$subject_ver" != "$manifest_ver" ]; then
	echo "commit-subject-version-gate: FAIL — commit subject claims version $subject_ver but $PLUGIN_JSON is still at $manifest_ver" >&2
	echo "" >&2
	echo "Subject: $subject" >&2
	echo "" >&2
	echo "Fix: bump $PLUGIN_JSON to at least $subject_ver and re-stage with this commit." >&2
	echo "Or drop the version scope from the subject if this isn't a version-bump commit." >&2
	echo "Bypass (audit-logged): COMMIT_SUBJECT_VERSION_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
