#!/bin/bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`: sourcing scripts define their own option discipline.
#
# auto-register: false
# (#2548) SSOT for ONE question: has a human replied to this CR thread yet?
#
# Two consumers read it and they must never disagree:
#
#   scripts/cr/thread-reply.sh   drives the cr-thread-reply STAGE — decides
#                                whether the cycle holds or advances.
#   hooks/_pr-cr-findings.sh     drives the MERGE GATE — decides whether the
#                                thread blocks the merge.
#
# Written twice, they drift, and the failure is silent and asymmetric: the
# stage advances believing everything is answered while the gate still blocks,
# or worse, the gate passes a thread the stage never asked anyone to address.
# Phase 0.5 flagged the duplication on the very commit that introduced it.
#
# THE RULE: a thread is `replied-awaiting-CR` when the LAST comment on it is
# from someone other than CodeRabbit. Otherwise it is `unaddressed`.
#
# POSITIONAL, not "any human comment exists" — that earlier form LATCHED OPEN.
# Verified against the real fragment: the sequence
#
#     coderabbitai: "bug here"
#     me:           "fixed in abc123"
#     coderabbitai: "No — still broken, the fix is not present"
#
# read as ANSWERED, so the merge gate stopped counting a thread on which CR had
# explicitly REJECTED the evidence. A reply permanently silenced the thread no
# matter what CR said next. Reading the last comment instead means CR's
# rebuttal puts the thread straight back into `unaddressed`, which is the
# whole point of replying rather than resolving.
#
# Read server-side, from the thread's own comments — never from a local log.
# Server state survives a session reset and cannot drift from the real PR.
#
# Both consumers need the predicate inside a larger jq program, so it is
# exported as a jq FRAGMENT rather than a function: one string, interpolated
# in both places, impossible to paraphrase differently.

# jq SOURCE TEXT, not a value — the `_JQ` suffix says so, because a name
# ending in COUNT reads like a number and invites `[ "$X" -gt 0 ]`, which
# would silently compare a string of jq code against an integer.
#
# Given a thread node as input, it emits 1 when the thread has been answered
# and 0 otherwise. Answered means BOTH:
#   - more than one comment exists (comment 0 is the finding itself, so a
#     lone opening comment is never an answer to itself), AND
#   - the LAST comment is not CodeRabbit's.
#
# The name says COUNT because callers compare it numerically and because it
# is the same shape the earlier counting form had; it is now 0-or-1.
#
# SC2089/SC2090 are suppressed deliberately: this variable holds jq SOURCE
# TEXT that is interpolated into a larger jq program, not a command line. The
# quotes inside are MEANT to reach jq literally — precisely the behaviour
# those checks warn about. Their suggested fix, an array, cannot be spliced
# into a jq expression at all.
# shellcheck disable=SC2089,SC2090
CR_THREAD_HUMAN_REPLY_COUNT_JQ='(((.comments.nodes // []) | length) as $n | if $n < 2 then 0 else (if ((((.comments.nodes // []) | last | .author.login) // "") | test("coderabbit"; "i")) then 0 else 1 end) end)'

# Deliberately the ONLY export. Boolean convenience forms
# (CR_THREAD_IS_REPLIED / _IS_UNADDRESSED) were defined here and used by
# neither consumer — unused API on a shared lib is the same dead surface that
# got removed from _lib/bats-assertion-check.sh earlier. Both call sites read
# this fragment and apply their own comparison, which is one concept, not two.
# shellcheck disable=SC2090
export CR_THREAD_HUMAN_REPLY_COUNT_JQ
