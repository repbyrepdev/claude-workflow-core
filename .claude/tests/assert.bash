# Shared bats assertion helpers. `load ../assert` (or `load ../../assert`,
# depending on depth) from any suite under .claude/tests.
#
# WHY THESE EXIST (#2631): a bare `[[ ]]` only fails a bats test when it is
# the block's LAST command. bats reports failure through an ERR trap, and on
# bash 3.2 — the 2007 build macOS ships at /bin/bash, frozen because bash 4.0
# relicensed to GPLv3 — a failing `[[ ]]` fires neither that trap nor
# `set -e`. See _lib/bats-assertion-check.sh for the one-line demonstration.
#
# `case` fails correctly on every bash, and an explicit `return 1` makes the
# failure independent of position. These wrap that so a suite reads as
# assertions rather than as control flow, and print BOTH sides on failure —
# a bats failure otherwise shows only the line that failed, not the value.
#
# Named `assert_*` because that is the bats convention AND what
# pre-commit-hooks/bats-gate.sh counts, so replacing a fragile check with a
# real one reads as the strengthening it is rather than as assertion removal.
#
# Extracted from five suites carrying byte-identical copies (#2631 phase-1
# review): a fix or rename to the assertion semantics had to be applied N
# times, and every new suite copy-pasted an N+1th.

# shellcheck disable=SC2154  # $output is set by bats' `run`, not by this file.
assert_output_contains() { # $1 = substring $output must contain
	case "$output" in
	*"$1"*) return 0 ;;
	esac
	echo "expected to find: $1"
	echo "actual output   : $output"
	return 1
}

# shellcheck disable=SC2154  # $output is set by bats' `run`, not by this file.
assert_output_lacks() { # $1 = substring $output must NOT contain
	case "$output" in
	*"$1"*)
		echo "expected NOT to find: $1"
		echo "actual output       : $output"
		return 1
		;;
	esac
	return 0
}
