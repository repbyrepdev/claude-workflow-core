#!/bin/bash
# set-u: opt-out — sourced library; inherits the caller's set -u/-e options.
# auto-register: false
# v0.34.32 (#2237): SSOT for the phase1 directive PROTOCOL version.
#
# The phase1 nonce handshake spans two components that live on OPPOSITE
# sides of the consumer-propagation boundary:
#   - WRITER: scripts/ship-pr-cycle.sh `_write_phase1_directive_marker`
#             (run from the pinned plugin cache in a consumer) stamps
#             `phase1_directive_protocol` into the per-SHA state JSON.
#   - READER: hooks/ship-cycle-guard.sh (Agent path) validates it before
#             allowing a pr-review-toolkit Agent launch.
#
# Both source THIS constant so a version bump is a one-line edit and the two
# sides can detect a SKEW (a consumer running a stale local driver vs an
# advanced reader) and FAIL LOUD with a remediation message instead of the
# historical silent "no nonce" deadlock (#2237 root cause: the writer lived
# in un-propagated scripts/, so it rotted out of protocol with the
# SSOT-tracked reader).
#
# Bump this integer ONLY on an INCOMPATIBLE change to the directive/nonce/
# state contract (e.g. renaming the nonce field, changing the sentinel
# format). A bump makes every consumer still on the prior pin fail loud with
# "re-pin + refresh" until they converge — which is the desired behavior.
# shellcheck disable=SC2034  # sourced constant — consumed by ship-pr-cycle.sh + ship-cycle-guard.sh
SHIP_CYCLE_PHASE1_PROTOCOL=1
