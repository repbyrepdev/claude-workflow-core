#!/usr/bin/env bats
# covers: hooks/_pr-cr-findings.sh
#
# v0.31 #230 (+ r1 hardening): the CR walkthrough Pre-merge-checks parse is the
# merge gate's fail-open surface (PR #302 class). It must: extract the failure
# count from the SUMMARY LINE only (not a decoy elsewhere), match the failure
# glyph as an alternation (❌|❎|⛔|🚫), validate positively (✅ N present), scope
# the ⚠-warning count to the Pre-merge region, and FAIL CLOSED on any
# unparseable / irreconcilable summary. Drives the CR_TEST_MODE harness with a
# CR_TEST_COMMENTS_FILE fixture; sources 1 (threads) + 3 (reviews) are left unset
# (⇒ empty) so only the walkthrough count is under test.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/_pr-cr-findings.sh"
	[ -f "$HOOK" ]
	command -v jq >/dev/null
	TMP=$(mktemp -d -t prcrf.XXXXXX) || return 1
	NBSP=$(printf '\xc2\xa0') # U+00A0 for the nbsp-drift fixture
}

teardown() {
	[ -n "${TMP:-}" ] && [ -d "$TMP" ] && [[ $TMP == */prcrf.* ]] && rm -rf "$TMP"
	return 0
}

# $1 = walkthrough body (may be multi-line) → one coderabbit issue-comment.
_comments_fixture() {
	jq -n --arg b "$1" '[{id:1, user:{login:"coderabbitai[bot]"}, body:$b}]' >"$TMP/comments.json"
}

_run_gate() {
	run env CR_TEST_MODE=1 CR_TEST_HEAD=abc123 CR_TEST_OWNER=o CR_TEST_REPO=r \
		CR_TEST_COMMENTS_FILE="$TMP/comments.json" bash "$HOOK" 1
}

@test "drift: ❌ marker present but no extractable count → FAIL CLOSED (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 5 | ❌ Failed checks listed below"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output == *"failing closed"* || $output == *"format drift"* ]]
}

@test "clean: ❌ 0 → zero findings, gate passes (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 5 | ❌ 0"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "failures: ❌ 2 → gate blocks on the COUNT (not drift) (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌ 2"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output != *"failing closed"* ]]
}

@test "no-space drift (❌3) still EXTRACTS → blocks, not fail-open (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌3"
	_run_gate
	[ "$status" -ne 0 ]
}

@test "no ❌ marker at all → treated as 0 (CR omitted it), gate passes (#230)" {
	_comments_fixture "🚥 Pre-merge checks | ✅ 5"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "nbsp drift (❌<nbsp>2) still EXTRACTS → blocks, not fail-open (#230 r1)" {
	# The PR's headline drift case; old `❌ [0-9]+` (ASCII space) would miss nbsp.
	_comments_fixture "🚥 Pre-merge checks | ✅ 3 | ❌${NBSP}2"
	_run_gate
	[ "$status" -ne 0 ]
}

@test "ALL four failure glyphs (❌ ❎ ⛔ 🚫) are recognized → block (#230 r1 sfh CRITICAL)" {
	# The extractor + detector match the full alternation ❌|❎|⛔|🚫; NONE may slip
	# past as 0 (the residual fail-open the first cut left). Cover every glyph.
	for g in "❌" "❎" "⛔" "🚫"; do
		_comments_fixture "🚥 Pre-merge checks | ✅ 3 | $g 2"
		_run_gate
		[ "$status" -ne 0 ] || {
			echo "expected BLOCK for failure glyph: $g (got status=$status)" >&2
			false
		}
	done
}

@test "decoy ❌ 0 BEFORE the summary line is ignored — count read from summary (#230 r1)" {
	# A bolded/legend "❌ 0" earlier in the body must not be matched; the count
	# comes from the 'Pre-merge checks' summary line (which says ❌ 3).
	_comments_fixture "$(printf 'Legend: ❌ 0 means none\n\n🚥 Pre-merge checks | ✅ 2 | ❌ 3')"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output != *"failing closed"* ]] # blocked on the real count (3), not drift
}

@test "summary line present but no ✅ N → FAIL CLOSED (positive validation) (#230 r1)" {
	_comments_fixture "🚥 Pre-merge checks (results pending)"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output == *"failing closed"* ]]
}

@test "warning-only (❌ 1 == one ⚠ Warning row) → 0 hard failures, passes (#230 r1)" {
	_comments_fixture "$(printf '🚥 Pre-merge checks | ✅ 5 | ❌ 1\n\n| Check | Status |\n| Docs | ⚠️ Warning |')"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "warnings exceed ❌ count → irreconcilable → FAIL CLOSED (#230 r1)" {
	_comments_fixture "$(printf '🚥 Pre-merge checks | ✅ 5 | ❌ 1\n\n| A | ⚠️ Warning |\n| B | ⚠️ Warning |')"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output == *"failing closed"* || $output == *"cannot reconcile"* ]]
}

@test "⚠ Warning in prose BEFORE the summary is NOT subtracted → real failure blocks (#230 r1)" {
	# Warning count is scoped to the Pre-merge region (summary onward); a prose
	# 'Warning' above must not cancel a real failure.
	_comments_fixture "$(printf '⚠️ Warning: this PR is large\n\n🚥 Pre-merge checks | ✅ 3 | ❌ 1')"
	_run_gate
	[ "$status" -ne 0 ]
	[[ $output != *"failing closed"* ]] # 1 real failure remains, not drift
}

@test "multiple CR comments → latest (highest id) walkthrough wins (#230 r1)" {
	jq -n '[
		{id:1, user:{login:"coderabbitai[bot]"}, body:"🚥 Pre-merge checks | ✅ 2 | ❌ 3"},
		{id:2, user:{login:"coderabbitai[bot]"}, body:"🚥 Pre-merge checks | ✅ 5 | ❌ 0"}
	]' >"$TMP/comments.json"
	_run_gate
	[ "$status" -eq 0 ] # reads id:2 (clean), not the stale id:1
}

# --- (#2548) the replied/unaddressed split at the MERGE GATE ---------------
#
# Only UNADDRESSED threads block. A thread carrying an evidence reply is
# `replied-awaiting-CR`: the operator did what the cr-thread-reply stage asked
# and CR has yet to resolve, so blocking would leave no available action.
#
# Phase 0.5 flagged this logic as having zero coverage on the commit that
# introduced it — and it is the merge gate, so a fail-open here merges over
# findings nobody read.

# $1 = threads JSON array → the reviewThreads GraphQL shape.
_threads_fixture() {
	jq -n --argjson n "$1" \
		'{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}' \
		>"$TMP/threads.json"
}

_run_gate_threads() {
	run env CR_TEST_MODE=1 CR_TEST_HEAD=abc123 CR_TEST_OWNER=o CR_TEST_REPO=r \
		CR_TEST_THREADS_FILE="$TMP/threads.json" bash "$HOOK" 1
}

@test "#2548: an UNADDRESSED thread blocks the gate" {
	# Status AND classification. The gate has several independent reasons to
	# block (walkthrough parse failing closed, a GraphQL read error), so a
	# status-only assertion here passed on a run that never counted the thread
	# at all — the test would stay green while the thread source was broken.
	_threads_fixture '[{"id":"T1","isResolved":false,"isOutdated":false,
	  "comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"finding"}]}}]'
	_run_gate_threads
	[ "$status" -ne 0 ] || {
		echo "an unaddressed thread did not block: $output"
		return 1
	}
	case "$output" in
	*"Unresolved current threads: 1 (unaddressed"*) ;;
	*)
		echo "blocked, but NOT as one unaddressed thread: $output"
		return 1
		;;
	esac
}

@test "#2548: a REPLIED thread does NOT block" {
	# The whole point. The operator replied with evidence; CR resolves on its
	# own schedule. Blocking here punished doing exactly what was asked.
	_threads_fixture '[{"id":"T1","isResolved":false,"isOutdated":false,
	  "comments":{"nodes":[
	    {"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"finding"},
	    {"author":{"login":"someone"},"path":"a.sh","line":1,"body":"here is the disproof"}]}}]'
	_run_gate_threads
	[ "$status" -eq 0 ] || {
		echo "a replied-awaiting-CR thread still blocked: $output"
		return 1
	}
	# It passed because it was SEEN and classified, not because the thread
	# source dropped it. Those two produce the same exit status and opposite
	# meanings: one is the feature, the other is the gate going blind.
	case "$output" in
	*"Unresolved current threads: 0 (unaddressed"*) ;;
	*)
		echo "passed, but not with zero unaddressed: $output"
		return 1
		;;
	esac
	case "$output" in
	*"replied-awaiting-CR: 1"*) ;;
	*)
		echo "the thread was not counted as replied — the gate may not have seen it: $output"
		return 1
		;;
	esac
}

@test "#2548: a human-opened thread is not a CR finding (shared population)" {
	# The population predicate, from the gate's side. The stage and the gate
	# read CR_THREAD_IS_CR_AUTHORED_JQ from the same lib; before it was shared
	# the gate matched the SUBSTRING "coderabbit", so a human whose login
	# merely contains it opened a thread the gate counted and the stage did
	# not — the exact stage-vs-gate disagreement the SSOT exists to prevent.
	_threads_fixture '[{"id":"T1","isResolved":false,"isOutdated":false,
	  "comments":{"nodes":[{"author":{"login":"coderabbit-fan"},"path":"a.sh","line":1,"body":"a human question"}]}}]'
	_run_gate_threads
	[ "$status" -eq 0 ] || {
		echo "a human-opened thread blocked the merge gate: $output"
		return 1
	}
	case "$output" in
	*"Unresolved current threads: 0 (unaddressed"*) ;;
	*)
		echo "a human-opened thread was counted as a CR finding: $output"
		return 1
		;;
	esac
}

@test "#2548: a replied thread is REPORTED even though it does not block" {
	# Non-blocking must not mean invisible — the operator should see the state
	# at the gate, or a thread awaiting CR looks like nothing at all.
	_threads_fixture '[{"id":"T1","isResolved":false,"isOutdated":false,
	  "comments":{"nodes":[
	    {"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"finding"},
	    {"author":{"login":"someone"},"path":"a.sh","line":1,"body":"disproof"}]}}]'
	_run_gate_threads
	case "$output" in
	*replied-awaiting-CR*) ;;
	*)
		echo "the replied thread was not surfaced: $output"
		return 1
		;;
	esac
}

@test "#2548: a CR follow-up does NOT count as a reply" {
	# CR often posts twice on its own thread. Counting that as an answer would
	# pass a thread nobody addressed straight through the gate.
	_threads_fixture '[{"id":"T1","isResolved":false,"isOutdated":false,
	  "comments":{"nodes":[
	    {"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"finding"},
	    {"author":{"login":"coderabbitai[bot]"},"path":"a.sh","line":1,"body":"still here"}]}}]'
	_run_gate_threads
	[ "$status" -ne 0 ] || {
		echo "a CR self-reply was mistaken for an answer: $output"
		return 1
	}
	case "$output" in
	*"Unresolved current threads: 1 (unaddressed"*) ;;
	*)
		echo "blocked, but not as one unaddressed thread: $output"
		return 1
		;;
	esac
}

@test "#2548: mixed threads block on the unaddressed one only" {
	_threads_fixture '[
	  {"id":"T1","isResolved":false,"isOutdated":false,
	   "comments":{"nodes":[
	     {"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"answered"},
	     {"author":{"login":"someone"},"path":"a.sh","line":1,"body":"disproof"}]}},
	  {"id":"T2","isResolved":false,"isOutdated":false,
	   "comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"b.sh","line":2,"body":"open"}]}}]'
	_run_gate_threads
	[ "$status" -ne 0 ]
	# The blocking COUNT is 1, not 2 — asserted, not just described. Naming
	# b.sh proves the open thread was seen; only the count proves the replied
	# one was excluded rather than also counted.
	case "$output" in
	*"Unresolved current threads: 1 (unaddressed"*) ;;
	*)
		echo "expected exactly one blocking thread; got: $output"
		return 1
		;;
	esac
	case "$output" in
	*"replied-awaiting-CR: 1"*) ;;
	*)
		echo "the replied thread was not reported alongside: $output"
		return 1
		;;
	esac
	case "$output" in
	*"b.sh"*) ;;
	*)
		echo "the unaddressed thread was not named: $output"
		return 1
		;;
	esac
}

@test "#2548: a RESOLVED thread is out of scope entirely" {
	_threads_fixture '[{"id":"T1","isResolved":true,"isOutdated":false,
	  "comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"done"}]}}]'
	_run_gate_threads
	[ "$status" -eq 0 ]
	# The count, for the reason stated at the top of this group: rc 0 is
	# produced by every clean path the gate has, including one where the
	# thread source never read the fixture. Only the count shows the thread
	# was SEEN and then excluded.
	case "$output" in
	*"Unresolved current threads: 0 (unaddressed"*) ;;
	*)
		echo "passed, but not with the resolved thread excluded: $output"
		return 1
		;;
	esac
	case "$output" in
	*"replied-awaiting-CR"*)
		echo "a resolved thread was reported as replied-awaiting-CR: $output"
		return 1
		;;
	esac
}
