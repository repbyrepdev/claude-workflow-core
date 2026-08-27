#!/usr/bin/env bats
# covers: _lib/cr-thread-state.sh
# audits: scripts/cr/thread-reply.sh hooks/_pr-cr-findings.sh
#
# (#2548) One question, two consumers that must never disagree:
#
#   scripts/cr/thread-reply.sh   drives the cr-thread-reply STAGE — holds or
#                                advances the cycle.
#   hooks/_pr-cr-findings.sh     drives the MERGE GATE — blocks or allows.
#
# Written twice they drift, and the failure is silent AND asymmetric: the
# stage advances believing every thread is answered while the gate still
# blocks, or the gate lets through a thread nobody was ever asked to address.
# Phase 0.5 flagged the duplication on the commit that introduced it, which is
# why the predicate now lives in one place.
#
# This suite pins the SEMANTICS of the fragment, and asserts that neither
# consumer has quietly re-inlined its own copy.

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$PLUGIN/_lib/cr-thread-state.sh"
	[ -r "$LIB" ]
	command -v jq >/dev/null
	# shellcheck source=../../../_lib/cr-thread-state.sh
	source "$LIB"
}

# Apply the shared fragment to one thread node; echoes the human-reply count.
_count() { # $1 = thread node JSON
	printf '%s' "$1" | jq "$CR_THREAD_HUMAN_REPLY_COUNT_JQ"
}

@test "CR alone on the thread = unaddressed" {
	run _count '{"comments":{"nodes":[{"author":{"login":"coderabbitai"},"body":"finding"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "a human reply after CR = replied" {
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"finding"},
	  {"author":{"login":"someone"},"body":"disproof"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "a CR follow-up is NOT a human reply" {
	# CR often posts more than once on its own thread. Counting that as an
	# answer would let a thread nobody addressed pass the merge gate.
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"finding"},
	  {"author":{"login":"coderabbitai[bot]"},"body":"still here"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "the FIRST comment never counts, even from a human" {
	# Thread [0] is the finding itself. A human-opened thread with no reply is
	# still unaddressed — otherwise every such thread would self-satisfy.
	run _count '{"comments":{"nodes":[{"author":{"login":"someone"},"body":"I found this"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "a missing or empty comments array does not crash the predicate" {
	# A malformed node must not abort the scan that feeds the merge gate.
	run _count '{}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
	run _count '{"comments":{"nodes":[]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "an UNREADABLE author fails CLOSED — a ghost cannot silence a thread" {
	# This previously asserted 1, i.e. a null author counted as a human reply.
	# That is a fail-open on a merge gate: a deleted or ghost account would
	# stop the thread blocking. An unidentifiable commenter is not evidence
	# that anyone addressed the finding, so the unknown case counts as
	# unanswered.
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"finding"},
	  {"author":null,"body":"ghost"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
	# An empty login string, same reasoning.
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"finding"},
	  {"author":{"login":""},"body":"blank"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "the bot match is ANCHORED — a human named coderabbitfan still counts" {
	# As a substring, `test("coderabbit")` swallowed any login containing it,
	# so that person's replies would never count and their thread would block
	# forever with no diagnosable cause.
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitfan"},"body":"I found this"},
	  {"author":{"login":"coderabbitfan"},"body":"and here is the fix"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
	# ...while the real bot logins are still recognised.
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"finding"},
	  {"author":{"login":"coderabbitai[bot]"},"body":"follow-up"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ]
}

@test "CR REBUTTING a reply puts the thread back to unaddressed" {
	# The predicate is positional for this reason. As "any human comment
	# exists after the first", the sequence below read as ANSWERED — so the
	# merge gate stopped counting a thread on which CR had explicitly
	# rejected the evidence, and no later CR comment could undo it.
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"bug here"},
	  {"author":{"login":"me"},"body":"fixed in abc123"},
	  {"author":{"login":"coderabbitai"},"body":"No — still broken"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "0" ] || {
		echo "a CR rebuttal did not re-block the thread"
		return 1
	}
}

##
## Agreement between the two consumers, checked by RUNNING them.
##
## These were grep-over-source tests: they asserted that each file MENTIONED
## the shared symbol. That is satisfied by a comment. It cannot see a consumer
## that sources the lib, names the fragment, and then applies its own filter
## first — which is what had actually happened to the POPULATION half, where
## the gate matched the substring "coderabbit" while the stage matched the
## anchored form. The property worth pinning is not "the text appears" but
## "the two answer the same".
##
## So: one fixture, both consumers, assert the classification agrees.
##

# The rebuttal sequence — the case that made the predicate positional. Reused
# by both consumers below so neither can be right about a different input.
_rebuttal_thread() {
	cat <<-'J'
		[{"id":"T_reb","isResolved":false,"isOutdated":false,"path":"a.sh","line":1,
		  "comments":{"nodes":[
		    {"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"finding"},
		    {"author":{"login":"someone"},"path":"a.sh","line":1,"body":"fixed in abc123"},
		    {"author":{"login":"coderabbitai"},"path":"a.sh","line":1,"body":"No — still broken"}]}}]
	J
}

_agreement_tmp() {
	AGREE_TMP=$(mktemp -d -t crthreadagree.XXXXXX) || return 1
	mkdir -p "$AGREE_TMP/bin"
}

# Cleanup lives in teardown(), which bats runs on EVERY exit path — including
# a failed assertion, a `set -u` reference, or a bats-level abort. It was
# called manually on four paths across two tests, so every future early return
# had to remember it and any hard abort leaked the directory. The
# `*/crthreadagree.*` guard keeps the rm -rf honest.
teardown() {
	case "${AGREE_TMP:-}" in
	*/crthreadagree.*) rm -rf "$AGREE_TMP" ;;
	esac
	return 0
}

@test "STAGE and GATE agree on a CR rebuttal: both say unaddressed" {
	# CR rejected the evidence, so the thread is open again. If the stage read
	# it as answered while the gate still blocked, the cycle would advance to a
	# merge that could not happen — with nothing naming the disagreement.
	_agreement_tmp || return 1
	printf '%s' "$(_rebuttal_thread)" >"$AGREE_TMP/nodes.json"

	# --- the GATE (hooks/_pr-cr-findings.sh), via its own test harness ---
	jq -n --argjson n "$(_rebuttal_thread)" \
		'{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}' \
		>"$AGREE_TMP/threads.json"
	run env CR_TEST_MODE=1 CR_TEST_HEAD=abc123 CR_TEST_OWNER=o CR_TEST_REPO=r \
		CR_TEST_THREADS_FILE="$AGREE_TMP/threads.json" \
		bash "$PLUGIN/hooks/_pr-cr-findings.sh" 1
	local gate_out=$output gate_status=$status
	case "$gate_out" in
	*"Unresolved current threads: 1 (unaddressed"*) ;;
	*)
		echo "GATE did not count the rebuttal as unaddressed (status=$gate_status): $gate_out"
		return 1
		;;
	esac

	# --- the STAGE (scripts/cr/thread-reply.sh), via a PATH-stubbed gh ---
	cat >"$AGREE_TMP/bin/gh" <<-'STUB'
		#!/bin/bash
		case "$*" in
		*"repo view"*) printf 'o/r\n'; exit 0 ;;
		*reviewThreads*)
			printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}}}}\n' "$(cat "$NODES_FILE")"
			exit 0
			;;
		esac
		printf '{}\n'
	STUB
	chmod +x "$AGREE_TMP/bin/gh"
	run env PATH="$AGREE_TMP/bin:$PATH" NODES_FILE="$AGREE_TMP/nodes.json" \
		"$PLUGIN/scripts/cr/thread-reply.sh" 7 --json
	local stage_out=$output stage_status=$status
	[ "$stage_status" -eq 0 ] || {
		echo "STAGE exited $stage_status: $stage_out"
		return 1
	}
	[ "$(printf '%s' "$stage_out" | jq -r '.unaddressed')" = "1" ] || {
		echo "STAGE disagreed with the GATE on the rebuttal: $stage_out"
		return 1
	}
}

@test "STAGE and GATE agree a human-opened thread is not a CR finding" {
	# The POPULATION half of the same agreement, and the half that HAD drifted:
	# the gate's substring match counted "coderabbit-fan" as CodeRabbit, the
	# stage's anchored match did not. Both now read the shared fragment.
	_agreement_tmp || return 1
	local human='[{"id":"T_h","isResolved":false,"isOutdated":false,"path":"a.sh","line":1,
	  "comments":{"nodes":[{"author":{"login":"coderabbit-fan"},"path":"a.sh","line":1,"body":"a human question"}]}}]'
	printf '%s' "$human" >"$AGREE_TMP/nodes.json"

	jq -n --argjson n "$human" \
		'{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}' \
		>"$AGREE_TMP/threads.json"
	run env CR_TEST_MODE=1 CR_TEST_HEAD=abc123 CR_TEST_OWNER=o CR_TEST_REPO=r \
		CR_TEST_THREADS_FILE="$AGREE_TMP/threads.json" \
		bash "$PLUGIN/hooks/_pr-cr-findings.sh" 1
	local gate_out=$output
	case "$gate_out" in
	*"Unresolved current threads: 0 (unaddressed"*) ;;
	*)
		echo "GATE counted a human-opened thread as a CR finding: $gate_out"
		return 1
		;;
	esac

	cat >"$AGREE_TMP/bin/gh" <<-'STUB'
		#!/bin/bash
		case "$*" in
		*"repo view"*) printf 'o/r\n'; exit 0 ;;
		*reviewThreads*)
			printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}}}}}\n' "$(cat "$NODES_FILE")"
			exit 0
			;;
		esac
		printf '{}\n'
	STUB
	chmod +x "$AGREE_TMP/bin/gh"
	run env PATH="$AGREE_TMP/bin:$PATH" NODES_FILE="$AGREE_TMP/nodes.json" \
		"$PLUGIN/scripts/cr/thread-reply.sh" 7 --json
	local stage_out=$output stage_status=$status
	[ "$stage_status" -eq 0 ] || {
		echo "STAGE exited $stage_status: $stage_out"
		return 1
	}
	[ "$(printf '%s' "$stage_out" | jq -r '.unaddressed')" = "0" ] || {
		echo "STAGE counted a human-opened thread as a CR finding: $stage_out"
		return 1
	}
}

@test "neither consumer re-inlined a private copy of the predicate" {
	# Kept as a cheap tripwire ALONGSIDE the runtime agreement above, not
	# instead of it: it catches a re-inlined copy on a code path the fixtures
	# above happen not to reach. On its own it proved nothing — that is why the
	# two tests it replaced are now runtime tests.
	cd "$PLUGIN" || return 1
	local f
	for f in scripts/cr/thread-reply.sh hooks/_pr-cr-findings.sh; do
		run bash -c "grep -c 'comments.nodes\[1:\]' '$f' || true"
		[ "$output" = "0" ] || {
			echo "$f re-inlined its own reply predicate — the two can now drift"
			return 1
		}
		# The old unanchored author match, which is how the population halves
		# came apart in the first place.
		run bash -c "grep -c 'author.login | test(\"coderabbit\"; \"i\")' '$f' || true"
		[ "$output" = "0" ] || {
			echo "$f re-inlined the UNANCHORED author match — populations can drift again"
			return 1
		}
	done
}
