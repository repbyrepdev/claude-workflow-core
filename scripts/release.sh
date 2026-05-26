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
# Idempotent — re-running skips tag-create, cache-clone, and gh release
# create when each is already in place. (git push origin <tag> still runs
# unconditionally but is a no-op on the remote when the tag is already
# pushed.) Refuses to run if the working tree is dirty / untracked-not-
# clean (commit or stash first), or if the version in plugin.json is
# older than the latest existing tag.
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
		# Validate existence at parse time. Without this, a typo'd path
		# silently falls through to --generate-notes downstream (CR R1).
		if [ ! -f "$NOTES_FILE" ]; then
			echo "release.sh: --notes file '$NOTES_FILE' not found" >&2
			exit 2
		fi
		shift 2
		;;
	-h | --help)
		# Print every leading `# ` comment line in the header block, stop
		# at the first non-comment line after the `set -u` directives.
		# Skips the shebang. Future-proofs against the help block growing
		# or shrinking — no hardcoded line numbers to drift.
		awk '
			NR == 1 { next }                              # shebang
			/^set / { next }                              # set -euo pipefail
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }          # blank lines inside header
			in_header { exit }                            # first non-comment after header
		' "$0"
		exit 0
		;;
	*)
		echo "release.sh: unknown arg '$1'" >&2
		exit 2
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "release.sh: jq required but not installed" >&2
	exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "release.sh: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT"

# --- Precondition checks ---------------------------------------------

# 1. Working tree clean (tracked AND untracked — untracked files at release
# time are usually unintended state that shouldn't ship in the tag).
DIRTY=$(git status --porcelain 2>/dev/null)
if [ -n "$DIRTY" ]; then
	echo "release.sh: working tree has uncommitted or untracked changes — commit/stash/.gitignore before releasing:" >&2
	printf '%s\n' "$DIRTY" >&2
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

# 3. Version not regressing — compare to the latest existing tag.
# Fetch remote tags so the comparison uses the actual state of origin,
# not stale local refs. Capture rc — a fetch failure means we may be
# comparing against stale state, but that's recoverable; warn and
# proceed so offline release-rehearsal is still possible.
if ! git fetch --tags --quiet 2>&1; then
	echo "release.sh: WARNING git fetch --tags failed; comparing against local tags only" >&2
fi
LATEST_TAG=$(git tag -l 'v*' --sort=-v:refname 2>/dev/null | head -1 || true)
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
	# Peel to commit SHA via `^{}` — `git tag -a` creates annotated tags,
	# and `git rev-parse $TAG` returns the tag OBJECT sha (not the commit).
	# Without peeling, the comparison fails even when the tag is at HEAD.
	LOCAL_TAG_SHA=$(git rev-parse "$TAG^{}")
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

# Push tag to origin. `git push` of an already-pushed identical tag is a
# no-op on the remote, so this is safe to invoke unconditionally.
if [ "$DRY_RUN" = "1" ]; then
	echo "  [dry-run] would: git push origin $TAG"
else
	echo "  pushing tag $TAG to origin..."
	# Don't truncate via `| tail` — auth errors / non-fast-forward / hint
	# lines need to reach the operator. Surface full output, then exit 3.
	if ! git push origin "$TAG"; then
		echo "release.sh: git push origin $TAG failed (see above for details)" >&2
		exit 3
	fi
fi

# --- Plugin cache population -----------------------------------------
CACHE_BASE="$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core"
CACHE_DIR="$CACHE_BASE/$VERSION"
if [ -d "$CACHE_DIR" ]; then
	# Validate the existing cache actually corresponds to this tag — a
	# partial clone from a prior aborted run leaves an "exists" directory
	# that the next install consumes silently with the wrong content.
	# Skip validity check in --dry-run since the tag may not exist yet
	# locally (planning, not state coherence).
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] cache dir already at $CACHE_DIR (validity check skipped)"
	else
		if [ -d "$CACHE_DIR/.git" ]; then
			cached_sha=$(git -C "$CACHE_DIR" rev-parse HEAD 2>/dev/null || echo MISSING)
		else
			cached_sha=NO_GIT_DIR
		fi
		# Peel to commit SHA (see comment above re: annotated tag objects).
		expected_sha=$(git rev-parse "$TAG^{}" 2>/dev/null || echo MISSING)
		if [ "$cached_sha" != "$expected_sha" ] || [ "$cached_sha" = "MISSING" ]; then
			echo "release.sh: cache $CACHE_DIR exists but contains sha=$cached_sha (expected $expected_sha) — remove and re-run" >&2
			exit 2
		fi
		echo "  ✓ plugin cache already populated at $CACHE_DIR"
	fi
else
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would: git clone --branch $TAG --single-branch --depth 1 <origin> $CACHE_DIR"
	else
		echo "  populating plugin cache at $CACHE_DIR..."
		# Allow PLUGIN_REPO_URL override (matches bootstrap-machine.sh
		# behavior); fall back to current repo's origin if unset.
		if [ -z "${PLUGIN_REPO_URL:-}" ]; then
			if ! REMOTE_URL=$(git config --get remote.origin.url); then
				echo "release.sh: no remote.origin.url configured — set PLUGIN_REPO_URL or git remote add origin" >&2
				exit 2
			fi
		else
			REMOTE_URL="$PLUGIN_REPO_URL"
		fi
		if ! mkdir -p "$CACHE_BASE"; then
			echo "release.sh: failed to create $CACHE_BASE — check permissions" >&2
			exit 2
		fi
		# Atomic clone: clone to tmp UNDER $CACHE_BASE (same filesystem as
		# the final destination, so `mv` is actually a same-fs rename and
		# atomic) — not the default $TMPDIR (typically on a different fs
		# than $HOME, where mv would copy+unlink and lose atomicity).
		# Prevents partial cache from fooling the idempotency check on a
		# re-run after Ctrl-C.
		TMP_CLONE=$(mktemp -d "$CACHE_BASE/release-clone.XXXXXX") || {
			echo "release.sh: mktemp -d under $CACHE_BASE failed" >&2
			exit 2
		}
		# trap removes tmp on any exit path (success after mv leaves empty
		# parent; failure leaves the partial clone for debugging).
		trap '[ -d "$TMP_CLONE" ] && rm -rf "$TMP_CLONE"' EXIT
		if ! git clone --branch "$TAG" --single-branch --depth 1 "$REMOTE_URL" "$TMP_CLONE/clone"; then
			echo "release.sh: git clone failed (see above)" >&2
			exit 3
		fi
		mv "$TMP_CLONE/clone" "$CACHE_DIR"
	fi
fi

# --- GitHub release (optional) ---------------------------------------
if [ "$NO_GITHUB" = "1" ]; then
	echo "  ⊘ --no-github — skipping gh release create"
elif command -v gh >/dev/null 2>&1; then
	# Distinguish 'release not found' (expected, proceed to create) from
	# auth/network errors (must surface, don't fall through silently).
	release_exists=0
	view_err=$(gh release view "$TAG" 2>&1 >/dev/null) || {
		view_rc=$?
		if printf '%s' "$view_err" | grep -qi 'release not found\|not found'; then
			release_exists=0
		else
			echo "release.sh: gh release view failed (rc=$view_rc): $view_err" >&2
			exit 3
		fi
	}
	[ -z "$view_err" ] && release_exists=1
	if [ "$release_exists" = "1" ]; then
		echo "  ✓ GitHub release $TAG already exists"
	elif [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would: gh release create $TAG --title $TAG --notes-file ${NOTES_FILE:-<auto-generated>}"
	else
		echo "  creating GitHub release $TAG..."
		# Don't pipe through tail — auth/upload errors need to reach the
		# operator in full. NOTES_FILE existence already validated at parse
		# time (no silent fallback).
		if [ -n "$NOTES_FILE" ]; then
			gh_args=(--notes-file "$NOTES_FILE")
		else
			gh_args=(--generate-notes)
		fi
		if ! gh release create "$TAG" --title "$TAG" "${gh_args[@]}"; then
			echo "release.sh: gh release create $TAG failed — tag pushed and cache populated; re-run after fixing gh to finish" >&2
			exit 3
		fi
	fi
else
	echo "  ⊘ gh not installed — skipping GitHub release creation"
fi

echo "release.sh: $TAG release complete"
exit 0
