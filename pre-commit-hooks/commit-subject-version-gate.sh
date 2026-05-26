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
#   - Subject contains `<type>(v<X.Y.Z>): ...` or `<type>(V<X.Y.Z>): ...`
#     scope (type + `v` prefix both case-insensitive — silently
#     skipping uppercase typos would defeat the gate's purpose;
#     breaking-change marker `!` tolerated per Conventional Commits).
#   - Compares X.Y.Z against the working-tree plugin.json.version
#     (the user is expected to have staged any intended manifest bump
#     before commit; sibling gate #87 catches the inverse mismatch
#     where hooks are added without bumping).
#   - If subject-version > manifest-version → fail
#
# Ignores:
#   - Non-version scopes (feat(skills): ..., chore: ..., etc.)
#   - Subjects without scope at all
#   - Versions that match or are below manifest
#
# Bypass: COMMIT_SUBJECT_VERSION_SKIP=1 (audit-trail to stderr only;
# no durable log file). Use for genuinely pre-bump commits where the
# scope IS the operator's signal of intent before the manifest catches
# up.
#
# Exit codes:
#   0 — passed (scope-version <= manifest, or non-version scope,
#       or plugin.json absent, or bypass)
#   1 — failed (scope-version > manifest)
#   2 — precondition (jq missing, malformed plugin.json, missing
#       commit-msg-file arg, manifest missing .version, repo-state
#       read failure)

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

# Resolve to absolute path BEFORE the cd below — otherwise a relative
# path silently fails to read after we change to REPO_ROOT (Phase 1 r2
# subdir-relative bypass bug). Use python's realpath as a portable
# fallback when `readlink -f` isn't available (BSD readlink on macOS).
COMMIT_MSG_FILE=$(cd "$(dirname "$COMMIT_MSG_FILE")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$COMMIT_MSG_FILE")") || {
	echo "commit-subject-version-gate: could not resolve absolute path for $1" >&2
	exit 2
}

if ! command -v jq >/dev/null 2>&1; then
	echo "commit-subject-version-gate: jq required but not installed" >&2
	exit 2
fi

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>&1); then
	echo "commit-subject-version-gate: git rev-parse failed: $REPO_ROOT" >&2
	exit 2
fi
cd "$REPO_ROOT"

PLUGIN_JSON=".claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
	# No plugin.json → not a plugin repo (see header exit-code 0).
	exit 0
fi
if ! jq_err=$(jq empty "$PLUGIN_JSON" 2>&1); then
	echo "commit-subject-version-gate: $PLUGIN_JSON failed jq validation: $jq_err" >&2
	exit 2
fi

# Extract subject: first line that is neither a comment (leading-`#`,
# optionally indented) nor blank. Atomic single-stage sed.
# Pre-r1 bug: `grep -m1 -v ^# | sed` consumed the blank line between
# preamble and subject, then sed saw only blank → empty subject →
# silent bypass on the canonical `git commit` editor flow.
if ! subject=$(sed -nE '/^[[:space:]]*[^#[:space:]]/{p;q;}' "$COMMIT_MSG_FILE"); then
	echo "commit-subject-version-gate: failed to read $COMMIT_MSG_FILE" >&2
	exit 2
fi
if [ -z "$subject" ]; then
	# Empty or comment-only — commit-template-check fires elsewhere.
	exit 0
fi

# Capture X.Y.Z from `<type>([vV]X.Y.Z): ...` (optional `!` marker).
# Use here-string instead of a printf pipe — sed's `q` early-closes
# stdin, which under set -euo pipefail SIGPIPEs the upstream printf
# and silently empties subject_ver (Phase 1 r2 SIGPIPE bypass bug).
subject_ver=$(sed -nE 's/^[A-Za-z]+\([vV]([0-9]+\.[0-9]+\.[0-9]+)\)!?:.*/\1/p' <<<"$subject")
if [ -z "$subject_ver" ]; then
	# No version scope — non-version commit, gate doesn't fire.
	exit 0
fi

# Read manifest version. jq validated above, so .version absence
# (or null) is the only realistic miss → empty → exit 2.
manifest_ver=$(jq -r '.version // ""' "$PLUGIN_JSON")
if [ -z "$manifest_ver" ]; then
	echo "commit-subject-version-gate: $PLUGIN_JSON has no usable .version field (missing or null)" >&2
	exit 2
fi
# Validate manifest .version matches the X.Y.Z shape we compare against.
# Without this, malformed values (numeric, '1.0', '1.0.0-rc1') would
# sort -V lexically against the captured subject ver, leading to
# silent wrong gate decisions. Reject early as a precondition.
if ! [[ $manifest_ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "commit-subject-version-gate: $PLUGIN_JSON .version='$manifest_ver' is not X.Y.Z — refusing to compare" >&2
	exit 2
fi

# sort -V for numeric version ordering (handles 0.10.0 > 0.9.5
# correctly, unlike lexicographic sort). Not full SemVer 2.0 —
# pre-release suffixes (e.g. -rc1) don't match the scope regex at
# all and silently pass the gate. We don't use them today; revisit
# if/when we do.
if ! higher=$(printf '%s\n%s\n' "$subject_ver" "$manifest_ver" | sort -V | tail -1); then
	echo "commit-subject-version-gate: version comparison failed — requires sort with version-sort support (GNU 'sort -V' or BSD 'sort --version-sort')" >&2
	exit 2
fi
# tail -1 of sort -V gives the highest version. If it equals
# subject_ver AND the two versions differ, subject is strictly
# greater than manifest.
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
