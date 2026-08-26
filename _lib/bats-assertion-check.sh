#!/bin/bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`: sourcing scripts define their own option discipline.
#
# auto-register: false
# (#2631 follow-up) Detector for bats assertions that CANNOT FAIL.
#
# bats reports a failed test through an ERR trap. On bash 3.2 — the 2007
# build macOS ships at /bin/bash, frozen because bash 4.0 relicensed to
# GPLv3 — a failing `[[ ]]` fires NEITHER that trap NOR `set -e`, so the
# script continues and the test PASSES. One line to see it:
#
#   /bin/bash -c 'set -eET; trap "echo TRAP" ERR; [[ a == b ]]; echo REACHED'
#   → REACHED        (bash 5 prints TRAP and stops)
#
# So a bare `[[ ]]` only fails a test when it is the test's LAST command —
# and then for an unrelated reason: bats takes the final command's exit
# status as the test's. An assertion whose enforcement depends on its
# POSITION is not an assertion. Measured 749 such no-ops across 96 files
# when this was found; this detector stops the number growing.
#
# WORKS (fails the test wherever it appears):
#   [ "$status" -eq 0 ]                       single-bracket builtin
#   [[ $output == *x* ]] || return 1          the `||` supplies the failure
#   case "$output" in *x*) ;; *) return 1 ;; esac
#   assert_output_contains "x"                helper that returns non-zero
#
# DOES NOT WORK:
#   [[ $output == *x* ]]                      bare, not the last command
#
# KNOWN LIMITATION, stated rather than papered over: this reads PHYSICAL
# lines. A multi-line quoted string inside a test — a fixture that embeds
# bats source as data — puts literal `[[ ... ]]` at the start of real lines,
# and they are counted. This suite's own tests hit that immediately and were
# rewritten to build fixtures with single-line `printf` instead. Teaching the
# detector to parse shell quoting would trade a rare, obvious false positive
# for a subtle parser nobody trusts; keeping the rule "one physical line, one
# judgement" is worth more.
#
# bats_assertion_scan <file>
#   Prints one `line:text` per offending assertion. rc 0 = clean, 1 = found.
#   Comment lines, and the final command of each @test block, are exempt.
bats_assertion_scan() {
	local f="${1:-}"
	[ -n "$f" ] && [ -r "$f" ] || return 0
	awk '
		/^@test / { intest = 1; n = 0; delete ln; delete tx; next }
		intest && /^}/ {
			# Everything except the LAST recorded command is unguarded.
			for (i = 1; i < n; i++) print ln[i] ":" tx[i]
			intest = 0
			next
		}
		intest {
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line == "" || line ~ /^#/) next
			n++
			# Record every command; only bare `[[ ]]` ones are reportable,
			# but non-assertions still occupy the "last command" slot.
			if (line ~ /^\[\[ / && line !~ /\|\|/ && line !~ /&&/) {
				ln[n] = NR
				tx[n] = line
			} else {
				ln[n] = 0
				tx[n] = ""
			}
		}
	' "$f" | grep -v '^0:$' || true
}

# Returns 0 when the file has no unguarded mid-test `[[ ]]`.
bats_assertion_clean() {
	local out
	out=$(bats_assertion_scan "${1:-}")
	[ -z "$out" ]
}
