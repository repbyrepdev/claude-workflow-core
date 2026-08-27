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
	printf '%s' "$1" | jq "$CR_THREAD_HUMAN_REPLY_COUNT"
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

@test "a null author login does not crash, and does not count as CR" {
	run _count '{"comments":{"nodes":[
	  {"author":{"login":"coderabbitai"},"body":"finding"},
	  {"author":null,"body":"ghost"}]}}'
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "BOTH consumers use the shared fragment, not a private copy" {
	# The point of the SSOT. If either re-inlines its own `[.comments.nodes[1:]`
	# filter, the two definitions can drift apart again silently.
	cd "$PLUGIN" || return 1
	local f
	for f in scripts/cr/thread-reply.sh hooks/_pr-cr-findings.sh; do
		run grep -c 'CR_THREAD_HUMAN_REPLY_COUNT' "$f"
		[ "$output" -ge 1 ] || {
			echo "$f no longer reads the shared predicate"
			return 1
		}
		# A re-inlined copy would reintroduce this literal shape.
		run bash -c "grep -c 'comments.nodes\[1:\]' '$f' || true"
		[ "$output" = "0" ] || {
			echo "$f re-inlined its own reply predicate — the two can now drift"
			return 1
		}
	done
}

@test "both consumers SOURCE the lib, so the fragment is always defined" {
	# Reading the variable without sourcing would silently expand to empty,
	# turning `select(<empty> == 0)` into a jq syntax error at runtime.
	cd "$PLUGIN" || return 1
	local f
	for f in scripts/cr/thread-reply.sh hooks/_pr-cr-findings.sh; do
		run grep -c 'cr-thread-state.sh' "$f"
		[ "$output" -ge 1 ] || {
			echo "$f uses the predicate without sourcing its SSOT"
			return 1
		}
	done
}
