#!/bin/bash
set -euo pipefail
# v4.21 (#520): find and resolve "stranded" CodeRabbit review threads —
# comments with isResolved=false AND isOutdated=true (CR flagged something,
# the code was fixed, but the thread was never marked resolved). These
# block merges on strict branch-protection setups and accumulate silently.
#
# Per `feedback_cr_stranded_threads` memory: these are STRANDED, not safe.
# Must be manually resolved via the resolveReviewThread GraphQL mutation.
#
# Usage:
#   .claude/scripts/cr/resolve-stranded.sh <pr-num>              # resolve all
#   .claude/scripts/cr/resolve-stranded.sh <pr-num> --dry-run    # list what would resolve
#   .claude/scripts/cr/resolve-stranded.sh <pr-num> --count      # just report the count

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

SCM_DRY_RUN=0
FORMAT="apply"
PR=""
for arg in "$@"; do
	case "$arg" in
	--dry-run) SCM_DRY_RUN=1 ;;
	--count) FORMAT="count" ;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		if [ -z "$PR" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
			PR="$arg"
		else
			scm_fail "unknown or invalid arg: $arg"
		fi
		;;
	esac
done
[ -n "$PR" ] || scm_fail "usage: $0 <pr-num> [--dry-run] [--count]"

# Resolve repo for the graphql owner/repo args. Don't merge stderr into
# the captured value — on success, a spurious stderr warning would
# pollute OWNER_REPO and break the split below. Capture separately with
# an EXIT trap so the tempfile is cleaned up even on early abort.
TMPERR=$(mktemp)
trap 'rm -f "$TMPERR"' EXIT
if ! OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$TMPERR"); then
	ERR=$(cat "$TMPERR" 2>/dev/null || echo "")
	scm_fail "gh repo view failed: $ERR"
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

# Fetch review threads (isResolved + isOutdated + id for mutation).
if ! THREADS=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes { id isResolved isOutdated comments(first: 1) { nodes { author { login } } } }
      }
    }
  }
}' -f "owner=$OWNER" -f "repo=$REPO" -F "pr=$PR" 2>&1); then
	scm_fail "gh graphql reviewThreads failed: $THREADS"
fi

# Warn if truncated — a PR with >100 review threads is rare but possible
# on large CR rounds. Full pagination would complicate the mutating loop;
# for now we surface the truncation so operator knows to re-run.
if [ "$(printf '%s' "$THREADS" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ]; then
	scm_warn "PR #$PR has >100 review threads — only the first page is processed. Re-run after this pass if needed."
fi

if printf '%s' "$THREADS" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
	scm_fail "graphql returned .errors: $(printf '%s' "$THREADS" | jq -c .errors)"
fi

# Filter to stranded: isResolved=false + isOutdated=true. Optionally
# restrict to coderabbitai-authored (future-proofing — we primarily care
# about CR threads, but any reviewer's stranded thread blocks merge).
STRANDED=$(printf '%s' "$THREADS" | jq -c \
	'[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == true)]')
COUNT=$(printf '%s' "$STRANDED" | jq 'length')

if [ "$FORMAT" = "count" ]; then
	printf '%s\n' "$COUNT"
	exit 0
fi

if [ "$COUNT" = "0" ]; then
	echo "✓ PR #$PR: no stranded threads"
	exit 0
fi

echo "Found $COUNT stranded thread(s) on PR #$PR:"
printf '%s' "$STRANDED" | jq -r '.[] | "  - \(.id)  (author: \(.comments.nodes[0].author.login // "unknown"))"'

if [ "$SCM_DRY_RUN" = "1" ]; then
	echo ""
	echo "[dry-run] would resolve the above $COUNT thread(s) via resolveReviewThread mutation"
	exit 0
fi

# Apply: loop resolveReviewThread mutations.
RESOLVED=0
FAILED=0
for thread_id in $(printf '%s' "$STRANDED" | jq -r '.[] | .id'); do
	rc=0
	RESULT=$(gh api graphql -f query='
mutation($id: ID!) {
  resolveReviewThread(input: {threadId: $id}) {
    thread { isResolved }
  }
}' -f "id=$thread_id" 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		scm_warn "failed to resolve $thread_id: $RESULT"
		FAILED=$((FAILED + 1))
		continue
	fi
	if printf '%s' "$RESULT" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
		scm_warn "resolve $thread_id returned errors: $(printf '%s' "$RESULT" | jq -c .errors)"
		FAILED=$((FAILED + 1))
		continue
	fi
	RESOLVED=$((RESOLVED + 1))
done

echo ""
echo "✓ resolved $RESOLVED/$COUNT thread(s)"
# Explicit if — `[ "$FAILED" -gt 0 ] && cmd` returns 1 when FAILED=0,
# which under set -e would abort BEFORE the scm_log below runs and lose
# the audit record for the happy-path (all resolves succeeded) run.
if [ "$FAILED" -gt 0 ]; then
	scm_warn "$FAILED resolve(s) failed — check output above"
fi

scm_log cr-resolve-stranded "$(jq -nc --argjson pr "$PR" --argjson count "$COUNT" \
	--argjson resolved "$RESOLVED" --argjson failed "$FAILED" \
	'{pr: $pr, stranded: $count, resolved: $resolved, failed: $failed}')"
# Exit non-zero on partial resolution so CI/cron consumers can detect the
# half-state. The scm_warn above still prints to stderr for interactive users.
[ "$FAILED" -eq 0 ] || exit 1
