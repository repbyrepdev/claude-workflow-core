#!/bin/bash
set -euo pipefail
# event: none
# auto-register: false
# v0.18.0 (#139) — one-shot tag-backfill for plugin.json versions that
# merged to main without a corresponding git tag.
#
# Root cause: between v0.8.8 (last good release) and this script's first
# run, the `.git/hooks/post-merge` wrapper was not installed in the plugin
# repo. About a dozen version bumps (v0.9.x → v0.17.0, mixed minor + patch)
# landed in main with no `git tag`, no `scripts/release.sh` invocation, no
# plugin-cache directory for any of those versions. Consumers stuck on
# v0.8.5/v0.8.8.
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
# version with one of these status values:
#   created            — tag created (and pushed unless --skip-push;
#                        release.sh ran unless --skip-release)
#   skipped-exists     — tag already present at the expected sha; no-op
#   dry-run            — --dry-run mode; would have created
#   failed-tag-create  — `git tag` failed (e.g., signing/perms)
#   failed-tag-push    — `git push origin <tag>` failed (network/auth)
#   failed-worktree-add — `git worktree add` failed
#   failed-release     — release.sh non-zero inside the worktree
# Each record carries a `schema_version` field (currently 1) so downstream
# consumers can detect format evolution.
#
# Exit codes:
#   0 — all versions handled (or --dry-run)
#   1 — at least one version failed (continued past failures; log has detail)
#   2 — precondition error (not a plugin repo, jq missing, git not init,
#       scripts/release.sh missing without --skip-release, --since does
#       not resolve to a valid ref)

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

# Worktree cleanup registry — populated as we mktemp each worktree. The
# EXIT trap below fires on every termination path (success, error,
# signal) so a Ctrl-C mid-release.sh doesn't leak `.git/worktrees/` +
# `/tmp/backfill-tags.*` entries. silent-failure-hunter #139 r1 CRIT:
# earlier draft referenced this array without declaring it AND promised
# an EXIT trap in comments without installing one.
WORKTREES_TO_CLEAN=()
# shellcheck disable=SC2329,SC2317  # invoked via trap (EXIT INT TERM) below
_cleanup_worktrees() {
	local wt
	for wt in "${WORKTREES_TO_CLEAN[@]:-}"; do
		if [ -z "$wt" ] || [ ! -d "$wt" ]; then
			continue
		fi
		git worktree remove --force "$wt" 2>/dev/null || true
		rm -rf "$wt" 2>/dev/null || true
	done
	# Prune orphan administrative entries that may remain if a worktree
	# was rm-rf'd while git still held a .git/worktrees/<name>/ stub.
	git worktree prune 2>/dev/null || true
}
trap _cleanup_worktrees EXIT INT TERM

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

echo "backfill-tags: walking ${RANGE_ARG[*]} on first-parent ancestors of HEAD..."

# Collect "version sha" pairs in chronological order (oldest first).
PAIRS=()
prev_version=""
# git log gives commits newest-first; reverse via `git log --reverse`.
# NOTE: we walk first-parent ancestors of HEAD (NOT specifically `main`).
# Callers should invoke this from a checkout where HEAD is the canonical
# release line — typically `main`. The header documents this assumption.
while read -r sha; do
	# Read plugin.json.version at this sha. Use `git show` rather than
	# `git checkout` to avoid moving HEAD.
	#
	# Two silent-failure modes to guard (silent-failure-hunter #139 r1 CRIT):
	#   1. `git show` fails (file missing at sha) → skip silently — legit.
	#   2. `jq -r '.version'` on null/missing returns the STRING "null" →
	#      we'd build `tag="vnull"` and create it on github. Use
	#      `jq -er '.version | select(. != null) | strings'` so null
	#      and non-string types produce a non-zero rc → caught + skipped
	#      with a stderr WARN.
	if ! plugin_raw=$(git show "$sha:.claude-plugin/plugin.json" 2>/dev/null); then
		continue
	fi
	if ! version=$(printf '%s' "$plugin_raw" | jq -er '.version | select(. != null) | strings' 2>/dev/null); then
		echo "backfill-tags: WARN: sha ${sha:0:7} has plugin.json but .version is missing/null/non-string — skipping" >&2
		continue
	fi
	# Semver guard — parity with post-merge-release-fire.sh: refuse
	# anything that's not X.Y.Z (any of the rejected shapes would create
	# a garbage tag).
	if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "backfill-tags: WARN: sha ${sha:0:7} has plugin.json .version '$version' (not X.Y.Z semver) — skipping" >&2
		continue
	fi
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
		jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
			--arg status "skipped-exists" --arg dry "$DRY_RUN" \
			'{ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:($dry=="1")}' \
			>>"$LOG_FILE" 2>/dev/null || true
		skipped=$((skipped + 1))
		continue
	fi

	if [ "$DRY_RUN" = "1" ]; then
		echo "  + $tag at ${sha:0:7} (dry-run)"
		jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
			--arg status "dry-run" \
			'{schema_version:$schema, ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:true}' \
			>>"$LOG_FILE" 2>/dev/null || true
		continue
	fi

	echo "  + tagging $tag at ${sha:0:7}"
	if ! git tag -a "$tag" "$sha" -m "$tag (backfilled — pre-#139 release-pipeline repair)" 2>&1; then
		echo "  ✗ git tag failed for $tag" >&2
		jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
			--arg status "failed-tag-create" \
			'{schema_version:$schema, ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
			>>"$LOG_FILE" 2>/dev/null || true
		failures=$((failures + 1))
		continue
	fi

	if [ "$SKIP_PUSH" = "0" ]; then
		if ! git push origin "$tag" 2>&1; then
			echo "  ✗ git push failed for $tag (tagged locally)" >&2
			jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
				--arg status "failed-tag-push" \
				'{schema_version:$schema, ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
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
		#
		# Cleanup contract: every code path out of this block — success,
		# worktree-add failure, release.sh failure — MUST remove $WT.
		# Earlier draft used a RETURN trap; code-reviewer #139 r1 caught
		# that RETURN traps only fire on FUNCTION return, not script-level
		# `continue`. We now do explicit cleanup at every exit point and
		# also register $WT into a script-EXIT cleanup list as belt-and-
		# suspenders against unhandled aborts.
		WT=$(mktemp -d -t backfill-tags.XXXXXX)
		WORKTREES_TO_CLEAN+=("$WT")
		if ! git worktree add --detach "$WT" "$sha" 2>&1; then
			echo "  ✗ git worktree add failed for $tag" >&2
			rm -rf "$WT" 2>/dev/null || true
			jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
				--arg status "failed-worktree-add" \
				'{schema_version:$schema, ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
				>>"$LOG_FILE" 2>/dev/null || true
			failures=$((failures + 1))
			continue
		fi
		release_rc=0
		(
			cd "$WT" || exit 1
			"$RELEASE_SH" 2>&1
		) || release_rc=$?
		# Cleanup BEFORE branching on rc so success + failure paths both
		# leave $WT removed. `git worktree remove --force` may fail if
		# the worktree was already partially-removed; rm -rf is the
		# stronger fallback.
		git worktree remove --force "$WT" 2>/dev/null || true
		rm -rf "$WT" 2>/dev/null || true
		if [ "$release_rc" -ne 0 ]; then
			echo "  ✗ release.sh failed (rc=$release_rc) for $tag" >&2
			jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
				--arg status "failed-release" \
				'{schema_version:$schema, ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
				>>"$LOG_FILE" 2>/dev/null || true
			failures=$((failures + 1))
			continue
		fi
	fi

	jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ver "$version" --arg sha "$sha" --argjson schema 1 \
		--arg status "created" \
		'{schema_version:$schema, ts:$ts, version:$ver, sha:$sha, status:$status, dry_run:false}' \
		>>"$LOG_FILE" 2>/dev/null || true
	created=$((created + 1))
done

echo
echo "backfill-tags: summary — created=$created skipped=$skipped failed=$failures"
[ "$failures" -gt 0 ] && exit 1
exit 0
