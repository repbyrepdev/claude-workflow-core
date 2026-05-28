#!/bin/bash
set -euo pipefail
# v4.20 (#519): github-pr-merge skill wrapper.
# Validates required checks, resolves stranded CR threads, requires explicit
# user gate, merges, and optionally auto-tags + invokes auto-release.sh.
# Sets SKILL_WRAPPER=1 so skill-bypass-guard allows gh pr merge.
#
# Usage:
#   .claude/skills/github-pr-merge/run.sh --pr <num> \
#     [--squash|--merge|--rebase] [--delete-branch] [--tag vX.Y.Z]
#
# Defaults: --squash --delete-branch.
# If --tag is provided, runs auto-release.sh after merge (respecting
# ACTIONS_MODE guard via auto-release.sh's own check).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# v0.6.7 (#15): REPO_ROOT via git rev-parse (works whether the wrapper
# lives in consumer .claude/skills/<name>/ or in plugin-cache
# <cache>/skills/<name>/). Fallback to SCRIPT_DIR ancestor for the
# legacy in-repo invocation path. `{ ... ; }` grouping avoids the
# v0.6.5 precedence bug (newline-corrupted REPO_ROOT).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# skill-common.sh sits next to this wrapper in BOTH the consumer
# (.claude/skills/_lib/) and the plugin cache (<cache>/skills/_lib/) —
# relative-to-SCRIPT_DIR resolves either way.
# shellcheck source=../_lib/skill-common.sh
source "$SCRIPT_DIR/../_lib/skill-common.sh"

PR=""
METHOD="--squash"
DELETE_BRANCH=1
TAG=""

while [ $# -gt 0 ]; do
	case "$1" in
	--pr)
		[ $# -ge 2 ] || {
			echo "error: --pr requires a value" >&2
			exit 2
		}
		PR="$2"
		shift 2
		;;
	--squash | --merge | --rebase)
		METHOD="$1"
		shift
		;;
	--delete-branch)
		DELETE_BRANCH=1
		shift
		;;
	--no-delete-branch)
		DELETE_BRANCH=0
		shift
		;;
	--tag)
		[ $# -ge 2 ] || {
			echo "error: --tag requires a value" >&2
			exit 2
		}
		TAG="$2"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ -z "$PR" ] || ! [[ $PR =~ ^[0-9]+$ ]]; then
	echo "Usage: $0 --pr <num> [--squash|--merge|--rebase] [--delete-branch|--no-delete-branch] [--tag vX.Y.Z]" >&2
	exit 2
fi

# Pre-merge state check.
STATE=$(gh pr view "$PR" --json state,mergeable,mergeStateStatus,statusCheckRollup \
	--jq '{state: .state, mergeable: .mergeable, mergeStateStatus: .mergeStateStatus, checks: [(.statusCheckRollup // [])[] | {context: .context, state: .state}]}')
echo "=== Pre-merge state for PR #$PR ==="
printf '%s\n' "$STATE" | jq .

# Bail if not mergeable. Note: UNKNOWN (GitHub still computing mergeable
# state) is treated the same as CONFLICTING here — if you hit UNKNOWN
# repeatedly, re-run after ~30s so GH's background job finishes.
mergeable=$(printf '%s' "$STATE" | jq -r .mergeable)
if [ "$mergeable" != "MERGEABLE" ]; then
	echo "PR #$PR is not mergeable (mergeable=$mergeable) — refusing" >&2
	exit 2
fi

# Warn on failing checks. Distinguish PENDING/IN_PROGRESS from FAILURE.
FAILED_JSON=$(printf '%s' "$STATE" | jq -c '[.checks[] | select(.state == "FAILURE" or .state == "ERROR" or .state == "CANCELLED" or .state == "TIMED_OUT")]')
PENDING_JSON=$(printf '%s' "$STATE" | jq -c '[.checks[] | select(.state == "PENDING" or .state == "IN_PROGRESS" or .state == "QUEUED")]')
failed_count=$(printf '%s' "$FAILED_JSON" | jq 'length')
pending_count=$(printf '%s' "$PENDING_JSON" | jq 'length')
if [ "$failed_count" != "0" ]; then
	echo "⚠ $failed_count FAILED check(s):" >&2
	printf '%s' "$FAILED_JSON" | jq -r '.[] | "    - " + .context + " (" + .state + ")"' >&2
	# In non-interactive APPROVE=1 mode, refuse to merge over failures —
	# the whole point of the wrapper is to be a safer merge gate.
	if [ "${APPROVE:-0}" = "1" ] && [ ! -t 0 ]; then
		echo "Refusing to merge over FAILED checks in non-interactive APPROVE=1 mode." >&2
		exit 2
	fi
fi
if [ "$pending_count" != "0" ]; then
	echo "ℹ $pending_count check(s) still running (PENDING/IN_PROGRESS):" >&2
	printf '%s' "$PENDING_JSON" | jq -r '.[] | "    - " + .context' >&2
fi

# Stranded-thread check (isResolved=false + isOutdated=true means CR
# flagged something that's now been fixed but not marked resolved).
OWNER_NAME=$(skc_repo_owner_name)
OWNER="${OWNER_NAME%/*}"
NAME="${OWNER_NAME#*/}"
if ! STRANDED=$(gh api graphql -f query="query { repository(owner: \"$OWNER\", name: \"$NAME\") { pullRequest(number: $PR) { reviewThreads(first: 100) { nodes { isResolved isOutdated } } } } }" \
	--jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == true)] | length' 2>&1); then
	echo "⚠ stranded-thread query failed: $STRANDED" >&2
	echo "  Cannot verify PR #$PR is clear of unresolved CR threads — investigate before merge." >&2
	# Non-interactive APPROVE=1: refuse rather than merge-in-the-dark (matches FAILED-check gate posture above).
	if [ "${APPROVE:-0}" = "1" ] && [ ! -t 0 ]; then
		echo "Refusing to merge when stranded-thread check couldn't run in non-interactive APPROVE=1 mode." >&2
		exit 2
	fi
elif [ "$STRANDED" != "0" ]; then
	echo "⚠ $STRANDED stranded review thread(s) (isResolved=false + isOutdated=true) — consider resolving via GraphQL before merge" >&2
fi

echo ""
skc_approve_or_exit "Merge PR #$PR ($METHOD)?"

# Merge.
MERGE_ARGS=(pr merge "$PR" "$METHOD")
[ "$DELETE_BRANCH" = "1" ] && MERGE_ARGS+=(--delete-branch)
# Capture branch HEAD sha BEFORE merge (branch may be deleted by --delete-branch).
BRANCH_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || true)

SKILL_WRAPPER=1 gh "${MERGE_ARGS[@]}"
echo "✓ Merged PR #$PR ($METHOD)"

# v0.27.0 #173 Layer 2: clear phase1-directive marker for the merged
# branch HEAD sha. Without this, the marker stays orphaned until either
# Layer 1 (phase1-directive-pending-guard self-heal) or Layer 3 (post-
# merge git hook) catches it. Belt-and-suspenders: catch at the source.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
MARKER_DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
if [ -n "$BRANCH_HEAD_SHA" ] && [ -f "$MARKER_DIR/$BRANCH_HEAD_SHA.phase1-directive.txt" ]; then
	rm -f "$MARKER_DIR/$BRANCH_HEAD_SHA.phase1-directive.txt"
	echo "  cleaned phase1-directive marker for $BRANCH_HEAD_SHA (merged via this skill)"
fi

# Resolve the exact merge-commit SHA via the GitHub API BEFORE any local
# fetch/pull that could move origin/main. This guarantees the tag (if
# --tag was passed) references the PR's actual mergeCommit.oid, not some
# later commit that landed on main between our fetch and rev-parse.
MERGE_SHA=$(gh pr view "$PR" --json mergeCommit --jq '.mergeCommit.oid' 2>&1)
if [ -z "$MERGE_SHA" ] || [ "$MERGE_SHA" = "null" ]; then
	echo "Could not resolve merge commit SHA for PR #$PR (gh returned: $MERGE_SHA)" >&2
	exit 2
fi

# Post-merge pull — fail loud, don't silently skip. A stale local main
# would break Step 11 (post-merge deploy) by recreating pre-merge state.
git fetch origin main --quiet
if ! git_out=$(git checkout main 2>&1); then
	echo "⚠ git checkout main failed: $git_out" >&2
	echo "  Merge succeeded remotely; fix local worktree before deploy." >&2
	exit 2
fi
if ! git_out=$(git pull --ff-only 2>&1); then
	echo "⚠ git pull --ff-only failed: $git_out" >&2
	echo "  Local main behind or diverged — resolve before deploy." >&2
	exit 2
fi

# v4.21 wire-in: trivy-post-merge. Script itself decides whether to scan
# (it diffs the merge range for image-pin changes in stacks/**/compose.yaml
# — no-ops if none). Warn-only, doesn't block — trivy findings are advisory
# (can't fix upstream CVEs) and may open a follow-up issue if found.
TRIVY_PM="$REPO_ROOT/.claude/hooks/trivy-post-merge.sh"
if [ -x "$TRIVY_PM" ]; then
	echo "=== Post-merge trivy scan (no-op if no compose image pins changed) ==="
	# trivy-post-merge.sh exits 0 on both clean scans AND CVE-found-advisory-
	# filed. Non-zero here means pure tooling failure (scan couldn't run,
	# jq/docker missing, etc.) — surface the rc to separate that from the
	# expected advisory paths. Use `|| rc=$?` form so `set -e` at the top
	# of this script doesn't abort the wrapper on non-zero before we can
	# warn and move on (this block must be warn-only per "not blocking
	# merge"). Pre-initialize `rc=0` because `set -u` is on and rc is
	# only assigned by `|| rc=$?` on the failure branch.
	rc=0
	"$TRIVY_PM" "$MERGE_SHA~1" 2>&1 || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "⚠ trivy-post-merge exited $rc — check output above. Not blocking merge." >&2
	fi
fi

# v4.21 wire-in: auto-close-parent for any sub-issues this PR's merge-commit
# closed via "Closes #N" trailers. Fires recursively for nested epic chains.
# Script is idempotent (no-ops if parent already closed or has open subs).
AUTO_CLOSE="$REPO_ROOT/.claude/hooks/auto-close-parent.sh"
if [ -x "$AUTO_CLOSE" ]; then
	# Extract "Closes #N" (case-insensitive, also "Closed", "Close", "Fixes",
	# "Fixed", "Fix", "Resolves", "Resolved", "Resolve") from the merge commit
	# message. gh's issue-linking uses this exact keyword set.
	# Capture git-log stderr loudly — a MERGE_SHA that doesn't resolve
	# (race, rebase, corrupt ref) would otherwise make closed_nums empty
	# and the whole stanza silently no-op; operator would assume "no sub-
	# issues to close" when git-log actually failed.
	if ! commit_body=$(git log -1 --format=%B "$MERGE_SHA" 2>&1); then
		echo "⚠ git log failed on $MERGE_SHA: $commit_body" >&2
		echo "  Skipping auto-close-parent — check if merge commit is visible locally." >&2
	else
		# `|| true` required because `set -eo pipefail` aborts the wrapper
		# when the first grep produces no matches (exit 1). A merge commit
		# with no Closes/Fixes/Resolves trailers is a legitimate case
		# (refactor PR, doc-only) — it must yield empty closed_nums, not
		# abort. Phase 2 CR caught this; Phase 1 silent-failure-hunter
		# missed it because the empty-body bats test didn't set pipefail.
		closed_nums=$(printf '%s\n' "$commit_body" |
			grep -oiE '(close[sd]?|fix(es|ed)?|resolve[sd]?)[[:space:]]+#[0-9]+' |
			grep -oE '[0-9]+' | sort -u || true)
		if [ -n "$closed_nums" ]; then
			count=$(printf '%s\n' "$closed_nums" | grep -c .)
			echo "=== Checking epic parent auto-close for $count closed sub-issue(s) ==="
			# `|| rc=$?` form so `set -e` doesn't abort the wrapper when a
			# single auto-close fails — warn and continue with the next
			# sub-issue in the loop. `if ! cmd; then rc=$?` would report
			# rc=0 (negated-test clobber); plain `cmd; rc=$?` would abort
			# under set -e before the assignment runs. Both avoided here.
			for n in $closed_nums; do
				rc=0
				"$AUTO_CLOSE" "$n" 2>&1 || rc=$?
				if [ "$rc" -ne 0 ]; then
					echo "⚠ auto-close-parent exited $rc on #$n — check parent epic state manually." >&2
				fi
			done
		fi
	fi
fi

# v4.24-C (#568) wire-in: post-merge-deploy chain when the PR touched
# stacks/**/compose.yaml or config/**. Prior state was honor-system —
# SKILL.md Step 8 told the operator to recreate stacks manually, which
# the `feedback_merge_is_not_deploy` memory repeatedly caught getting
# skipped. This makes the recreate+verify+e2e chain automatic.
POST_MERGE_DEPLOY="$REPO_ROOT/.claude/scripts/deploy/post-merge-deploy.sh"
if [ -x "$POST_MERGE_DEPLOY" ]; then
	# Detect compose / config changes in the merge range.
	# Capture stderr so `git diff` failures (bad MERGE_SHA, shallow clone)
	# surface as warnings instead of silently skipping the deploy chain.
	if ! deploy_touched_raw=$(git diff --name-only "${MERGE_SHA}~1" "$MERGE_SHA" -- \
		'stacks/**/compose.yaml' 'config/**' 2>&1); then
		echo "⚠ git diff failed computing deploy-touched files: $deploy_touched_raw" >&2
		echo "  Skipping auto post-merge-deploy — run manually if compose/config changed." >&2
		deploy_touched=""
	else
		deploy_touched=$(printf '%s\n' "$deploy_touched_raw" | head -1)
	fi
	if [ -n "$deploy_touched" ]; then
		echo "=== Post-merge deploy chain (compose/config touched) ==="
		pmd_rc=0
		"$POST_MERGE_DEPLOY" "${MERGE_SHA}~1" "$MERGE_SHA" 2>&1 || pmd_rc=$?
		if [ "$pmd_rc" -ne 0 ]; then
			echo "⚠ post-merge-deploy exited $pmd_rc — verify stack state + run:" >&2
			echo "  $POST_MERGE_DEPLOY ${MERGE_SHA}~1 $MERGE_SHA" >&2
			echo "  (This is advisory; merge already landed. Deploy manually if the chain failed.)" >&2
		fi
	fi
fi

# Optional: create tag + auto-release.
if [ -n "$TAG" ]; then
	echo "=== Creating tag $TAG ==="
	skc_approve_or_exit "Tag this merge as $TAG and invoke auto-release.sh?"
	# MERGE_SHA was captured via gh pr view above (immediately after
	# the merge call returned, before any fetch/pull) — it references
	# the PR's actual mergeCommit.oid regardless of what happened on
	# main since, so tag always hits the merged commit.
	if ! git_out=$(git tag -a "$TAG" "$MERGE_SHA" -m "$TAG: release from PR #$PR ($MERGE_SHA)" 2>&1); then
		echo "git tag $TAG failed: $git_out" >&2
		echo "  Check: (a) tag already exists (git tag -l $TAG), (b) signing key, (c) HEAD is at intended commit" >&2
		exit 2
	fi
	# git push is not guarded by skill-bypass-guard (guard only targets gh).
	if ! git_out=$(git push origin "refs/tags/$TAG" 2>&1); then
		echo "git push $TAG failed: $git_out" >&2
		echo "  Tag not on origin; auto-release will refuse to proceed." >&2
		exit 2
	fi
	AUTO_RELEASE="$REPO_ROOT/.claude/local-backups/auto-release.sh"
	if [ -x "$AUTO_RELEASE" ]; then
		"$AUTO_RELEASE" "$TAG"
	elif [ -e "$AUTO_RELEASE" ]; then
		echo "⚠ $AUTO_RELEASE exists but is not executable — tag pushed, release NOT created." >&2
		echo "  Fix: chmod +x $AUTO_RELEASE && $AUTO_RELEASE $TAG" >&2
		exit 2
	else
		# Silent-skip here would leave tag pushed without a release page —
		# the "tagged-state ≠ released-state" gap: tag on origin but no
		# GitHub release page for users to discover the version.
		echo "⚠ $AUTO_RELEASE missing — tag pushed, release NOT created." >&2
		echo "  Run auto-release manually or restore the script." >&2
		exit 2
	fi
fi
