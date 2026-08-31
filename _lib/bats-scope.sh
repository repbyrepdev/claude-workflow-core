#!/bin/bash
# bats-required: 0
set -u
# (#2642) SSOT for "which shell files does the bats discipline apply to".
#
# WHY THIS EXISTS
#
# The answer lived in three places, byte-identical, and was wrong in all
# three:
#
#   pre-commit-hooks/bats-gate.sh:99      the COMMIT gate
#   hooks/pre-push-pipeline-gate.sh:773   the PUSH gate
#   scripts/test.sh:211                   the --coverage denominator
#
#     .claude/scripts/* | .claude/hooks/* | .claude/skills/* |
#     .claude/local-backups/* | scripts/*
#
# Those are CONSUMER paths. In the plugin's own repo, production lives at
# hooks/, _lib/, pre-commit-hooks/, skills/ and scripts/, and the .claude/*
# equivalents are untracked symlinks into the root — `git ls-files
# .claude/hooks` returns zero entries. So the list matched `scripts/` and
# nothing else: 50 of 229 production files, 22%.
#
# The consequences were not symmetric. The commit gate silently allowed a
# touched `hooks/*.sh` with no covering test. The push gate — which hashes
# the blob and demands a pass row recorded at THAT content, the strongest
# check in the repo — never looked at 78% of what it was guarding. And
# --coverage reported a percentage over the same wrong denominator, which
# is why the scope defect stayed invisible: it printed ~60%, and the true
# figure across everything was 58.5%. A near-coincidence hid it.
#
# Three copies is also how it stayed wrong. Fixing any one of them leaves
# the other two lying, and nothing compared them. One predicate now; the
# duplicate-arm check in .claude/tests/_lib/bats-scope.bats is what keeps
# it one.
#
# SCOPE CHOICE
#
# Both layouts are listed — the plugin's own root dirs and the consumer's
# .claude/* install paths — because one library serves both and a path
# that does not exist in a given repo simply never matches.
#
# The tradeoff, stated rather than hidden: a consumer repo with its own
# unrelated `hooks/` or `_lib/` at the root now has those files gated too.
# That is deliberate. Under-enforcement is the live bug being fixed, the
# per-file opt-out (`# bats-required: 0`) is one line, and TEST_GATE_SKIP
# with a recorded reason covers the rest. A consumer that wants the
# narrower rule sets BATS_SCOPE_DIRS.
#
# NOT IN SCOPE, deliberately:
#   .claude/tests/*   the tests themselves (Layer 2 of the gate owns those)
#   .git/*            hooks git generates
#   node_modules/*    vendored anything

# Override for consumers that want a different set. Space-separated
# directory prefixes, no trailing slash.
BATS_SCOPE_DIRS=${BATS_SCOPE_DIRS:-"hooks _lib pre-commit-hooks skills scripts .claude/scripts .claude/hooks .claude/skills .claude/_lib .claude/pre-commit-hooks .claude/local-backups"}

# bats_in_scope <path>
#   rc 0 = the bats discipline applies to this file
#   rc 1 = out of scope
#
# Takes a repo-relative path. Only *.sh is ever in scope; the callers
# already filter, and checking here means a future caller cannot forget.
bats_in_scope() {
	local p=${1:-}
	[ -n "$p" ] || return 1
	case "$p" in
	*.sh) ;;
	*) return 1 ;;
	esac
	# Tests are Layer 2's business, and .git/ is not ours at all.
	case "$p" in
	.claude/tests/* | .git/* | node_modules/*) return 1 ;;
	esac
	local d
	for d in $BATS_SCOPE_DIRS; do
		case "$p" in
		"$d"/*) return 0 ;;
		esac
	done
	return 1
}

# bats_scope_roots
#   Echoes, one per line, the scope directories that EXIST here — for
#   `find` and friends. `find` returns rc 1 on a missing starting path,
#   and under pipefail that aborts the caller (v0.9.4 #53 fixed exactly
#   that bug in scripts/test.sh); filtering first is what keeps it fixed.
bats_scope_roots() {
	local d
	for d in $BATS_SCOPE_DIRS; do
		[ -d "$d" ] && printf '%s\n' "$d"
	done
	return 0
}
