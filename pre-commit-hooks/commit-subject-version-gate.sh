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
# Fires at the pre-commit framework `commit-msg` stage — runs against
# the in-progress commit message file passed as $1. Detects:
#   - Subject contains `<type>(v<X.Y.Z>): ...` scope (case-insensitive
#     type, optional `!` breaking-change marker tolerated)
#   - Compares the X.Y.Z against the working-tree plugin.json.version.
#     Under pre-commit framework, the working tree reflects the user's
#     intended commit state, so no separate staged/HEAD lookup is needed.
#   - If subject-version > manifest-version → fail
#
# Ignores:
#   - Non-version scopes (feat(skills): ..., chore: ..., etc.)
#   - Subjects without scope at all
#   - Versions that match or are below manifest
#
# Bypass: COMMIT_SUBJECT_VERSION_SKIP=1 (audit-trail to stderr only;
# no durable log file today). Use for genuinely pre-bump commits where
# the scope IS the operator's signal of intent before the manifest
# catches up.
#
# Exit codes:
#   0 — passed (scope-version <= manifest, or non-version scope,
#       or plugin.json absent, or bypass)
#   1 — failed (scope-version > manifest)
#   2 — precondition (jq missing, malformed plugin.json, missing
#       commit-msg-file arg, manifest missing .version)

if [ "${COMMIT_SUBJECT_VERSION_SKIP:-0}" = "1" ]; then
	echo "commit-subject-version-gate: COMMIT_SUBJECT_VERSION_SKIP=1 — passing through (stderr-only audit trail)" >&2
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
	# No plugin.json → not a plugin repo, gate does not apply (exit 0
	# per header contract).
	exit 0
fi
if ! jq empty "$PLUGIN_JSON" 2>/dev/null; then
	echo "commit-subject-version-gate: $PLUGIN_JSON is malformed JSON" >&2
	exit 2
fi

# Extract subject: first line that is neither a comment (leading-`#`,
# optionally indented) nor blank. Atomic single-stage sed avoids the
# `grep -m1 | sed` blank-line silent-bypass bug (a blank line between
# comment preamble and the real subject would otherwise consume the
# match and silently bypass the gate).
subject=$(sed -nE '/^[[:space:]]*[^#[:space:]]/{p;q;}' "$COMMIT_MSG_FILE" || printf '')
if [ -z "$subject" ]; then
	# Empty or comment-only commit message — commit-template-check.sh
	# enforces non-empty subjects elsewhere; this gate stays silent.
	exit 0
fi

# Capture X.Y.Z from `<type>(vX.Y.Z): ...` or `<type>(vX.Y.Z)!: ...`
# (type case-insensitive — silently skipping uppercase types would
# defeat the gate's purpose; breaking-change marker `!` tolerated per
# Conventional Commits 1.0.0).
subject_ver=$(printf '%s' "$subject" |
	sed -nE 's/^[A-Za-z]+\(v([0-9]+\.[0-9]+\.[0-9]+)\)!?:.*/\1/p;q' || printf '')
if [ -z "$subject_ver" ]; then
	# No version scope — non-version commit, gate doesn't fire
	exit 0
fi

# Read manifest version from the working-tree plugin.json. Under
# pre-commit framework the working tree reflects the intended commit
# (staged files have been written out), so no separate staged/HEAD
# lookup is needed.
manifest_ver=$(jq -r '.version // ""' "$PLUGIN_JSON")
if [ -z "$manifest_ver" ]; then
	echo "commit-subject-version-gate: $PLUGIN_JSON has no .version field" >&2
	exit 2
fi

# Use sort -V for numeric version ordering (handles 0.10.0 > 0.9.5
# correctly, unlike lexicographic sort). Not full SemVer 2.0 —
# pre-release suffixes (e.g. -rc1) may not order per the spec; we
# don't use them today, and the regex only captures the numeric
# X.Y.Z portion anyway.
higher=$(printf '%s\n%s\n' "$subject_ver" "$manifest_ver" | sort -V | tail -1)
# subject_ver wins sort -V tie-break AND the two strings differ →
# subject is strictly greater than manifest.
if [ "$higher" = "$subject_ver" ] && [ "$subject_ver" != "$manifest_ver" ]; then
	echo "commit-subject-version-gate: FAIL — commit subject claims version $subject_ver but $PLUGIN_JSON is still at $manifest_ver" >&2
	echo "" >&2
	echo "Subject: $subject" >&2
	echo "" >&2
	echo "Fix: bump $PLUGIN_JSON to at least $subject_ver and re-stage with this commit." >&2
	echo "Or drop the version scope from the subject if this isn't a version-bump commit." >&2
	echo "Bypass (stderr-only audit): COMMIT_SUBJECT_VERSION_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
