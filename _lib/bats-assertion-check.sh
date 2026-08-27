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
# DELIBERATE BOUNDARY — the last command of a block is exempt, and that is
# a compromise, not a principle. Verified in real bats on both shells: a
# failing `[[ ]]` in final position DOES fail the test, because bats takes
# the block's last exit status. But by the rule three paragraphs up, an
# assertion that only enforces because of where it sits is not an assertion:
# add one line after it and it silently becomes a no-op.
#
# Closing that would mean appending `|| return 1` to 927 last-position
# assertions across this suite (measured, not estimated) — and would let
# this scanner drop its command-position bookkeeping entirely, since the
# rule would collapse to "a bare `[[ ]]` is never acceptable". That is the
# right end state and it is a separate, purely mechanical change; doing it
# inside the PR that established the rule would bury the rule under the
# migration. Recorded here so the number does not have to be rediscovered.
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
		# Blank out quoted spans, keeping the line length so positions still
		# line up. Everything downstream then judges CODE only — a keyword or
		# a bracket inside a message string is invisible.
		#
		# The backup reviewer on #2635 found why this matters: the terminator
		# check matched `fail` inside `echo "guard should fail here"`, so a
		# brace-group body that only PRINTED was accepted as a real guard.
		# This repo writes exactly those messages, so it was a matter of time.
		# A backslash escapes the NEXT character, inside a string or out of
		# it. Without that, `echo "he said \"fail\""` mis-pairs the quotes and
		# re-exposes the very word this blanking exists to hide.
		function strip_strings(line,   i, c, q, out, n) {
			q = ""
			out = ""
			n = length(line)
			for (i = 1; i <= n; i++) {
				c = substr(line, i, 1)
				if (c == "\\" && i < n) {
					out = out "  "
					i++
					continue
				}
				if (q == "") {
					if (c == "\"" || c == "'"'"'") {
						q = c
						out = out " "
					} else
						out = out c
				} else {
					if (c == q) q = ""
					out = out " "
				}
			}
			return out
		}
		# A `#` starts a comment only at the start of a word — bash treats
		# `*#tag*` as literal. Cutting at the FIRST `#` truncated such a
		# pattern and lost the closing `]]` with it, turning a guarded
		# assertion into a finding.
		function cut_comment(code,   i, c, prev, n) {
			n = length(code)
			for (i = 1; i <= n; i++) {
				c = substr(code, i, 1)
				if (c != "#") continue
				if (i == 1) return ""
				prev = substr(code, i - 1, 1)
				# A `#` opens a comment at any WORD boundary, not only after
				# whitespace: `;`, `&`, `|`, `(`, `)`, `<` and `>` all end the
				# preceding word. Checking space/tab alone left
				# `echo ignored;# return 1` visible, so the COMMENTED-OUT
				# terminator satisfied the brace-group check and a group that
				# can never fail was accepted.
				if (index(" \t;&|()<>", prev) > 0) return substr(code, 1, i - 1)
			}
			return code
		}
		# Code after the closing `]]`. Strings are blanked and any trailing
		# comment cut BEFORE the search, so neither a `#` inside a pattern nor
		# a literal `]]` inside a comment can move the anchor.
		function guard_pos(line,   code, i, p) {
			code = cut_comment(strip_strings(line))
			p = 0
			for (i = 1; i < length(code); i++)
				if (substr(code, i, 2) == "]]") p = i
			if (p == 0) return ""
			return substr(code, p + 2)
		}
		# A block is an `@test` body OR a file-local function — setup,
		# teardown, a helper. The rule is the same in all of them: a bare
		# `[[ ]]` is enforced only in last position, where its status becomes
		# the verdict for the whole block. Helpers went unscanned until now,
		# and the teardown of the suite covering THIS lib carried one.
		# (No apostrophes here: the awk program is single-quoted.)
		# All four shapes bash accepts, not just `name(){`. `f () {` (space
		# before the parens) and `function f {` (keyword, no parens) are
		# equally valid and were silently unscanned — intest stayed 0, so a
		# bare `[[ ]]` in such a body was neither reported nor flagged as an
		# unterminated block. A detector that quietly skips a whole syntax is
		# the same failure as one that reports clean on a file it cannot read.
		/^@test / ||
		/^[A-Za-z_][A-Za-z0-9_]*[ \t]*\([ \t]*\)[ \t]*\{/ ||
		/^function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\([ \t]*\))?[ \t]*\{/ {
			intest = 1
			n = 0
			opened = NR
			delete ln
			delete tx
			next
		}
		# `&& !pending`: while a brace group is open, a `}` at column 0 is
		# THAT group closing, not the block. Ending the block here would strand
		# the deferred verdict and stop scanning the rest of the test. The
		# pending handler below sees it instead, resolves the group, and
		# scanning continues.
		intest && /^}/ && !pending {
			# Belt and braces: a group somehow still open when the block does
			# end never found its terminator, so report it rather than drop it.
			if (pending > 0 && !pending_ok) {
				ln[pending] = pending_ln
				tx[pending] = pending_tx
			}
			pending = 0
			pending_ok = 0
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
			# EITHER operator counts only when its right-hand side actually
			# ENDS the block — return, exit, break, continue, skip, fail.
			# What matters is not which operator, but whether anything
			# non-zero survives to the block s verdict:
			#
			#   [[ x ]] || return 1     guard      — the return supplies it
			#   [[ x ]] || echo warn    NO-OP      — echo succeeds, list is 0
			#   [[ x ]] && return 0     control flow, correct on every bash
			#   [[ x ]] && [ y ]        NO-OP      — reads as "both must hold"
			#
			# The `||`-with-a-printing-fallback shape is the subtle one: it
			# looks like a guard, prints on failure, and enforces nothing,
			# because a non-last AND/OR list contributes no status.
			#
			# The brace-group form spans lines and is the commonest guard in
			# this repo, so it gets a bounded lookahead rather than a guess:
			#
			#   [[ x ]] || {          <- pending: verdict deferred
			#           echo "why"
			#           return 1      <- terminator found => it IS a guard
			#   }                     <- none found => report it
			# Resolve an open brace-group FIRST: while one is pending, these
			# lines are its body, not new assertions. A terminator anywhere
			# inside makes the deferred assertion a real guard. Depth-counted
			# so a nested group cannot close the outer one early.
			if (pending > 0) {
				# CODE only. Matching the raw line accepted a body that merely
				# printed the word — `echo "guard should fail here"` set this,
				# and the guard was certified while nothing terminated. Strings
				# are blanked and the comment cut before the test.
				pline = cut_comment(strip_strings(line))
				if (pline ~ /(^|[ \t;])(return|exit|break|continue|skip|fail|false)([ \t;)]|$)/)
					pending_ok = 1
				# Braces counted on the SAME stripped text. Counting the raw
				# line let `echo "}"` close the group early, resolving the
				# deferred verdict before the terminator was reached and
				# reporting a correctly guarded assertion.
				d = pline
				pending_depth += gsub(/\{/, "", d)
				d = pline
				pending_depth -= gsub(/\}/, "", d)
				if (pending_depth <= 0) {
					if (!pending_ok) {
						ln[pending] = pending_ln
						tx[pending] = pending_tx
					}
					pending = 0
					pending_ok = 0
				}
				ln[n] = 0
				tx[n] = ""
				next
			}
			# `|| return 0` and `|| exit 0` are NOT guards: the fallback fires
			# exactly when the condition failed, and hands back SUCCESS. Same
			# shape as `|| echo`, just less obvious. `&& return 0` is fine —
			# there the zero is reached only when the condition HELD.
			g = guard_pos(line)
			if (line !~ /^\[\[ /) {
				ln[n] = 0
				tx[n] = ""
			} else if (g ~ /\|\|[ \t]*(return|exit)[ \t]+0[ \t]*(;|$)/) {
				ln[n] = NR
				tx[n] = line
			} else if (g ~ /(\|\||&&)[ \t]*(return|exit|break|continue|skip|fail)([ \t;)]|$)/) {
				ln[n] = 0
				tx[n] = ""
			} else if (g ~ /(\|\||&&)[ \t]*\{[ \t]*$/) {
				# Defer: the brace-group body decides, above.
				pending = n
				pending_ln = NR
				pending_tx = line
				pending_depth = 1
				pending_ok = 0
				ln[n] = 0
				tx[n] = ""
			} else {
				ln[n] = NR
				tx[n] = line
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
	# Zero arguments is an ERROR, not a clean sweep. The loop body simply
	# never runs, so a bare invocation — or a glob that expanded to nothing —
	# would exit 0. This path is named above as the real entry point for
	# prove-yourself evidence, so an evidence command whose path list
	# silently collapsed would produce a pass: the same green-light-on-
	# nothing that bats_assertion_scan rejects with rc 2 for an empty
	# argument.
	if [ "$#" -eq 0 ]; then
		echo "usage: bats-assertion-check.sh <file.bats> [...]" >&2
		echo "  (no paths given — refusing to report a clean sweep of nothing)" >&2
		exit 2
	fi
	_rc=0
	for _f in "$@"; do
		bats_assertion_scan "$_f" || {
			_this=$?
			[ "$_this" -gt "$_rc" ] && _rc=$_this
		}
	done
	exit "$_rc"
fi
