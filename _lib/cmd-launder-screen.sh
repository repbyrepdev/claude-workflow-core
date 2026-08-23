#!/usr/bin/env bash
set -u
# NB: sourced lib → `set -u` only, never `-e`/`-o pipefail` (would mutate the
# sourcing hook's errexit). Matches the convention of the other _lib helpers.
#
# v0.34.124 (#2535 phase2): SSOT for "could this command smuggle a mutation past
# a verb allowlist?"
#
# WHY IT IS SHARED: phase1-directive-pending-guard.sh and
# phase1-log-pending-gate.sh both admit `review-log.sh` as their escape hatch,
# and both must screen it identically — otherwise the SAME command is allowed by
# one gate and denied by the other depending on which fires first. That is
# exactly what happened: the guard's copy strips harmless discard redirects
# (`2>/dev/null`, `2>&1`, `>/dev/null`) before looking for metacharacters, while
# the gate's inline copy did not, so `review-log.sh … 2>/dev/null` was allowed
# by one and refused by the other. Two copies of a security predicate WILL drift;
# this is the one definition.
#
# cmd_launders_mutation <command-string>
#   rc 0 = the command contains a construct that could hide a mutation:
#          a statement separator / background / pipe / backtick, command or
#          process substitution, or a SURVIVING file redirect.
#   rc 1 = clean.
#
# Harmless discard/dup redirects are STRIPPED FIRST so a benign `… 2>/dev/null`
# is not flagged; only a real file-writing redirect survives to the match.
# Newlines fold to `;` because the match is line-oriented — a second-line command
# (`… next`⏎`git commit`) is otherwise invisible to a per-line reject.
cmd_launders_mutation() {
	printf '%s' "$1" |
		sed -E 's/2>&1/ /g; s/(&|[0-9]*)>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g' |
		tr '\n' ';' |
		grep -qE '[;&|`]|\$\(|<\(|[0-9]*>'
}
