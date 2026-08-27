#!/bin/bash
set -euo pipefail
# (#2548) Classify unresolved CodeRabbit review threads and REPLY to them.
#
# The cycle has a stage for FIXING a CR finding (cr-autofix → coderabbit:autofix)
# and no stage for the other three outcomes. When a thread is verified-fixed, a
# false positive, or a deliberate rejection, the standing rule says do NOT
# resolve it by hand — but nothing said what to do instead, so the cycle stalled
# at merge-gate with non-zero threads and no defined next action. Observed on
# PR #2540 (5 threads, only 1 fixable by writing code) and again on #2635, where
# the operator posted both replies by hand.
#
# The gap this closes: the rule says don't resolve; this says reply, with
# evidence, and let CR resolve.
#
#   actionable       → NOT handled here. Back to coderabbit:autofix.
#   verified-fixed   → reply citing the commit + the line range, GATED on
#                      `git show HEAD:<path>` actually succeeding.
#   false-positive   → reply with the disproof (command + output).
#   rejected-by-design → reply with the rationale + where it is recorded.
#
# NEVER fires resolveReviewThread. The reply is the action; CR resolving is the
# outcome. That is the whole point — see resolve-stranded.sh for the one place
# manual resolution IS correct (stranded = isResolved:false + isOutdated:true).
#
# reply_state is read SERVER-SIDE, not from a local log: a thread counts as
# `replied-awaiting-CR` when a non-coderabbitai comment follows CR's first one.
# Server state survives a session reset and cannot drift from the real PR.
#
# Usage:
#   scripts/cr/thread-reply.sh <pr>                    # human-readable table
#   scripts/cr/thread-reply.sh <pr> --list             # same, explicit
#   scripts/cr/thread-reply.sh <pr> --count            # unaddressed count only
#   scripts/cr/thread-reply.sh <pr> --json             # buckets + per-thread
#   scripts/cr/thread-reply.sh <pr> --thread <node-id> \
#       --class <verified-fixed|false-positive|rejected-by-design> \
#       --body <text> [--path <p>]        # --path REQUIRED for verified-fixed
#   ... --dry-run                                      # read + print, no mutation
#
# Exit: 0 ok · 2 usage/precondition · 3 reply refused (evidence gate failed)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"
# (#2548) SSOT for the replied/unaddressed predicate — shared with
# hooks/_pr-cr-findings.sh so the STAGE and the MERGE GATE cannot disagree
# about whether a thread has been answered.
# shellcheck source=../../_lib/cr-thread-state.sh
source "$SCRIPT_DIR/../../_lib/cr-thread-state.sh"

# skill-bypass-guard permits the gh api calls below for a skill wrapper.
export SKILL_WRAPPER=1

PR=""
MODE="list"
DRY_RUN=0
THREAD_ID=""
CLASS=""
BODY=""
SUBJECT_PATH=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--list)
		MODE="list"
		shift
		;;
	--count)
		MODE="count"
		shift
		;;
	--json)
		MODE="json"
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--thread)
		[ -n "${2:-}" ] || scm_fail "--thread requires a review-thread node id"
		THREAD_ID="$2"
		MODE="reply"
		shift 2
		;;
	--class)
		[ -n "${2:-}" ] || scm_fail "--class requires a value"
		CLASS="$2"
		shift 2
		;;
	--body)
		[ -n "${2:-}" ] || scm_fail "--body requires text"
		BODY="$2"
		shift 2
		;;
	--path)
		[ -n "${2:-}" ] || scm_fail "--path requires a repo-relative path"
		SUBJECT_PATH="$2"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	-*)
		scm_fail "unknown flag: $1"
		;;
	*)
		if [ -z "$PR" ] && [[ $1 =~ ^[0-9]+$ ]]; then
			PR="$1"
		else
			scm_fail "unknown or invalid arg: $1"
		fi
		shift
		;;
	esac
done

[ -n "$PR" ] || scm_fail "usage: $0 <pr-num> [--list|--count|--json] [--thread ID --class C --body TEXT]"

# Separate stderr so a warning on the success path cannot pollute the value.
TMPERR=$(mktemp) || scm_fail "mktemp failed"
trap 'rm -f "$TMPERR"' EXIT
if ! OWNER_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$TMPERR"); then
	scm_fail "gh repo view failed: $(cat "$TMPERR" 2>/dev/null || echo "")"
fi
OWNER="${OWNER_REPO%/*}"
REPO="${OWNER_REPO#*/}"

# --- read: every review thread, paginated ---------------------------------
#
# Paginated rather than first:100 like resolve-stranded.sh, because this
# feeds the MERGE GATE: a PR whose 101st thread is unaddressed must not read
# as clean. Truncation here would be a fail-open.
_fetch_threads() {
	local cursor="" page all="[]" has_next
	while :; do
		local args=(-f "owner=$OWNER" -f "repo=$REPO" -F "pr=$PR")
		[ -n "$cursor" ] && args+=(-f "cursor=$cursor")
		if ! page=$(gh api graphql "${args[@]}" -f query='
query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 100) {
            nodes { author { login } body }
          }
        }
      }
    }
  }
}' 2>"$TMPERR"); then
			scm_fail "gh graphql reviewThreads failed: $(cat "$TMPERR" 2>/dev/null || echo "")"
		fi
		if printf '%s' "$page" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
			scm_fail "graphql returned .errors: $(printf '%s' "$page" | jq -c .errors)"
		fi
		all=$(jq -c -n --argjson a "$all" --argjson p "$page" \
			'$a + $p.data.repository.pullRequest.reviewThreads.nodes') ||
			scm_fail "jq failed merging a reviewThreads page"
		has_next=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
		[ "$has_next" = "true" ] || break
		cursor=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
		if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
			scm_fail "hasNextPage=true but endCursor is empty — refusing a partial thread read"
		fi
	done
	printf '%s' "$all"
}

# Classify: unresolved threads only. `replied-awaiting-CR` when any comment
# AFTER CR's first is authored by someone other than coderabbitai.
_classify() {
	jq -c '
	  [ .[]
	    | select(.isResolved == false)
	    | . as $t
	    | ($t.comments.nodes // []) as $c
	    | ( '"$CR_THREAD_HUMAN_REPLY_COUNT_JQ"' ) as $human
	    | {
		id: $t.id,
		path: ($t.path // "?"),
		line: ($t.line // 0),
		outdated: $t.isOutdated,
		author: ($c[0].author.login // "unknown"),
		excerpt: (($c[0].body // "") | gsub("\r"; "") | split("\n")[0] | .[0:90]),
		reply_state: (if $human > 0 then "replied-awaiting-CR" else "unaddressed" end)
	      }
	  ]'
}

if [ "$MODE" != "reply" ]; then
	THREADS=$(_fetch_threads)
	RECORDS=$(printf '%s' "$THREADS" | _classify)
	UNADDRESSED=$(printf '%s' "$RECORDS" | jq '[.[] | select(.reply_state == "unaddressed")] | length')
	REPLIED=$(printf '%s' "$RECORDS" | jq '[.[] | select(.reply_state == "replied-awaiting-CR")] | length')
	TOTAL=$(printf '%s' "$RECORDS" | jq 'length')

	case "$MODE" in
	count)
		printf '%s\n' "$UNADDRESSED"
		;;
	json)
		jq -n --argjson u "$UNADDRESSED" --argjson r "$REPLIED" \
			--argjson t "$TOTAL" --argjson recs "$RECORDS" \
			'{pr: '"$PR"', unresolved: $t, unaddressed: $u, replied_awaiting_cr: $r, threads: $recs}'
		;;
	list)
		if [ "$TOTAL" = "0" ]; then
			echo "✓ PR #$PR: no unresolved review threads"
			exit 0
		fi
		echo "PR #$PR — $TOTAL unresolved thread(s): $UNADDRESSED unaddressed, $REPLIED replied-awaiting-CR"
		echo ""
		printf '%-22s %-42s %s\n' "STATE" "PATH:LINE" "EXCERPT"
		printf '%s\n' "$RECORDS" | jq -r '.[] | "\(.reply_state)\t\(.path):\(.line)\t\(.excerpt)"' |
			while IFS=$'\t' read -r st loc ex; do
				printf '%-22s %-42s %s\n' "$st" "$loc" "$ex"
			done
		echo ""
		echo "Reply to an unaddressed thread (node ids via --json):"
		echo "  $0 $PR --thread <id> --class verified-fixed --path <p> --body '...'"
		echo "  $0 $PR --thread <id> --class false-positive --body '...'"
		echo "  $0 $PR --thread <id> --class rejected-by-design --body '...'"
		;;
	esac
	exit 0
fi

# --- reply ----------------------------------------------------------------
[ -n "$CLASS" ] || scm_fail "--thread requires --class"
[ -n "$BODY" ] || scm_fail "--thread requires --body"

case "$CLASS" in
actionable)
	# Deliberately refused. An actionable finding is closed by CHANGING THE
	# CODE, not by explaining it away. Replying here would let a real defect
	# leave the cycle with prose attached.
	echo "thread-reply: class 'actionable' is not repliable — fix it instead." >&2
	echo "  Route it through the cr-autofix stage (coderabbit:autofix), commit," >&2
	echo "  and let the delta re-review confirm. Reply classes are for findings" >&2
	echo "  that need EVIDENCE, not a code change." >&2
	exit 2
	;;
verified-fixed)
	# The evidence gate, made mechanical. On PR #2540 a commit message
	# claimed a fix (`pcr_newest_complete`, v0.34.135) that had been lost
	# from the working tree — CR was right to keep flagging it. "Verify
	# against the committed file, not memory" has to be a command, not a
	# habit.
	[ -n "$SUBJECT_PATH" ] || scm_fail "--class verified-fixed requires --path (the file whose fix is being claimed)"
	if ! git show "HEAD:$SUBJECT_PATH" >/dev/null 2>"$TMPERR"; then
		echo "thread-reply: REFUSING the verified-fixed reply." >&2
		echo "  git show HEAD:$SUBJECT_PATH failed — that path is not in the" >&2
		echo "  committed tree at HEAD, so the fix being claimed is not there." >&2
		echo "  $(head -c 300 "$TMPERR" 2>/dev/null || echo "")" >&2
		exit 3
	fi
	;;
false-positive | rejected-by-design) ;;
*)
	scm_fail "--class must be one of: actionable | verified-fixed | false-positive | rejected-by-design"
	;;
esac

if [ "$DRY_RUN" = "1" ]; then
	echo "[dry-run] would reply to thread $THREAD_ID (class=$CLASS) on PR #$PR:"
	printf '%s\n' "$BODY" | sed 's/^/    /'
	exit 0
fi

if ! REPLY=$(gh api graphql -f "threadId=$THREAD_ID" -f "body=$BODY" -f query='
mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { id url }
  }
}' 2>"$TMPERR"); then
	scm_fail "addPullRequestReviewThreadReply failed: $(head -c 400 "$TMPERR" 2>/dev/null || echo "")"
fi
if printf '%s' "$REPLY" | jq -e '(.errors // []) | length > 0' >/dev/null 2>&1; then
	scm_fail "reply mutation returned .errors: $(printf '%s' "$REPLY" | jq -c .errors)"
fi

URL=$(printf '%s' "$REPLY" | jq -r '.data.addPullRequestReviewThreadReply.comment.url // "?"')
SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
scm_log cr-thread-reply "$(jq -nc --arg pr "$PR" --arg sha "$SHA" --arg tid "$THREAD_ID" \
	--arg cls "$CLASS" --arg url "$URL" \
	'{pr: $pr, sha: $sha, thread_id: $tid, class: $cls, reply_state: "replied-awaiting-CR", url: $url}')"
echo "✓ replied to thread ($CLASS): $URL"
echo "  CR resolves it; this script never does."
