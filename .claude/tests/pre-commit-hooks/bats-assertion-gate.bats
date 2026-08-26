#!/usr/bin/env bats
# covers: pre-commit-hooks/bats-assertion-gate.sh _lib/bats-assertion-check.sh
# audits: .claude/tests/**/*.bats
#
# (#2631 follow-up) The gate that stops bats assertions which cannot fail.
# bats reports failure through an ERR trap, and on bash 3.2 — what macOS
# ships at /bin/bash, frozen since 2007 over the GPLv3 relicensing in bash
# 4.0 — a failing `[[ ]]` fires neither that trap nor `set -e`. So a bare
# `[[ ]]` only fails a test when it happens to be the block's LAST command.
# 749 such no-ops existed when this was found.
#
# These tests are written entirely in `[ ]` / `case` forms, for the obvious
# reason: a suite guarding this property must not depend on the property
# being fixed first.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	LIB="$REPO_ROOT/_lib/bats-assertion-check.sh"
	[ -r "$LIB" ]
	GATE="$REPO_ROOT/pre-commit-hooks/bats-assertion-gate.sh"
	[ -r "$GATE" ]
	TEST_TMP=$(mktemp -d -t bats-assert-gate.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	case "${TEST_TMP:-}" in
	*/bats-assert-gate.*) rm -rf "$TEST_TMP" ;;
	esac
}

# $output becomes the hit count. The subshell must exit 0 for the count to be
# trustworthy, so the pipeline's own rc is checked separately from the
# detector's — an earlier form ended `|| true`, which pinned status to 0 and
# made the `[ "$status" -eq 0 ]` below unfalsifiable.
_scan() { # $1 = file contents; echoes the detector's hit count
	printf '%s' "$1" >"$TEST_TMP/probe.bats"
	run bash -c '
		. "$1"
		out=$(bats_assertion_scan "$2") || rc=$?
		case "${rc:-0}" in
		0 | 1) ;;
		*) exit 9 ;;
		esac
		printf "%s\n" "$out" | grep -c . || true
	' _ "$LIB" "$TEST_TMP/probe.bats"
	[ "$status" -eq 0 ] || {
		echo "scan errored (status $status): $output"
		return 1
	}
}

# A miniature repo with the gate and lib in place, one .bats file STAGED.
_staged_repo() { # $1 = dir name, $2 = .bats contents
	local work="$TEST_TMP/$1"
	mkdir -p "$work/.claude/tests" "$work/_lib" "$work/pre-commit-hooks"
	cp "$LIB" "$work/_lib/"
	cp "$GATE" "$work/pre-commit-hooks/"
	printf '%s' "$2" >"$work/.claude/tests/new.bats"
	(
		cd "$work" || exit 1
		git init -q
		git add -A
	) || return 1
	echo "$work"
}

@test "a bare mid-test [[ ]] is reported" {
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
}

@test "the LAST command in a block is exempt — its status IS the test status" {
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n}\n')"
	[ "$output" -eq 0 ]
}

@test "forms that DO fail are not reported" {
	# Each of these fails the test wherever it sits, so none is a finding.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ]\n\t[[ $output == *"hi"* ]] || return 1\n\tcase "$output" in *hi*) ;; *) return 1 ;; esac\n\tassert_output_contains "hi"\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "&& is NOT a guard — it fires on no bash, and is reported" {
	# `[[ a ]] && cmd` puts the failing conditional in non-last position of an
	# AND-list, where neither the ERR trap nor `set -e` fires. It reads like a
	# guard. The gate shipped accepting it; one real assertion hid behind it.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] && true\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
}

@test "a guard inside a trailing COMMENT is not a guard" {
	# The shape 31 assertions shipped in:
	#     [[ $output == *"x"* ]]   # what this checks || return 1
	# The `||` is inside the comment, so nothing guards the assertion — and a
	# detector that scanned the whole line for `||` called it clean. The bug
	# concealed itself. Anchoring on the closing `]]` is what fixes it.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]]   # checked || return 1\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
}

@test "a real guard followed by a comment IS accepted" {
	# The correct shape, and the counterpart to the test above: anchoring must
	# not swing the other way and reject a guard that has a comment after it.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]] || return 1   # what this checks\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "a # inside a quoted pattern does not hide a real guard" {
	# Only text after the FINAL `]]` is comment-stripped, so a `#` inside the
	# match pattern cannot swallow the guard that follows it.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"a # b"* ]] || return 1\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "comments and blank lines do not occupy the last-command slot" {
	# A trailing comment must not make the real final assertion look mid-test.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n\t# trailing comment\n\n}\n')"
	[ "$output" -eq 0 ]
}

@test "multiple offenders in one block are all reported" {
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"a"* ]]\n\t[[ $output == *"b"* ]]\n\t[[ $output == *"c"* ]]\n\ttrue\n}\n')"
	[ "$output" -eq 3 ]
}

@test "each @test block is scored independently" {
	_scan "$(printf '@test "one" {\n\trun echo hi\n\t[[ $output == *"a"* ]]\n\ttrue\n}\n\n@test "two" {\n\trun echo hi\n\t[[ $output == *"b"* ]]\n}\n')"
	# One offender in the first block; the second block ends on its assertion.
	[ "$output" -eq 1 ]
}

@test "the gate REFUSES a staged file with an assertion that cannot fail" {
	local work
	work=$(_staged_repo repo1 "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]]\n\ttrue\n}\n')") || return 1
	run bash -c "cd '$work' && ./pre-commit-hooks/bats-assertion-gate.sh"
	[ "$status" -eq 2 ]
	case "$output" in
	*"cannot fail"*) ;;
	*)
		echo "expected the gate to name the problem; got: $output"
		return 1
		;;
	esac
}

@test "the gate PASSES a file that is clean" {
	local work
	work=$(_staged_repo repo2 "$(printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ]\n\ttrue\n}\n')") || return 1
	run bash -c "cd '$work' && ./pre-commit-hooks/bats-assertion-gate.sh"
	[ "$status" -eq 0 ]
	# Silent, too. A clean staged run that emitted a warning or a skip notice
	# would still exit 0, so status alone cannot distinguish "gate ran and
	# found nothing" from "gate bailed out early and said so".
	[ -z "$output" ] || {
		echo "expected no output on a clean run; got: $output"
		return 1
	}
}

@test "the gate scans the STAGED blob, not the worktree" {
	# Staging bad content and then cleaning the worktree copy must not pass:
	# the commit records the index, so the index is what has to be gated. The
	# `pre-commit` framework stashes unstaged changes and hides this, but a
	# raw .git/hooks install — what consumers get — does not.
	local work
	work=$(_staged_repo repo3 "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]]\n\ttrue\n}\n')") || return 1
	# Worktree now looks innocent; the index still holds the bare assertion.
	printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ]\n\ttrue\n}\n' \
		>"$work/.claude/tests/new.bats"
	run bash -c "cd '$work' && ./pre-commit-hooks/bats-assertion-gate.sh"
	[ "$status" -eq 2 ] || {
		echo "gate read the worktree, not the index — staged content was not gated"
		echo "output: $output"
		return 1
	}
}

@test "the whole suite is clean — zero assertions that cannot fail" {
	# The invariant is absolute, so it is asserted directly rather than
	# through a baseline file. The baseline this shipped with lived at a
	# gitignored path: it read as empty on every machine but the author's,
	# which made the debt gate inert exactly where it mattered while looking
	# active. Zero needs no file.
	cd "$REPO_ROOT" || return 1
	run ./pre-commit-hooks/bats-assertion-gate.sh --all
	[ "$status" -eq 0 ] || {
		echo "assertions that cannot fail on bash 3.2 are present:"
		echo "$output"
		return 1
	}
}

@test "an unreadable file is an ERROR (rc 2), never a clean bill of health" {
	# It returned 0 — "no problems found" — for a missing path, an unreadable
	# path and an empty argument alike. A detector whose failure mode is a
	# green light is worse than no detector: the caller commits on it.
	run bash -c '. "$1"; bats_assertion_scan "$2"' _ "$LIB" "$TEST_TMP/does-not-exist.bats"
	[ "$status" -eq 2 ] || {
		echo "expected rc 2 for an unreadable file, got $status"
		return 1
	}
	run bash -c '. "$1"; bats_assertion_scan ""' _ "$LIB"
	[ "$status" -eq 2 ] || {
		echo "expected rc 2 for an empty argument, got $status"
		return 1
	}
}

@test "rc distinguishes clean (0) from findings (1)" {
	# Documented as `rc 0 = clean, 1 = found` from the start, but a trailing
	# `|| true` made it unconditionally 0, so every caller had to re-derive
	# the verdict from whether stdout was empty.
	printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ]\n\ttrue\n}\n' >"$TEST_TMP/clean.bats"
	run bash -c '. "$1"; bats_assertion_scan "$2"' _ "$LIB" "$TEST_TMP/clean.bats"
	[ "$status" -eq 0 ] || {
		echo "clean file should be rc 0, got $status"
		return 1
	}
	printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"hi"* ]]\n\ttrue\n}\n' >"$TEST_TMP/dirty.bats"
	run bash -c '. "$1"; bats_assertion_scan "$2"' _ "$LIB" "$TEST_TMP/dirty.bats"
	[ "$status" -eq 1 ] || {
		echo "file with findings should be rc 1, got $status"
		return 1
	}
}

@test "helper functions, setup and teardown are scanned too" {
	# Only `@test` blocks were examined, so a bare `[[ ]]` in a helper — which
	# runs in the test's context and is a no-op for exactly the same reason —
	# was invisible. This suite's own teardown carried one.
	_scan "$(printf 'teardown() {\n\t[[ $TEST_TMP == */x.* ]]\n\ttrue\n}\n')"
	[ "$output" -eq 1 ] || {
		echo "teardown was not scanned"
		return 1
	}
	_scan "$(printf '_helper() {\n\t[[ $1 == a ]]\n\ttrue\n}\n')"
	[ "$output" -eq 1 ] || {
		echo "a file-local helper was not scanned"
		return 1
	}
}

@test "&& CONTROL FLOW is allowed; && used as an assertion is not" {
	# The distinction is intent, and it is visible in the right-hand side.
	# `&& return 0` early-exits a search loop and behaves identically on every
	# bash. `&& [ ... ]` reads as "both must hold" and enforces neither.
	_scan "$(printf '_find() {\n\tlocal p\n\tfor p in "$@"; do\n\t\t[[ $1 == $p ]] && return 0\n\tdone\n\treturn 1\n}\n')"
	[ "$output" -eq 0 ] || {
		echo "control-flow && was reported as an assertion"
		return 1
	}
	_scan "$(printf '@test "x" {\n\trun echo 5\n\t[[ $output =~ ^[0-9]+$ ]] && [ "$output" -ge 1 ]\n\ttrue\n}\n')"
	[ "$output" -eq 1 ] || {
		echo "&& used as an assertion was not reported"
		return 1
	}
}

@test "a block that never closes is an ERROR, not a pass" {
	# The scan ends a block on `}` at column 0 — deliberately narrow, because
	# `^[ \t]*}` would also match the closing brace of the very common inline
	# `... || { echo ...; return 1; }`. The cost of the narrow rule is a block
	# that never terminates, and that must not report clean.
	# Built with a single-line printf, per the lib's stated limitation: a
	# multi-line heredoc would put a literal `[[ ` at the start of a real line
	# in THIS file and the repo-wide sweep would count it as a finding here.
	printf '@test "never closed" {\n\trun echo hi\n\t[ -n "$output" ]\n' \
		>"$TEST_TMP/unterminated.bats"
	run bash -c '. "$1"; bats_assertion_scan "$2"' _ "$LIB" "$TEST_TMP/unterminated.bats"
	[ "$status" -eq 2 ] || {
		echo "an unterminated block reported rc $status; expected 2"
		return 1
	}
}

@test "the common inline || { ... } block does not end the scan early" {
	# The counterpart to the test above: this shape is everywhere in this
	# repo, and its indented closing brace must NOT be read as the end of the
	# @test block — that would hide every assertion after it.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[ "$status" -eq 0 ] || {\n\t\techo "boom"\n\t\treturn 1\n\t}\n\t[[ $output == *"hi"* ]]\n\ttrue\n}\n')"
	[ "$output" -eq 1 ] || {
		echo "an assertion after an inline || { } block was missed"
		return 1
	}
}

@test "|| with a fallback that SUCCEEDS is not a guard" {
	# The subtle one. It looks like a guard and prints on failure, but the
	# echo succeeds, so the OR-list returns 0 and — being non-last — its
	# status is discarded anyway. Verified directly:
	#   bash -c 'set -eET; trap "echo TRAP" ERR;
	#            t(){ [[ a == b ]] || echo warn; echo REACHED; }; t'
	#   -> warn / REACHED   (no TRAP, on 3.2 AND 5)
	# Accepting any `||` let this through; the operator is not what matters,
	# whether the right-hand side ENDS the block is.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] || echo warn\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
}

@test "|| { ... return 1; } across lines IS a guard" {
	# The commonest guard shape in this repo. The terminator is inside the
	# brace group, on a later physical line, so a line-at-a-time rule cannot
	# see it — the detector defers the verdict and resolves it at the closing
	# brace. Getting this wrong reported 82 false positives in one sweep.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] || {\n\t\techo "why"\n\t\treturn 1\n\t}\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "|| { ... } with NO terminator inside is still reported" {
	# Same shape, but the block only prints. Nothing fails the test, so the
	# deferred verdict must come back as a finding.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] || {\n\t\techo "just noise"\n\t}\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
}

@test "a nested brace group does not close the outer guard early" {
	# Depth counting: an inner `{ }` inside the guard body must not be read
	# as the outer group's close, which would resolve the verdict before the
	# terminator is reached.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] || {\n\t\tif true; then { echo a; }; fi\n\t\treturn 1\n\t}\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "|| return 0 is not a guard; && return 0 is" {
	# `|| return 0` fires exactly when the condition FAILED, and hands back
	# success — the same hole as `|| echo warn`, wearing a terminator. But
	# `&& return 0` reaches its zero only when the condition HELD, which is
	# ordinary early-exit control flow. The operator decides which zero is
	# legitimate, so the rule cannot key on `return` alone.
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] || return 0\n\ttrue\n}\n')"
	[ "$output" -eq 1 ]
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] && return 0\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
	_scan "$(printf '@test "x" {\n\trun echo hi\n\t[[ $output == *"nope"* ]] || return 1\n\ttrue\n}\n')"
	[ "$output" -eq 0 ]
}

@test "a bare [ ] DOES fail a real bats test — the helper forms need no guard" {
	# Locked in because CR-CLI asked four times for `|| return 1` on bare
	# single-bracket assertions. It is not needed, and this asserts it against
	# the real harness rather than a simulation: `[` is an ordinary simple
	# command, so errexit and the ERR trap apply to it in any position. Only
	# `[[ ]]`, a shell conditional expression, is special-cased — which is the
	# entire premise of this gate.
	mkdir -p "$TEST_TMP/real"
	printf '#!/usr/bin/env bats\n@test "t" {\n\t[ 1 -eq 2 ]\n\techo REACHED_PAST_IT\n\ttrue\n}\n' \
		>"$TEST_TMP/real/probe.bats"
	run bats --tap "$TEST_TMP/real/probe.bats"
	[ "$status" -ne 0 ] || {
		echo "a bare [ ] did NOT fail the test — the premise of this gate is wrong"
		return 1
	}
	case "$output" in
	*REACHED_PAST_IT*)
		echo "execution continued past a failed [ ] — it is not enforcing"
		return 1
		;;
	esac
}
