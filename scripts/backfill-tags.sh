#!/bin/bash
set -euo pipefail
# event: none
# auto-register: false
# v0.18.0 (#139) — one-shot tag-backfill for plugin.json versions that
# merged to main without a corresponding git tag.
#
# Root cause: between v0.8.8 (last good release) and this script's first
# run, the `.git/hooks/post-merge` wrapper was not installed in the plugin
# repo. Eight minor version bumps (v0.9 → v0.17) landed in main with no
# `git tag`, no `scripts/release.sh` invocation, no plugin-cache directory
# for any of those versions. Consumers stuck on v0.8.5/v0.8.8.
#
# This script walks `git log main` for every `.claude-plugin/plugin.json`
# version change. For each (version, sha) pair where `v<version>` is NOT
# already a tag, creates an annotated tag AT THAT SHA, then defers cache
# packaging to `scripts/release.sh` (one invocation per tag).
#
# Idempotent — re-running skips any version whose tag already exists.
#
# Usage:
#   scripts/backfill-tags.sh                    # apply
#   scripts/backfill-tags.sh --dry-run          # report what would happen
#   scripts/backfill-tags.sh --since v0.8.8     # explicit lower bound
#   scripts/backfill-tags.sh --skip-push        # tag locally, don't push
#   scripts/backfill-tags.sh --skip-release     # tag only; skip release.sh
#   scripts/backfill-tags.sh --help
#
# Audit log: .claude/logs/release-backfill.jsonl (one line per attempted
# version with status: created | skipped-exists | skipped-error).
#
# Exit codes:
#   0 — all versions handled (or --dry-run)
#   1 — at least one version failed (continued past failures; log has detail)
#   2 — precondition error (not a plugin repo, jq missing, git not init)

DRY_RUN=0
SINCE_TAG=""
SKIP_PUSH=0
SKIP_RELEASE=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--since)
		[ "$#" -ge 2 ] || {
			echo "backfill-tags: --since requires a value" >&2
			exit 2
		}
		SINCE_TAG=$2
		shift 2
		;;
	--skip-push)
		SKIP_PUSH=1
		shift
		;;
	--skip-release)
		SKIP_RELEASE=1
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
	*)
		echo "backfill-tags: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

# Preconditions.
[ -f .claude-plugin/plugin.json ] || {
	echo "backfill-tags: not in a plugin repo (no .claude-plugin/plugin.json)" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	echo "backfill-tags: jq required" >&2
	exit 2
}
[ -d .git ] || {
	echo "backfill-tags: .git missing" >&2
	exit 2
}

RELEASE_SH="$SCRIPT_DIR/release.sh"
if [ "$SKIP_RELEASE" = "0" ] && [ ! -x "$RELEASE_SH" ]; then
	echo "backfill-tags: $RELEASE_SH missing or non-exec — use --skip-release to tag only" >&2
	exit 2
fi

LOG_DIR="$REPO_ROOT/.claude/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/release-backfill.jsonl"

# Default --since to the latest existing v* tag so we don't recompute
# history every run. Operator can override.
if [ -z "$SINCE_TAG" ]; then
	SINCE_TAG=$(git tag --list 'v*' --sort=-version:refname | head -1 || true)
fi
if [ -n "$SINCE_TAG" ] && ! git rev-parse -q --verify "$SINCE_TAG" >/dev/null 2>&1; then
	echo "backfill-tags: --since $SINCE_TAG is not a valid ref" >&2
	exit 2
fi

# Walk first-parent main history; for each commit, capture the
# plugin.json.version at that revision. Group consecutive identical
# versions, keep only the FIRST commit where each version first appears.
# That's the commit we tag.
RANGE_ARG=()
if [ -n "$SINCE_TAG" ]; then
	RANGE_ARG=("${SINCE_TAG}..HEAD")
else
	RANGE_ARG=("HEAD")
fi

echo "backfill-tags: walking ${RANGE_ARG[*]} on first-parent main..."

# Collect "version sha" pairs in chronological order (oldest first).
PAIRS=()
prev_version=""
# git log gives commits newest-first; reverse via tac (gnu) or `git log --reverse`.
while read -r sha; do
	# Read plugin.json.version at this sha. Use `git show` rather than `git
	# checkout` to avoid moving HEAD.
	version=$(git show "$sha:.claude-plugin/plugin.json" 2>/dev/null | jq -r '.version' 2>/dev/null || echo "")
	[ -n "$version" ] || continue
	if [ "$version" != "$prev_version" ]; then
		PAIRS+=("$version $sha")
		prev_version=$version
	fi
done < <(git log --reverse --first-parent --format='%H' "${RANGE_ARG[@]}" -- .claude-plugin/plugin.json)

echo "backfill-tags: found ${#PAIRS[@]} version transition(s) since ${SINCE_TAG:-(genesis)}"

failures=0
created=0
skipped=0

# set -u + empty array dereference would unbound-fail on bash <4.4. Guard
# the loop with explicit count check before iterating.
if [ "${#PAIRS[@]}" -eq 0 ]; then
	echo "backfill-tags: nothing to do (no version transitions since ${SINCE_TAG:-(genesis)})"
	exit 0
fi

for pair in "${PAIRS[@]}"; do
	version=${pair%% *}
	sha=${pair##* }
	tag="v$version"

	if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
		echo "  ⊙ $tag already exists at $(git rev-parse --short "$tag") — skipping"
		jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" \
			--arg status "skipped-exists" --arg dry "$DRY_RUN" \
			'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:($dry=="1")}' \
			>>"$LOG_FILE" 2>/dev/null || true
		skipped=$((skipped + 1))
		continue
	fi

	if [ "$DRY_RUN" = "1" ]; then
		echo "  + $tag at ${sha:0:7} (dry-run)"
		jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" \
			--arg status "dry-run" \
			'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:true}' \
			>>"$LOG_FILE" 2>/dev/null || true
		continue
	fi

	echo "  + tagging $tag at ${sha:0:7}"
	if ! git tag -a "$tag" "$sha" -m "$tag (backfilled — pre-#139 release-pipeline repair)" 2>&1; then
		echo "  ✗ git tag failed for $tag" >&2
		jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" \
			--arg status "failed-tag-create" \
			'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
			>>"$LOG_FILE" 2>/dev/null || true
		failures=$((failures + 1))
		continue
	fi

	if [ "$SKIP_PUSH" = "0" ]; then
		if ! git push origin "$tag" 2>&1; then
			echo "  ✗ git push failed for $tag (tagged locally)" >&2
			jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" \
				--arg status "failed-tag-push" \
				'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
				>>"$LOG_FILE" 2>/dev/null || true
			failures=$((failures + 1))
			continue
		fi
	fi

	if [ "$SKIP_RELEASE" = "0" ]; then
		# release.sh reads plugin.json's current version, not the tag
		# we just created. Run it from a worktree checked out at $sha
		# so it sees the right manifest. Use git worktree (cleaner than
		# stashing main).
		WT=$(mktemp -d -t backfill-tags.XXXXXX)
		# shellcheck disable=SC2064  # expand $WT now (trap is single-shot per loop)
		trap "git worktree remove --force '$WT' 2>/dev/null || true; rm -rf '$WT' 2>/dev/null || true" RETURN
		if ! git worktree add --detach "$WT" "$sha" 2>&1; then
			echo "  ✗ git worktree add failed for $tag" >&2
			failures=$((failures + 1))
			continue
		fi
		(
			cd "$WT" || exit 1
			"$RELEASE_SH" 2>&1
		) || {
			echo "  ✗ release.sh failed for $tag (worktree at $WT)" >&2
			jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" \
				--arg status "failed-release" \
				'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
				>>"$LOG_FILE" 2>/dev/null || true
			git worktree remove --force "$WT" 2>/dev/null || true
			rm -rf "$WT" 2>/dev/null || true
			trap - RETURN
			failures=$((failures + 1))
			continue
		}
		git worktree remove --force "$WT" 2>/dev/null || true
		rm -rf "$WT" 2>/dev/null || true
		trap - RETURN
	fi

	jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" \
		--arg status "created" \
		'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
		>>"$LOG_FILE" 2>/dev/null || true
	created=$((created + 1))
done

echo
echo "backfill-tags: summary — created=$created skipped=$skipped failed=$failures"
[ "$failures" -gt 0 ] && exit 1
exit 0
