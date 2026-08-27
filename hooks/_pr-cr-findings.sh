#!/bin/bash
# Authoritative check for unresolved CodeRabbit feedback on a PR.
#
# Four data sources — ALL must be clean for a true "0 unresolved":
#   1. Unresolved current threads (isResolved=false AND isOutdated=false)
#      — active findings on HEAD code, must be addressed.
#   2. Stranded outdated threads (isResolved=false AND isOutdated=true)
#      — v4.0 lesson (PR #354): CR's auto-resolve heuristic sometimes fails
#      to correlate a fix with its suggested diff, leaving the thread
#      formally unresolved even after the code change lands. The thread
#      becomes "outdated" when the anchored line changes, but "outdated"
#      ≠ "resolved". Skipping these hid a near-miss merge past an
#      unaddressed finding. Now surfaced as a separate count so the
#      operator runs `resolveReviewThread` explicitly before merge.
#   3. Walkthrough issue-comment "🚥 Pre-merge checks | ✅ N | ❌ M"
#      (CR's own PR-body/description/docstring check summary)
#   4. Outside-diff-range findings embedded in review BODIES
#      — v4.1 lesson (PR #359): when CR wants to flag a line NOT in the
#      diff (cross-reference inconsistency, untouched-neighbor
#      contradiction), it can't post inline — it dumps the finding in the
#      review body under "Outside diff range comments (N)". Prior helper
#      only queried reviewThreads and missed this class entirely.
#      Now parsed per-review on HEAD.
#
# v3.21 lessons:
#   - PR #301: timestamp-based filtering missed 3 findings posted before
#     an arbitrary cutoff (commit_id/thread-resolution is the right axis).
#   - PR #302: walkthrough Pre-merge failure wasn't a reviewThread, so
#     helper v1 was blind to it — merged with unaddressed Description check.
#   - PR #303: reinforced both lessons + bulletproofed fail-closed paths.
#
# Usage:
#   .claude/hooks/_pr-cr-findings.sh <PR_NUMBER>
#
# Exit codes:
#   0  — clean (no active findings)
#   1  — findings present OR query failure
#   2  — bad args

set -euo pipefail

PR="${1:-}"
if [ -z "$PR" ] || ! [ "$PR" -eq "$PR" ] 2>/dev/null; then
	echo "Usage: $0 <PR_NUMBER>" >&2
	echo "  Returns 0 if PR has zero unresolved CodeRabbit findings (review-threads + walkthrough Pre-merge checks). Non-zero otherwise." >&2
	exit 2
fi

# Fail-closed pre-reqs. Silent-pass on missing tools merged PRs blind in the past.
command -v jq >/dev/null || {
	echo "ERROR: jq not installed" >&2
	exit 1
}
# gh required only when not in test mode. CR_TEST_MODE=1 short-circuits all gh
# calls and reads fixtures from CR_TEST_{THREADS,COMMENTS,REVIEWS}_FILE +
# CR_TEST_{OWNER,REPO,HEAD}. Used by tests/test_pr-cr-findings.sh.
if [ "${CR_TEST_MODE:-0}" != "1" ]; then
	command -v gh >/dev/null || {
		echo "ERROR: gh CLI not installed" >&2
		exit 1
	}
fi

if [ "${CR_TEST_MODE:-0}" = "1" ]; then
	# Defense-in-depth: if CR_TEST_MODE leaks into a real merge-gate shell,
	# fail loud rather than silently scanning empty fixtures. Require the
	# test harness to explicitly set CR_TEST_HEAD, which no prod caller would.
	if [ -z "${CR_TEST_HEAD:-}" ]; then
		echo "ERROR: CR_TEST_MODE=1 requires CR_TEST_HEAD to be set (test harness contract)" >&2
		exit 1
	fi
	OWNER="${CR_TEST_OWNER:-testowner}"
	REPO="${CR_TEST_REPO:-testrepo}"
	HEAD="$CR_TEST_HEAD"
else
	# Resolve repo — errors if not in a repo or auth fails
	OWNER=$(gh repo view --json owner -q .owner.login 2>/dev/null || true)
	REPO=$(gh repo view --json name -q .name 2>/dev/null || true)
	if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
		echo "ERROR: gh repo view failed (auth? not in a repo?)" >&2
		exit 1
	fi

	# Resolve PR HEAD — errors if PR doesn't exist
	HEAD=$(gh pr view "$PR" --json headRefOid -q .headRefOid 2>/dev/null || true)
	if [ -z "$HEAD" ]; then
		echo "ERROR: PR #$PR not found in ${OWNER}/${REPO}" >&2
		exit 1
	fi
fi

# ---- Source 1: unresolved review threads (inline file:line comments) ----
# v3.22 CR: cursor-based pagination. Accumulates all pages rather than the
# previous hard-fail-over-100. Hard cap at 20 pages (2000 threads) as a
# runaway guard — no realistic PR exceeds that.
UNRESOLVED="[]"
REPLIED="[]" # (#2548) answered, awaiting CR — reported, never counted
CURSOR=""
PAGE=0
MAX_PAGES=20
while [ "$PAGE" -lt "$MAX_PAGES" ]; do
	PAGE=$((PAGE + 1))
	# First page has no cursor (after omitted entirely). Subsequent pages
	# pass the endCursor from the previous response as `after:"..."`.
	if [ -z "$CURSOR" ]; then
		AFTER_CLAUSE=""
	else
		# Quote the cursor string — GraphQL `after:` expects a String value
		AFTER_CLAUSE=", after:\"$CURSOR\""
	fi
	if [ "${CR_TEST_MODE:-0}" = "1" ]; then
		# Test mode: one page, whole file, no pagination. If the fixture env
		# var is explicitly SET, the file MUST exist — a typo'd path must not
		# silently substitute the empty default (fail-closed on path mistakes).
		if [ -n "${CR_TEST_THREADS_FILE:-}" ]; then
			if [ ! -f "$CR_TEST_THREADS_FILE" ]; then
				echo "ERROR: CR_TEST_THREADS_FILE=$CR_TEST_THREADS_FILE set but file does not exist" >&2
				exit 1
			fi
			RAW=$(cat "$CR_TEST_THREADS_FILE") || {
				echo "ERROR: could not read CR_TEST_THREADS_FILE=$CR_TEST_THREADS_FILE" >&2
				exit 1
			}
		else
			RAW='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
		fi
	else
		RAW=$(gh api graphql \
			-F owner="$OWNER" -F repo="$REPO" -F pr="$PR" \
			-f query='
				query($owner:String!, $repo:String!, $pr:Int!) {
					repository(owner:$owner, name:$repo) {
						pullRequest(number:$pr) {
							reviewThreads(first:100'"$AFTER_CLAUSE"') {
								pageInfo { hasNextPage endCursor }
								nodes {
									id
									isResolved
									isOutdated
									comments(first:100) {
										nodes {
											author { login }
											path
											line
											originalLine
											body
										}
									}
								}
							}
						}
					}
				}' 2>/dev/null || true)
	fi
	if [ -z "$RAW" ]; then
		echo "ERROR: reviewThreads GraphQL query returned empty on page $PAGE — fail-closed" >&2
		exit 1
	fi
	PAGE_NODES=$(echo "$RAW" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
		| select(.isResolved == false)
		| select(.isOutdated == false)
		| select(.comments.nodes[0].author.login | test("coderabbit"; "i"))
		| select(([.comments.nodes[1:][] | select((.author.login // "") | test("coderabbit"; "i") | not)] | length) == 0)
		| {path: .comments.nodes[0].path, line: (.comments.nodes[0].line // .comments.nodes[0].originalLine), thread_id: .id, body: (.comments.nodes[0].body[0:400])}]' 2>/dev/null || true)
	if [ -z "$PAGE_NODES" ]; then
		echo "ERROR: thread-nodes jq-parse failed on page $PAGE" >&2
		exit 1
	fi
	# (#2548) `replied-awaiting-CR`: a human answered with evidence and CR has
	# not resolved yet. Surfaced at the gate for visibility, but NOT counted —
	# blocking on it would punish the operator for doing exactly what the
	# cr-thread-reply stage asks, and there is no further action available.
	PAGE_REPLIED=$(echo "$RAW" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
		| select(.isResolved == false)
		| select(.isOutdated == false)
		| select(.comments.nodes[0].author.login | test("coderabbit"; "i"))
		| select(([.comments.nodes[1:][] | select((.author.login // "") | test("coderabbit"; "i") | not)] | length) > 0)
		| {path: .comments.nodes[0].path, line: (.comments.nodes[0].line // .comments.nodes[0].originalLine), thread_id: .id}]' 2>/dev/null || true)
	if [ -z "$PAGE_REPLIED" ]; then
		echo "ERROR: replied-thread jq-parse failed on page $PAGE" >&2
		exit 1
	fi
	# v4.0 CR #354: stranded outdated-but-unresolved threads (CR's
	# auto-resolve missed). Separate list so the caller knows to run
	# the resolveReviewThread mutation rather than paper over them.
	PAGE_STRANDED=$(echo "$RAW" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
		| select(.isResolved == false)
		| select(.isOutdated == true)
		| select(.comments.nodes[0].author.login | test("coderabbit"; "i"))
		| {path: .comments.nodes[0].path, line: (.comments.nodes[0].line // .comments.nodes[0].originalLine), thread_id: .id, body: (.comments.nodes[0].body[0:200])}]' 2>/dev/null || true)
	if [ -z "$PAGE_STRANDED" ]; then
		echo "ERROR: stranded-thread jq-parse failed on page $PAGE" >&2
		exit 1
	fi
	# Merge this page's nodes into UNRESOLVED + STRANDED
	UNRESOLVED=$(jq -n --argjson a "$UNRESOLVED" --argjson b "$PAGE_NODES" '$a + $b')
	REPLIED=$(jq -n --argjson a "$REPLIED" --argjson b "$PAGE_REPLIED" '$a + $b')
	STRANDED=$(jq -n --argjson a "${STRANDED:-[]}" --argjson b "$PAGE_STRANDED" '$a + $b')
	HAS_NEXT=$(echo "$RAW" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false')
	NEXT_CURSOR=$(echo "$RAW" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""')
	[ "$HAS_NEXT" != "true" ] && break
	# Next iteration's cursor — pass as string, GraphQL will accept non-null
	CURSOR="$NEXT_CURSOR"
done
if [ "$PAGE" -eq "$MAX_PAGES" ] && [ "$HAS_NEXT" = "true" ]; then
	echo "ERROR: >$((MAX_PAGES * 100)) review threads — exceeded pagination cap. File a bug." >&2
	exit 1
fi
THREAD_COUNT=$(echo "$UNRESOLVED" | jq 'length' 2>/dev/null || true)
if [ -z "$THREAD_COUNT" ] || ! [ "$THREAD_COUNT" -eq "$THREAD_COUNT" ] 2>/dev/null; then
	echo "ERROR: thread count jq-parse failed" >&2
	exit 1
fi
STRANDED_COUNT=$(echo "${STRANDED:-[]}" | jq 'length' 2>/dev/null || true)
if [ -z "$STRANDED_COUNT" ] || ! [ "$STRANDED_COUNT" -eq "$STRANDED_COUNT" ] 2>/dev/null; then
	echo "ERROR: stranded count jq-parse failed" >&2
	exit 1
fi

# ---- Source 2: CR walkthrough Pre-merge checks (issue-comment) ----
# CR posts ONE walkthrough comment per PR, updated as commits are pushed.
# Summary block: "🚥 Pre-merge checks | ✅ N | ❌ M"
# Multiple CR comments might exist (past incremental reviews); take the most
# recent one (highest id) that contains "Pre-merge checks".
# CR feedback: --paginate + --jq applies the filter PER PAGE, so
# `sort_by(.id) | last` picks the last match within each page, not overall.
# Pipe raw pages through jq -s (slurp all pages into an array, then flatten).
if [ "${CR_TEST_MODE:-0}" = "1" ]; then
	if [ -n "${CR_TEST_COMMENTS_FILE:-}" ]; then
		if [ ! -f "$CR_TEST_COMMENTS_FILE" ]; then
			echo "ERROR: CR_TEST_COMMENTS_FILE=$CR_TEST_COMMENTS_FILE set but file does not exist" >&2
			exit 1
		fi
		COMMENTS_RAW=$(cat "$CR_TEST_COMMENTS_FILE") || {
			echo "ERROR: could not read CR_TEST_COMMENTS_FILE=$CR_TEST_COMMENTS_FILE" >&2
			exit 1
		}
		# Zero-byte fixture is a test bug, not "no comments" — fail loud
		# rather than letting the blank-response default silently substitute.
		if [ -z "$COMMENTS_RAW" ]; then
			echo "ERROR: CR_TEST_COMMENTS_FILE=$CR_TEST_COMMENTS_FILE is empty (treat as fixture bug, not a valid empty-comments payload; use an explicit [] file if that's the intent)" >&2
			exit 1
		fi
	else
		COMMENTS_RAW="[]"
	fi
else
	COMMENTS_RAW=$(gh api --paginate "repos/${OWNER}/${REPO}/issues/${PR}/comments" 2>/dev/null)
	# Only the prod path is allowed to coerce blank → []; a silent-empty
	# from gh here is a legitimate "zero comments" signal. Test-mode never
	# gets here because we errored above on empty fixture.
	COMMENTS_RAW=${COMMENTS_RAW:-"[]"}
fi
WALKTHROUGH_BODY=$(echo "$COMMENTS_RAW" |
	jq -s '[.[][] | select(.user.login | test("coderabbit"; "i")) | select(.body | contains("Pre-merge checks"))]
		| sort_by(.id) | last.body // ""' 2>/dev/null || true)
if [ -z "$WALKTHROUGH_BODY" ]; then
	# Empty string means jq failed — not "no CR walkthrough". Fail closed.
	echo "ERROR: walkthrough jq-parse failed (source 2)" >&2
	exit 1
fi
WALKTHROUGH_BODY=${WALKTHROUGH_BODY:-\"\"}
# jq -s output is JSON-encoded — strip outer quotes for downstream grep
WALKTHROUGH_BODY=$(echo "$WALKTHROUGH_BODY" | jq -r . 2>/dev/null || echo "")

WALKTHROUGH_FAILURES=0
WALKTHROUGH_WARNINGS=0
if [ -n "$WALKTHROUGH_BODY" ]; then
	# CR's walkthrough summary line: "🚥 Pre-merge checks | ✅ N | ❌ M", where M
	# counts both ❌ Failed AND ⚠ Warning rows. For merge gating we block only on
	# hard failures (M - warnings); warnings are informational.
	#
	# v0.31 #230 + r1 hardening — the gate must FAIL CLOSED on any unparseable CR
	# summary (the lone fail-OPEN this gate had; PR #302 class). The robustness:
	#   * extract the count from the SUMMARY LINE only, not the whole body — a
	#     decoy "❌ 0" elsewhere (e.g. a bolded legend) must not be matched (#230 r1
	#     security-review).
	#   * match the failure glyph as an ALTERNATION (CR may render ❌|❎|⛔|🚫) —
	#     locale-robust vs a multibyte [class], and the SAME set drives both the
	#     extractor and the drift-detector so they can't disagree (#230 r1 sfh).
	#   * validate POSITIVELY: a real summary shows "✅ N". If the body has the
	#     "Pre-merge checks" substring but no parseable summary line / no ✅ N, or a
	#     failure glyph with no parseable count, FAIL CLOSED — do not certify 0.
	#   * count ⚠ warnings only within the Pre-merge region (summary onward), not
	#     the whole body — a "Warning" in unrelated prose must not inflate the count
	#     and cancel real failures. A NEGATIVE (warnings > M) means the parse model
	#     is wrong → fail closed, never clamp-to-clean.
	PMG='❌|❎|⛔|🚫' # CR failure glyphs (alternation matches the whole glyph in any locale)
	SUMMARY_LINE=$(printf '%s' "$WALKTHROUGH_BODY" | grep -F 'Pre-merge checks' | head -1) || true
	if [ -z "$SUMMARY_LINE" ]; then
		echo "ERROR: walkthrough body present but no 'Pre-merge checks' summary line parseable — failing closed" >&2
		printf '%s\n' "$WALKTHROUGH_BODY" | head -20 >&2
		exit 1
	fi
	if ! printf '%s' "$SUMMARY_LINE" | grep -qE '✅[^0-9]{0,8}[0-9]+'; then
		echo "ERROR: 'Pre-merge checks' summary present but no parseable '✅ N' — format drift; failing closed" >&2
		printf '%s\n' "$SUMMARY_LINE" | head -5 >&2
		exit 1
	fi
	SUMMARY_FAIL=$(printf '%s' "$SUMMARY_LINE" | grep -oE "(${PMG})[^0-9]{0,8}[0-9]+" | head -1 | grep -oE '[0-9]+') || true
	if [ -z "$SUMMARY_FAIL" ]; then
		if printf '%s' "$SUMMARY_LINE" | grep -qE "(${PMG})"; then
			echo "ERROR: summary has a failure marker but no parseable count — format drift; failing closed" >&2
			printf '%s\n' "$SUMMARY_LINE" | head -5 >&2
			exit 1
		fi
		SUMMARY_FAIL=0 # ✅ N present, no failure glyph → genuinely zero
	fi
	if ! [ "$SUMMARY_FAIL" -eq "$SUMMARY_FAIL" ] 2>/dev/null; then
		echo "ERROR: summary failure count unparseable (non-integer) — failing closed" >&2
		printf '%s\n' "$SUMMARY_LINE" | head -5 >&2
		exit 1
	fi
	# Warnings: scoped to the Pre-merge region (summary line onward), not the body.
	PRE_MERGE_REGION=$(printf '%s' "$WALKTHROUGH_BODY" | awk '/Pre-merge checks/{f=1} f{print}')
	WALKTHROUGH_WARNINGS=$(printf '%s' "$PRE_MERGE_REGION" | grep -cE '⚠️?[[:space:]]*Warning') || true
	WALKTHROUGH_WARNINGS=${WALKTHROUGH_WARNINGS:-0}
	WALKTHROUGH_FAILURES=$((SUMMARY_FAIL - WALKTHROUGH_WARNINGS))
	if [ "$WALKTHROUGH_FAILURES" -lt 0 ]; then
		echo "ERROR: walkthrough warning count ($WALKTHROUGH_WARNINGS) exceeds total ❌ count ($SUMMARY_FAIL) — cannot reconcile CR summary; failing closed" >&2
		printf '%s\n' "$SUMMARY_LINE" | head -5 >&2
		exit 1
	fi
fi

# ---- Source 3: Outside-diff-range comments in review bodies ----
# v4.1 CR #359: when CR wants to flag a line NOT in the diff (cross-reference
# inconsistency, untouched-neighbor contradiction), it can't post inline. It
# instead embeds the finding in a REVIEW BODY under an "Outside diff range
# comments" section. My prior helper only queried reviewThreads (inline) and
# missed this class entirely — near-miss merge past real findings.
# Parse: fetch all CR reviews on HEAD, scan each body for "Outside diff range
# comments (N)" header, sum the N across unresolved reviews.
OUTSIDE_DIFF_COUNT=0
OUTSIDE_DIFF_DETAILS=""
if [ "${CR_TEST_MODE:-0}" = "1" ]; then
	if [ -n "${CR_TEST_REVIEWS_FILE:-}" ]; then
		if [ ! -f "$CR_TEST_REVIEWS_FILE" ]; then
			echo "ERROR: CR_TEST_REVIEWS_FILE=$CR_TEST_REVIEWS_FILE set but file does not exist" >&2
			exit 1
		fi
		REVIEWS_RAW=$(cat "$CR_TEST_REVIEWS_FILE") || {
			echo "ERROR: could not read CR_TEST_REVIEWS_FILE=$CR_TEST_REVIEWS_FILE" >&2
			exit 1
		}
		if [ -z "$REVIEWS_RAW" ]; then
			echo "ERROR: CR_TEST_REVIEWS_FILE=$CR_TEST_REVIEWS_FILE is empty (treat as fixture bug; use an explicit [] file if you want zero reviews)" >&2
			exit 1
		fi
	else
		REVIEWS_RAW="[]"
	fi
else
	REVIEWS_RAW=$(gh api --paginate "repos/${OWNER}/${REPO}/pulls/${PR}/reviews" 2>/dev/null)
	REVIEWS_RAW=${REVIEWS_RAW:-"[]"}
fi
REVIEW_BODIES=$(echo "$REVIEWS_RAW" |
	jq -s --arg h "$HEAD" '[.[][] | select(.user.login | test("coderabbit"; "i")) | select(.commit_id == $h) | .body]' 2>/dev/null || true)
if [ -z "$REVIEW_BODIES" ]; then
	echo "ERROR: pr-reviews jq-parse failed (source 3)" >&2
	exit 1
fi
# Sum finding counts across all CR reviews on HEAD that contain an "outside diff" section.
OUTSIDE_DIFF_COUNT=$(echo "$REVIEW_BODIES" | jq -r '.[] | capture("[Oo]utside diff range comments? \\((?<n>[0-9]+)\\)").n // empty' 2>/dev/null |
	awk '{s+=$1} END {print s+0}')
OUTSIDE_DIFF_COUNT=${OUTSIDE_DIFF_COUNT:-0}
if [ "$OUTSIDE_DIFF_COUNT" -gt 0 ]; then
	# Extract the content of the "Outside diff range comments" sections for display
	OUTSIDE_DIFF_DETAILS=$(echo "$REVIEW_BODIES" | jq -r '.[] | select(test("[Oo]utside diff range"))' 2>/dev/null |
		awk '/Outside diff range/,/<\/details>\s*$/' | head -60)
fi

TOTAL_FINDINGS=$((THREAD_COUNT + STRANDED_COUNT + WALKTHROUGH_FAILURES + OUTSIDE_DIFF_COUNT))

# ---- Report ----
echo "PR #$PR HEAD: ${HEAD:0:8}"
echo "Unresolved current threads: $THREAD_COUNT"
echo "Stranded outdated threads: $STRANDED_COUNT (CR missed auto-resolve; run resolveReviewThread)"
echo "Outside-diff-range findings: $OUTSIDE_DIFF_COUNT (CR can't post inline on untouched lines)"
echo "CR walkthrough Pre-merge failures: $WALKTHROUGH_FAILURES (warnings: $WALKTHROUGH_WARNINGS)"
echo "TOTAL needing cleanup: $TOTAL_FINDINGS"
echo ""

if [ "$TOTAL_FINDINGS" = "0" ]; then
	echo "(clean — no active CR findings, no stranded threads, no outside-diff findings)"
	exit 0
fi

# Show threads first
if [ "$THREAD_COUNT" -gt 0 ]; then
	echo "=== Unresolved current threads ==="
	echo "$UNRESOLVED" | jq -r '.[] | "===== \(.path):\(.line) =====\n\(.body)\n"'
fi

# v4.0 CR #354: show stranded threads with their thread_id so the
# caller can paste directly into the GraphQL resolveReviewThread mutation.
if [ "$STRANDED_COUNT" -gt 0 ]; then
	echo "=== Stranded outdated threads (resolve via GraphQL) ==="
	echo "$STRANDED" | jq -r '.[] | "===== \(.path):\(.line) =====\nthread_id: \(.thread_id)\n\(.body)\n"'
	echo ""
	echo "To resolve each (after confirming the fix landed):"
	# shellcheck disable=SC2016  # intentional literal \$ID placeholder for operator
	echo '  gh api graphql -f query="mutation { resolveReviewThread(input: {threadId: \"$ID\"}) { thread { isResolved } } }"'
	echo ""
fi

# Show walkthrough failures
if [ "$WALKTHROUGH_FAILURES" -gt 0 ]; then
	echo "=== CR walkthrough Pre-merge checks ==="
	echo "$WALKTHROUGH_BODY" | awk '/Pre-merge checks/,/<\/details>/' | head -40
	echo ""
fi

# Show outside-diff-range findings (v4.1 CR #359 gap)
if [ "$OUTSIDE_DIFF_COUNT" -gt 0 ]; then
	echo "=== Outside-diff-range findings ($OUTSIDE_DIFF_COUNT) ==="
	echo "CR flagged lines NOT in the diff — usually cross-reference inconsistencies"
	echo "or contradictions with untouched neighboring content."
	echo ""
	echo "$OUTSIDE_DIFF_DETAILS"
	echo ""
fi

exit 1
