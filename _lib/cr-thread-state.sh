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
# THE RULE: a thread is `replied-awaiting-CR` when at least one comment AFTER
# CodeRabbit's first is authored by someone who is not CodeRabbit. Otherwise
# it is `unaddressed`.
#
# Read server-side, from the thread's own comments — never from a local log.
# Server state survives a session reset and cannot drift from the real PR.
#
# Both consumers need the predicate inside a larger jq program, so it is
# exported as a jq FRAGMENT rather than a function: one string, interpolated
# in both places, impossible to paraphrase differently.

# Given a thread node as input, emits the count of non-CodeRabbit comments
# following the first. `> 0` means replied.
#
# SC2089/SC2090 are suppressed deliberately: this variable holds jq SOURCE
# TEXT that is interpolated into a larger jq program, not a command line. The
# quotes inside are MEANT to reach jq literally — precisely the behaviour
# those checks warn about. Their suggested fix, an array, cannot be spliced
# into a jq expression at all.
# shellcheck disable=SC2089,SC2090
CR_THREAD_HUMAN_REPLY_COUNT='([(.comments.nodes // [])[1:][] | select((.author.login // "") | test("coderabbit"; "i") | not)] | length)'

# Boolean forms, for readability at the call sites.
# shellcheck disable=SC2089,SC2090
CR_THREAD_IS_REPLIED="(${CR_THREAD_HUMAN_REPLY_COUNT} > 0)"
# shellcheck disable=SC2089,SC2090
CR_THREAD_IS_UNADDRESSED="(${CR_THREAD_HUMAN_REPLY_COUNT} == 0)"

# shellcheck disable=SC2090
export CR_THREAD_HUMAN_REPLY_COUNT CR_THREAD_IS_REPLIED CR_THREAD_IS_UNADDRESSED
