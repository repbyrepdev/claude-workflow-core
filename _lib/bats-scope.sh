#!/bin/bash
# (#2642) SSOT for "which shell files does the bats discipline apply to".
#
# NO `set -u` in this file. It is SOURCED, so an option set at the top level
# leaks into the caller and changes how the rest of ITS script behaves —
# three consumers, each with its own option contract. Every expansion in the
# body is guarded (`${1:-}`, `${BATS_SCOPE_DIRS-...}`), so the library does
# not need it; owning shell options is the caller's business.
#
# WHY THIS EXISTS
#
# The same directory SET lived in three places and was wrong in all three:
#
#   pre-commit-hooks/bats-gate.sh       the COMMIT gate
#   hooks/pre-push-pipeline-gate.sh     the PUSH gate
#   scripts/test.sh                     the --coverage denominator
#
# NOT byte-identical, and an earlier version of this comment said they were
# while quoting the case-glob spelling as if it were shared text. Two were
# `case` arms over `.claude/scripts/* | ... | scripts/*` (differing in
# indent and in whether they ended `;;`); the third was a space-separated
# word list with no globs at all. Only the SET of directories matched — a
# reader grepping test.sh for the quoted glob would have found nothing.
#
# Those are CONSUMER paths. In the plugin's own repo, production lives at
# hooks/, _lib/, pre-commit-hooks/, skills/ and scripts/. Of the six
# .claude/* entries the list named, three exist here as symlinks to the
# corresponding root directories (_lib, hooks, scripts) and three do not
# exist at all — and `git ls-files .claude/hooks` returns zero entries
# either way, because the tree is gitignored. So the list matched
# `scripts/` and nothing else: 50 of 229 production files, 22%.
#
# The consequences were not symmetric. The commit gate silently allowed a
# touched `hooks/*.sh` with no covering test. The push gate — which hashes
# the blob and demands a pass row recorded at THAT content, the strongest
# check in the repo — never looked at 78% of what it was guarding. And
# --coverage reported a percentage over the same wrong denominator, which
# is why the scope defect stayed invisible: it printed exactly 60% (30 of
# the 50 files it could see), while the true figure across all 229 was
# 58.95%. A near-coincidence hid it.
#
# (58.5% appeared here first and does not reproduce — 135/229 is 58.95%.
# Recomputed rather than rounded, because a measured claim that cannot be
# replayed is the kind of thing this file is about.)
#
# Three copies is also how it stayed wrong. Fixing any one of them leaves
# the other two lying, and nothing compared them. One predicate now.
#
# The duplicate-arm check in .claude/tests/_lib/bats-scope.bats narrows the
# ways a fourth copy can reappear; it does not make it impossible, and an
# earlier version of this comment claimed it did. It catches a re-introduced
# CASE-GLOB copy. It would not have caught the third copy this change
# removed, which was a word list.
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
# directory prefixes; a trailing slash is tolerated.
#
# `${VAR-default}`, NOT `${VAR:-default}`. The colon form substitutes the
# default when the variable is empty OR unset — so an operator who sets
# BATS_SCOPE_DIRS='' to turn the discipline OFF would silently get the full
# default list back, which is the opposite of what they asked for and
# indistinguishable from the variable being ignored. Only UNSET falls back.
BATS_SCOPE_DIRS=${BATS_SCOPE_DIRS-"hooks _lib pre-commit-hooks skills scripts .claude/scripts .claude/hooks .claude/skills .claude/_lib .claude/pre-commit-hooks .claude/local-backups"}

# bats_scope_is_empty
#   rc 0 when the configured scope matches nothing at all. The gates use it
#   to refuse rather than to pass every file silently.
#
#   BATS_SCOPE_DIRS='' is documented as the off switch, but a TYPO produces
#   the identical state — and an empty scope makes the commit gate return
#   success for every staged script and the push gate build an empty
#   in-scope list, with no bypass recorded and nothing said. That is the
#   discipline switching itself off, which is the one outcome this library
#   exists to prevent. Turning it off is fine; doing so invisibly is not.
# _bats_scope_each
#   Echoes the configured scope entries, one per line, normalised — trailing
#   slashes stripped, empties dropped, and GLOBBING DISABLED.
#
#   One iterator for every consumer, because the three that existed had
#   already drifted: bats_in_scope disabled globbing and the validators did
#   not, so `BATS_SCOPE_DIRS='hooks*'` expanded to a real directory during
#   validation (reported usable) while the matcher treated the wildcard
#   literally and selected nothing. Both gates then permitted every changed
#   script. Two predicates disagreeing about what the list SAYS is the same
#   class of defect as the three copies this whole file replaced.
_bats_scope_each() {
	local d _glob_was_off=0
	case "$-" in *f*) _glob_was_off=1 ;; esac
	set -f
	for d in ${BATS_SCOPE_DIRS-}; do
		while [ "${d%/}" != "$d" ]; do d=${d%/}; done
		[ -n "$d" ] && printf '%s\n' "$d"
	done
	[ "$_glob_was_off" -eq 1 ] || set +f
	return 0
}

bats_scope_is_empty() {
	local first
	first=$(_bats_scope_each | head -1)
	[ -z "$first" ]
}

# bats_scope_is_unusable
#   rc 0 when NOT ONE of the configured scope directories exists in this
#   repo — the signature of a typo or a stale override. rc 1 otherwise.
#
#   Checking that the list has non-empty tokens is not enough:
#   `BATS_SCOPE_DIRS=hooks_typo` passes that and selects nothing, which is
#   indistinguishable to every gate from the empty case. A typo is also far
#   likelier than the deliberate off switch.
#
#   But "selects no FILE" is the wrong test, and the first version used it.
#   A repo can legitimately have shell files none of which are in scope — a
#   consumer whose only .sh is vendored, or the bats-gate's own fixture,
#   where the sole tracked script is under vendor/. Refusing there turns a
#   correct answer ("nothing here needs gating") into a hard error, which
#   an existing test caught immediately.
#
#   What distinguishes a typo from a legitimately-empty selection is
#   whether the scope points at anything REAL: `hooks_typo` names a
#   directory that does not exist, while a consumer with only vendored
#   shell still has `scripts/` or `hooks/` on disk. So the question is
#   whether ANY configured directory is present, not whether any file was
#   selected.
bats_scope_is_unusable() {
	local d
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		# `[ -d "$d" ]` on the LITERAL entry — _bats_scope_each already
		# suppressed globbing, so a wildcard entry is tested as the literal
		# string it is, which is how bats_in_scope will treat it too.
		[ -d "$d" ] && return 1
	done <<EOF
$(_bats_scope_each)
EOF
	return 0
}

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
	# Same iterator as the validators, so all three agree about what the
	# list says — normalised, unglobbed, empties dropped.
	local d
	while IFS= read -r d; do
		[ -n "$d" ] || continue
		case "$p" in
		"$d"/*) return 0 ;;
		esac
	done <<EOF
$(_bats_scope_each)
EOF
	return 1
}

# bats_scope_files
#   Echoes, one per line, every TRACKED .sh in scope. rc 2 if git cannot
#   answer — never a silent empty list, which would read as "no files to
#   cover" and report 100% of nothing.
#
#   ASKS GIT, does not walk the filesystem. The authoritative answer to
#   "what shell files does this repo have" is `git ls-files`, and this
#   whole issue is a case study in why: the broken scope list was proven
#   wrong by `git ls-files .claude/hooks` returning 0 entries for a
#   directory that EXISTS on disk. A `find` over directories answers a
#   different question and gets it wrong in two ways —
#
#     .claude/hooks here is a SYMLINK (to an absolute path, not ../hooks).
#     find does not follow it, so today the two agree by accident. On a
#     consumer where that path is a real directory, find would count the
#     same files twice.
#
#     find also counts UNTRACKED files: build output, a colleague's
#     scratch script, an editor backup. None of those can carry a
#     covering test and none belong in a coverage denominator.
#
#   Phase 0.5 raised this twice, from two agents, against the derivation
#   rule: do not re-compute what an authoritative source already provides.
bats_scope_files() {
	# NUL-delimited, through a TEMP FILE rather than a command substitution.
	# `out=$(git ls-files -z ...)` silently drops every NUL — bash cannot
	# hold them in a variable — so the whole listing collapses into one
	# concatenated string, `read -d ''` finds no delimiter, and the function
	# returns NOTHING. Which reads as "no shell files in scope", i.e. a
	# coverage denominator of zero and a gate with nothing to gate. Caught
	# because --coverage printed 0 files immediately after the switch; had
	# it printed a plausible number this would have shipped.
	local tmp rc=0
	tmp=$(mktemp -t bats-scope-files.XXXXXX) || {
		echo "bats_scope_files: mktemp failed" >&2
		return 2
	}
	# git's own stderr is kept: "not a git repository" and "index file
	# corrupt" want completely different responses, and an rc alone cannot
	# tell them apart.
	local errf
	errf=$(mktemp -t bats-scope-err.XXXXXX) || errf="/dev/null"
	git ls-files -z -- '*.sh' >"$tmp" 2>"$errf" || rc=$?
	if [ "$rc" -ne 0 ]; then
		local detail=""
		[ "$errf" != "/dev/null" ] && [ -s "$errf" ] && detail=" — git said: $(head -c 200 "$errf")"
		echo "bats_scope_files: git ls-files failed (rc=$rc)${detail}. Refusing to report an empty file set, which would read as full coverage of nothing." >&2
		rm -f "$tmp"
		[ "$errf" != "/dev/null" ] && rm -f "$errf"
		return 2
	fi
	[ "$errf" != "/dev/null" ] && rm -f "$errf"
	local f
	while IFS= read -r -d '' f; do
		[ -n "$f" ] || continue
		bats_in_scope "$f" && printf '%s\n' "$f"
	done <"$tmp"
	rm -f "$tmp"
	return 0
}

# (No load-time self-check. An earlier version ended the file with one,
# reasoning that a truncated or half-written library should announce
# itself. It cannot: the check is the LAST statement, both definitions
# above it are unconditional, so any flow that reaches it has already
# executed both — and a genuinely truncated file does not contain the
# check either. Two agents showed the condition is unfalsifiable. The
# mechanism is the `command -v` guard each of the three consumers carries;
# reassurance the file cannot deliver is worse than none.)
