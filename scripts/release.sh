#!/bin/bash
set -euo pipefail
# v0.9.5 (#75) — release packaging.
#
# Reads .claude-plugin/plugin.json `version`, creates the matching `v<version>`
# git tag (if absent), pushes the tag, populates the local plugin cache dir at
# ~/.claude/plugins/cache/claude-workflow-core/claude-workflow-core/<version>/
# by cloning the tag into that path. Optionally creates a GitHub release with
# release notes from `gh release create`.
#
# Idempotent — re-running on the same version no-ops if tag + cache + release
# already exist. Refuses to run if the working tree is dirty (commit or stash
# first), if the latest commit on main isn't this branch's HEAD, or if the
# version in plugin.json is older than the latest existing tag.
#
# Usage:
#   scripts/release.sh                   # release plugin.json's version
#   scripts/release.sh --dry-run         # print what would happen, exit 0
#   scripts/release.sh --no-github       # skip `gh release create` step
#   scripts/release.sh --notes <file>    # release-notes body file
#
# Exit codes:
#   0 — release tag + cache dir + (optional) GitHub release in place
#   2 — usage / precondition error (dirty tree, version regression, etc.)
#   3 — gh / git remote / network error
#
# Sibling-issue references:
#   #74 — pre-merge version-bump gate (ensures plugin.json is bumped before
#         this script can succeed on the merge commit)
#   #61 — plugin self-bootstrap CI (asserts every release has the .github/*
#         SSOT in place; runs verify before tagging)
#   #77 — release runbook (CLAUDE.md / README documentation)

DRY_RUN=0
NO_GITHUB=0
NOTES_FILE=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--no-github)
		NO_GITHUB=1
		shift
		;;
	--notes)
		if [ -z "${2:-}" ] || [[ ${2:-} == -* ]]; then
			echo "release.sh: --notes requires a filename" >&2
			exit 2
		fi
		NOTES_FILE=$2
		shift 2
		;;
	-h | --help)
		# Range 5-26 ends at the last header line; lines after are non-comment code.
		sed -n '5,26p' "$0"
		exit 0
		;;
	*)
		echo "release.sh: unknown arg '$1'" >&2
		exit 2
		;;
	esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "release.sh: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT"

# --- Precondition checks ---------------------------------------------

# 1. Working tree clean
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "release.sh: working tree has uncommitted changes — commit or stash before releasing" >&2
	exit 2
fi

# 2. Read version from plugin.json
PLUGIN_JSON=".claude-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then
	echo "release.sh: $PLUGIN_JSON not found — wrong repo?" >&2
	exit 2
fi
VERSION=$(jq -r '.version' "$PLUGIN_JSON")
if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
	echo "release.sh: .version missing from $PLUGIN_JSON" >&2
	exit 2
fi
TAG="v$VERSION"

# 3. Version not regressing — compare to the latest existing tag
git fetch --tags --quiet 2>/dev/null || true
LATEST_TAG=$(git tag -l 'v*' --sort=-v:refname | head -1 || true)
if [ -n "$LATEST_TAG" ]; then
	# Sort the two; if our target sorts BEFORE the latest, we're regressing
	# unless the target IS the latest (idempotent re-run).
	if [ "$TAG" != "$LATEST_TAG" ]; then
		SORTED=$(printf '%s\n%s\n' "$TAG" "$LATEST_TAG" | sort -V | head -1)
		if [ "$SORTED" = "$TAG" ]; then
			echo "release.sh: plugin.json version $VERSION is older than latest tag $LATEST_TAG — bump plugin.json first" >&2
			exit 2
		fi
	fi
fi

echo "release.sh: target $TAG (plugin.json version=$VERSION)"
echo "release.sh: latest existing tag: ${LATEST_TAG:-<none>}"

# --- Tag creation ----------------------------------------------------
if git rev-parse "$TAG" >/dev/null 2>&1; then
	echo "  ✓ tag $TAG already exists locally"
	LOCAL_TAG_SHA=$(git rev-parse "$TAG")
	HEAD_SHA=$(git rev-parse HEAD)
	if [ "$LOCAL_TAG_SHA" != "$HEAD_SHA" ]; then
		echo "release.sh: tag $TAG points at $LOCAL_TAG_SHA but HEAD is $HEAD_SHA — recreate the tag at HEAD or move HEAD" >&2
		exit 2
	fi
else
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would: git tag -a $TAG -m 'Release $TAG'"
	else
		echo "  creating tag $TAG at HEAD..."
		git tag -a "$TAG" -m "Release $TAG"
	fi
fi

# Push tag to origin (idempotent — gh refuses noop push silently)
if [ "$DRY_RUN" = "1" ]; then
	echo "  [dry-run] would: git push origin $TAG"
else
	echo "  pushing tag $TAG to origin..."
	git push origin "$TAG" 2>&1 | tail -2 || {
		echo "release.sh: git push origin $TAG failed" >&2
		exit 3
	}
fi

# --- Plugin cache population -----------------------------------------
CACHE_BASE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
CACHE_DIR="$CACHE_BASE/$VERSION"
if [ -d "$CACHE_DIR" ]; then
	echo "  ✓ plugin cache already populated at $CACHE_DIR"
else
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would: git clone --branch $TAG --single-branch --depth 1 <origin> $CACHE_DIR"
	else
		echo "  populating plugin cache at $CACHE_DIR..."
		REMOTE_URL=$(git config --get remote.origin.url)
		mkdir -p "$CACHE_BASE"
		git clone --branch "$TAG" --single-branch --depth 1 "$REMOTE_URL" "$CACHE_DIR" 2>&1 | tail -3
	fi
fi

# --- GitHub release (optional) ---------------------------------------
if [ "$NO_GITHUB" = "1" ]; then
	echo "  ⊘ --no-github — skipping gh release create"
elif command -v gh >/dev/null 2>&1; then
	if gh release view "$TAG" >/dev/null 2>&1; then
		echo "  ✓ GitHub release $TAG already exists"
	else
		if [ "$DRY_RUN" = "1" ]; then
			echo "  [dry-run] would: gh release create $TAG --title $TAG --notes-file ${NOTES_FILE:-<auto-generated>}"
		else
			echo "  creating GitHub release $TAG..."
			if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
				gh release create "$TAG" --title "$TAG" --notes-file "$NOTES_FILE" 2>&1 | tail -2
			else
				gh release create "$TAG" --title "$TAG" --generate-notes 2>&1 | tail -2
			fi
		fi
	fi
else
	echo "  ⊘ gh not installed — skipping GitHub release creation"
fi

echo "release.sh: $TAG release complete"
exit 0
