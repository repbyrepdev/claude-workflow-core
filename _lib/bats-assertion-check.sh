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
#   Prints one `line:text` per offending assertion.
#   rc 0 = clean · 1 = findings · 2 = the file could not be read.
#
#   The rc-2 case is separate on purpose. It previously shared rc 0 with
#   "clean", so a missing path, an unreadable path or an empty argument all
#   reported the file as having no problems — a detector whose failure mode
#   is a clean bill of health. Callers run under `set -e`, so capture as
#   `out=$(bats_assertion_scan "$f") || rc=$?` and branch on the code.
#
#   Blocks scanned: `@test` bodies AND file-local functions (setup, teardown,
#   helpers). A bare `[[ ]]` in a helper is a no-op for exactly the same
#   reason — the helper runs in the test's context — and this suite's own
#   teardown carried one.
bats_assertion_scan() {
	local f="${1:-}" out rc=0
	if [ -z "$f" ]; then
		echo "bats_assertion_scan: no file given" >&2
		return 2
	fi
	if [ ! -r "$f" ]; then
		echo "bats_assertion_scan: cannot read '$f'" >&2
		return 2
	fi
	out=$(awk '
		# A guard only counts when it is in COMMAND position: after the
		# closing `]]`, and before any `#` that starts a trailing comment.
		#
		# Anchoring on the last `]]` rather than scanning the whole line is
		# what makes this exact. Testing the raw line for `||` exempted
		#     [[ $output == *"is STALE"* ]]     # ancestry check fired || return 1
		# because the `||` inside the comment satisfied the test — the guard
		# was never code, the assertion was still a no-op, and the detector
		# certified it clean. That is the self-concealing shape this whole
		# lib exists to catch, and it hid 31 of them. Anchoring also avoids
		# the opposite error: a `#` inside a quoted pattern is left alone,
		# because only text after the final `]]` is considered.
		function guard_pos(line,   i, p, tail, h) {
			p = 0
			for (i = 1; i < length(line); i++)
				if (substr(line, i, 2) == "]]") p = i
			if (p == 0) return ""
			tail = substr(line, p + 2)
			h = index(tail, "#")
			if (h > 0) tail = substr(tail, 1, h - 1)
			return tail
		}
		# A block is an `@test` body OR a file-local function — setup,
		# teardown, a helper. The rule is the same in all of them: a bare
		# `[[ ]]` is enforced only in last position, where its status becomes
		# the verdict for the whole block. Helpers went unscanned until now,
		# and the teardown of the suite covering THIS lib carried one.
		# (No apostrophes here: the awk program is single-quoted.)
		/^@test / || /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/ {
			intest = 1
			n = 0
			opened = NR
			delete ln
			delete tx
			next
		}
		intest && /^}/ {
			# Everything except the LAST recorded command is unguarded.
			for (i = 1; i < n; i++)
				if (ln[i] > 0) print ln[i] ":" tx[i]
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
			#
			# `&&` is accepted ONLY when its right-hand side is control flow
			# (`return`, `exit`, `break`, `continue`, `skip`, `fail`). The
			# distinction is intent, and it is visible:
			#
			#   [[ $path == $glob ]] && return 0     control flow — correct
			#   [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ]   an ASSERTION — a no-op
			#
			# The second shape reads as "both must hold" and enforces neither:
			# the failing `[[ ]]` is a non-last AND-list member, so nothing
			# fires on any bash. That exact line shipped here carrying a
			# comment saying it would "fail LOUD".
			g = guard_pos(line)
			if (line ~ /^\[\[ / && index(g, "||") == 0 &&
				g !~ /^[ \t]*&&[ \t]*(return|exit|break|continue|skip|fail)([ \t;)]|$)/) {
				ln[n] = NR
				tx[n] = line
			} else {
				ln[n] = 0
				tx[n] = ""
			}
		}
		END {
			# A block closes on `}` at column 0 — the shell convention this
			# repo writes, and deliberately narrow: `^[ \t]*}` would also
			# match the closing brace of the very common inline
			# `... || { echo ...; return 1; }`, silently ending the block
			# early. The cost of the narrow rule is a block that never
			# terminates, which would report clean. So say so instead: an
			# un-flushed block is an ERROR, not a pass.
			if (intest) {
				print opened ": UNTERMINATED block — no `}` at column 0;" \
					" the scan could not judge it"
				exit 3
			}
		}
	' "$f") || rc=$?
	case "$rc" in
	0) ;;
	3)
		# The deliberate signal from the END block: a block that never closed.
		printf '%s\n' "$out" >&2
		return 2
		;;
	*)
		# awk itself failed (bad file, I/O error). Reported as rc 2 even
		# though `out` is empty — the empty-output path below would otherwise
		# read a crashed scan as "clean", which is the one answer a detector
		# must never give when it did not run.
		echo "bats_assertion_scan: scan of '$f' failed (awk rc $rc)" >&2
		return 2
		;;
	esac
	[ -n "$out" ] || return 0
	printf '%s\n' "$out"
	return 1
}

# Executed directly rather than sourced: scan the paths given as arguments and
# exit on the worst rc seen (0 clean · 1 findings · 2 unjudgeable). When
# sourced, BASH_SOURCE[0] is this file while $0 is the sourcing script, so the
# block is skipped and only the function is defined.
#
# A detector worth trusting should be runnable on one file without a harness —
# for a bisect, for a single suite mid-edit, and as the real entry point that
# prove-yourself evidence has to invoke.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	_rc=0
	for _f in "$@"; do
		bats_assertion_scan "$_f" || {
			_this=$?
			[ "$_this" -gt "$_rc" ] && _rc=$_this
		}
	done
	exit "$_rc"
fi
