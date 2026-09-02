#!/usr/bin/env bats
# covers: scripts/test-touched.sh
# audits: scripts/refresh-from-source.sh
#
# (#2572) The `# audits:` header. A repo-wide meta-lint sweeps many files
# without executing any of them, so it must ROUTE like `covers:` (re-run when
# a subject changes) while granting NO behavioural credit (it never ran the
# thing). Before the split a meta-lint had to either lie in `covers:` — which
# tells the mirror-drift gate that 40 hooks are verified by a policy scan — or
# omit them and silently drop out of change-triggered routing.
#
# Assertions here use `[ ]` / `case` / `|| return 1` so they fail on bash 3.2
# as well as 4/5. A suite guarding a test-infrastructure contract must not
# itself depend on the newest shell.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	TEST_TMP=$(mktemp -d -t audits-header.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */audits-header.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# A miniature repo: one hook, one suite that COVERS a lib, one suite that
# AUDITS the hooks. Committed, so `git diff` has a base to compare against.
_fixture() {
	local w="$TEST_TMP/repo"
	mkdir -p "$w/hooks" "$w/_lib" "$w/.claude/tests" "$w/scripts"
	cp "$REPO_ROOT/scripts/test-touched.sh" "$w/scripts/"
	printf '#!/bin/bash\nexit 0\n' >"$w/hooks/some-hook.sh"
	printf '#!/bin/bash\nexit 0\n' >"$w/_lib/some-lib.sh"
	printf '#!/usr/bin/env bats\n# covers: _lib/some-lib.sh\n@test "x" { true; }\n' \
		>"$w/.claude/tests/covers-only.bats"
	printf '#!/usr/bin/env bats\n# audits: hooks/*.sh\n@test "y" { true; }\n' \
		>"$w/.claude/tests/audits-only.bats"
	(
		cd "$w" || exit 1
		git init -q -b main
		git config user.email t@t
		git config user.name t
		git add -A
		git commit -q -m base
	) || return 1
	echo "$w"
}

@test "a touched hook ROUTES to the suite that audits it" {
	local w
	w=$(_fixture) || return 1
	# Change only the hook.
	printf '#!/bin/bash\nexit 1\n' >"$w/hooks/some-hook.sh"
	run env -u LIST_ONLY bash -c "cd '$w' && scripts/test-touched.sh --list --base HEAD"
	[ "$status" -eq 0 ] || {
		echo "test-touched failed: $output"
		return 1
	}
	case "$output" in
	*audits-only.bats*) ;;
	*)
		echo "the audits: suite did NOT route on its subject changing: $output"
		return 1
		;;
	esac
	# ...and the unrelated covers: suite does not.
	case "$output" in
	*covers-only.bats*)
		echo "an unrelated covers: suite routed: $output"
		return 1
		;;
	esac
}

@test "a touched lib ROUTES to the suite that covers it, not the auditor" {
	local w
	w=$(_fixture) || return 1
	printf '#!/bin/bash\nexit 1\n' >"$w/_lib/some-lib.sh"
	run env -u LIST_ONLY bash -c "cd '$w' && scripts/test-touched.sh --list --base HEAD"
	[ "$status" -eq 0 ] || {
		echo "test-touched failed: $output"
		return 1
	}
	case "$output" in
	*covers-only.bats*) ;;
	*)
		echo "the covers: suite did not route: $output"
		return 1
		;;
	esac
	case "$output" in
	*audits-only.bats*)
		echo "the hooks auditor routed on a lib change it does not audit: $output"
		return 1
		;;
	esac
}

@test "audits: globs match, so one line covers a whole directory" {
	local w
	w=$(_fixture) || return 1
	# A SECOND hook the audit never names individually.
	printf '#!/bin/bash\nexit 0\n' >"$w/hooks/another-hook.sh"
	(cd "$w" && git add -A && git commit -q -m second) || return 1
	printf '#!/bin/bash\nexit 1\n' >"$w/hooks/another-hook.sh"
	run env -u LIST_ONLY bash -c "cd '$w' && scripts/test-touched.sh --list --base HEAD"
	[ "$status" -eq 0 ] || return 1
	case "$output" in
	*audits-only.bats*) ;;
	*)
		echo "glob did not match a sibling hook: $output"
		return 1
		;;
	esac
}

@test "the coverage report gives NO credit for audits: paths" {
	# The whole point of the split: an audit sweeps without executing, so it
	# must not make its subjects look tested.
	cd "$REPO_ROOT" || return 1
	run grep -n 'COVERED_PATHS=' scripts/test.sh
	[ "$status" -eq 0 ] || return 1
	case "$output" in
	*audits*)
		echo "test.sh coverage reads audits: — that hands out false credit"
		return 1
		;;
	esac
	case "$output" in
	*covers*) ;;
	*)
		echo "expected the coverage scan to read covers:; got: $output"
		return 1
		;;
	esac
}

@test "the mirror-drift gate accepts covers: only, never audits:" {
	# A replaced mirror hook must be verified by a test that RAN it. A policy
	# scan that merely swept it is not that test.
	cd "$REPO_ROOT" || return 1
	run grep -c 'covers:' scripts/refresh-from-source.sh
	[ "$status" -eq 0 ] || return 1
	[ "$output" -gt 0 ] || return 1
	# CODE lines only. It was written `grep -cE '\^#\[\[:space:\]\]\*audits:'`
	# — every metacharacter escaped, so it searched for that literal text
	# rather than for the header, and could only ever report 0, which is what
	# it asserted. De-escaping it alone swings too far the other way: the
	# script explains in comments why it deliberately ignores `audits:`, and
	# an explanation is not a read. Strip comments, then look.
	run bash -c "grep -v '^[[:space:]]*#' scripts/refresh-from-source.sh | grep -c 'audits:' || true"
	[ "$output" = "0" ] || {
		echo "the drift gate reads audits: in code — it must not"
		return 1
	}
}

@test "the first user declares BOTH headers, each naming the right thing" {
	cd "$REPO_ROOT" || return 1
	local f=".claude/tests/_lib/event-frontmatter-audit.bats"
	[ -r "$f" ] || return 1
	run grep -m1 -E '^#[[:space:]]*covers:' "$f"
	[ "$status" -eq 0 ] || return 1
	case "$output" in
	*event-frontmatter.sh*) ;;
	*)
		echo "covers: should name the lib it executes; got: $output"
		return 1
		;;
	esac
	run grep -m1 -E '^#[[:space:]]*audits:' "$f"
	[ "$status" -eq 0 ] || {
		echo "the first user is missing its audits: header"
		return 1
	}
	case "$output" in
	*hooks/*) ;;
	*)
		echo "audits: should name the hooks it sweeps; got: $output"
		return 1
		;;
	esac
}

@test "AGENTS.md documents the convention as LIVE, not as pending" {
	# It shipped as "convention only — NOT yet parsed" with a warning against
	# migrating. Landing the parsers without correcting that leaves the docs
	# telling the next reader the opposite of what the code does.
	cd "$REPO_ROOT" || return 1
	run grep -n 'audits:' AGENTS.md
	[ "$status" -eq 0 ] || return 1
	# Search the WHOLE file for the stale phrase. Grepping for `audits:` first
	# and then inspecting only those lines made this nearly vacuous: the
	# disclaimer need only sit on a neighbouring line to survive.
	run grep -c 'NOT yet parsed' AGENTS.md
	[ "$output" = "0" ] || {
		echo "AGENTS.md still says audits: is unparsed"
		return 1
	}
}

@test "LIST_ONLY is a FLAG, not ambient state" {
	# It was read as `${LIST_ONLY:-0}` with no initialisation, so an exported
	# LIST_ONLY=1 anywhere upstream turned the runner into a lister: it printed
	# paths and exited 0 having run nothing, while callers that treat exit 0 as
	# "scoped tests passed" (scripts/cr/autofix-cycle.sh's post-pull re-test
	# gate, hooks/phase1-launcher.sh) stayed satisfied. LIST_ONLY is not
	# matched by hooks/skip-env-approval-gate.sh's `*_SKIP` pattern either, so
	# it silently disabled a gate with no operator approval.
	local w
	w=$(_fixture) || return 1
	printf '#!/bin/bash\nexit 1\n' >"$w/hooks/some-hook.sh"
	# With the env var set but the flag absent, the routing list must NOT be
	# what comes back — the script must go on to actually run something.
	run env LIST_ONLY=1 bash -c "cd '$w' && scripts/test-touched.sh --base HEAD"
	# Assert the run actually happened, rather than only complaining when a
	# path shows up without it — output matching NEITHER pattern would
	# otherwise pass, which is the shape of a test that cannot fail.
	case "$output" in
	*audits-only.bats*) ;;
	*)
		echo "the auditor did not route at all; fixture is wrong: $output"
		return 1
		;;
	esac
	case "$output" in
	*"running "*) ;;
	*)
		echo "LIST_ONLY=1 from the environment suppressed the run: $output"
		return 1
		;;
	esac
}

@test "covers: is matched EXACTLY, so it cannot route without earning credit" {
	# Routing globbed both headers, but the three credit-granting readers
	# (test.sh --coverage, bats-gate.sh, refresh-from-source.sh) match covers:
	# literally. A covers: glob would therefore route while satisfying no gate
	# — a partial behaviour nothing rejects and AGENTS.md contradicts.
	local w
	w=$(_fixture) || return 1
	printf '#!/usr/bin/env bats\n# covers: _lib/*.sh\n@test "z" { true; }\n' \
		>"$w/.claude/tests/covers-glob.bats"
	(cd "$w" && git add -A && git commit -q -m glob) || return 1
	printf '#!/bin/bash\nexit 1\n' >"$w/_lib/some-lib.sh"
	run env -u LIST_ONLY bash -c "cd '$w' && scripts/test-touched.sh --list --base HEAD"
	[ "$status" -eq 0 ] || return 1
	case "$output" in
	*covers-glob.bats*)
		echo "a covers: glob routed; covers: must be an exact path: $output"
		return 1
		;;
	esac
	# The exact-path suite still routes, so this is not just "nothing matched".
	case "$output" in
	*covers-only.bats*) ;;
	*)
		echo "the exact covers: suite stopped routing: $output"
		return 1
		;;
	esac
}

@test "--help documents every flag the parser accepts" {
	# --help printed a hardcoded `sed -n '4,30p'` range, which stopped covering
	# the header the moment a flag was documented in it: --list shipped absent
	# from its own help. Derived from the header now, so it cannot drift.
	cd "$REPO_ROOT" || return 1
	run scripts/test-touched.sh --help
	[ "$status" -eq 0 ] || return 1
	local flag
	for flag in --base --list --help; do
		case "$output" in
		*"$flag"*) ;;
		*)
			echo "--help does not mention $flag"
			return 1
			;;
		esac
	done
	# ...and it is help text, not the machine directives above it.
	case "$output" in
	*bats-required*)
		echo "--help leaked the # bats-required: directive"
		return 1
		;;
	esac
}

@test "--list answers with an empty list when nothing routes" {
	# The no-coverage branch exited 0 first, so --list printed an advisory to
	# stderr and nothing to stdout. "Nothing routes" is a valid answer to
	# --list and has to come back on stdout as the empty list it is.
	local w
	w=$(_fixture) || return 1
	# Touch a file no suite covers or audits.
	printf 'x\n' >"$w/README.md"
	(cd "$w" && git add -A && git commit -q -m readme) || return 1
	printf 'y\n' >"$w/README.md"
	run env -u LIST_ONLY bash -c "cd '$w' && scripts/test-touched.sh --list --base HEAD"
	[ "$status" -eq 0 ] || {
		echo "--list should exit 0 with nothing to list; got $status: $output"
		return 1
	}
	# EMPTY, not merely free of the advisory: unrelated output would
	# otherwise satisfy the case below and the test would pass on it.
	[ -z "$output" ] || {
		echo "--list should print nothing when nothing routes; got: $output"
		return 1
	}
	case "$output" in
	*"no-op"* | *"consider:"*)
		echo "--list emitted the no-coverage advisory instead of a list: $output"
		return 1
		;;
	esac
}

@test "BEHAVIOUR: audits: earns no coverage credit, covers: does" {
	# The counterpart to the source-grep test above, and the stronger claim:
	# not "the scan reads covers:" but "a path declared ONLY in audits: comes
	# back UNCOVERED, while one in covers: comes back covered". Asserted by
	# running the real --coverage against a fixture rather than by reading
	# its implementation.
	#
	# --coverage scans .claude/scripts|hooks|skills|local-backups and
	# scripts/, so the fixture puts both hooks under .claude/hooks/.
	local w="$TEST_TMP/covrepo"
	mkdir -p "$w/.claude/hooks" "$w/.claude/tests"
	printf '#!/bin/bash\nexit 0\n' >"$w/.claude/hooks/audited.sh"
	printf '#!/bin/bash\nexit 0\n' >"$w/.claude/hooks/covered.sh"
	printf '#!/usr/bin/env bats\n# audits: .claude/hooks/*.sh\n@test "a" { true; }\n' \
		>"$w/.claude/tests/auditor.bats"
	printf '#!/usr/bin/env bats\n# covers: .claude/hooks/covered.sh\n@test "c" { true; }\n' \
		>"$w/.claude/tests/coverer.bats"

	# (#2642) The fixture must be a real git repo with the files TRACKED.
	# bats_scope_files enumerates via `git ls-files` and refuses to report an
	# empty set when git errors, because an empty set reads as full coverage
	# of nothing — the exact false-green that refusal exists to prevent. A
	# bare mkdir tree made git exit 128 and tripped it. Tracking the files
	# also makes the fixture match production, where every scanned script is
	# committed; an untracked file is invisible to the inventory either way,
	# so a loose directory was never representative.
	# gpgsign/hooksPath overridden: a developer with commit signing or a
	# global hooksPath configured would otherwise have this fixture commit
	# fail or run their hooks, neither of which this test is about.
	(cd "$w" && git init -q &&
		git -c core.excludesFile=/dev/null add -A &&
		git -c user.email=t@t -c user.name=t -c commit.gpgsign=false \
			-c core.hooksPath=/dev/null -c core.excludesFile=/dev/null \
			commit -qm fixture) || {
		echo "could not make the coverage fixture a git repo"
		return 1
	}

	run env TEST_REPO_ROOT="$w" "$REPO_ROOT/scripts/test.sh" --coverage
	[ "$status" -eq 0 ] || {
		echo "--coverage failed: $output"
		return 1
	}
	# Two scripts in scope, exactly one of them credited — so the audited-only
	# one is not. 50%, not 100%: that difference IS the invariant.
	case "$output" in
	*"Shell scripts in scope: 2"*) ;;
	*)
		echo "fixture wrong — expected 2 scripts in scope: $output"
		return 1
		;;
	esac
	case "$output" in
	*"Coverage: 50%"*) ;;
	*)
		echo "audits: appears to have earned coverage credit: $output"
		return 1
		;;
	esac
	# `--coverage` reports counts, not paths, so the count is the assertion.
	# Pin the uncovered tally too: "Coverage: 50%" alone would also hold if
	# the scan credited the audited hook and missed the covered one.
	case "$output" in
	*"Covered (referenced in some .bats): 1"*) ;;
	*)
		echo "expected exactly 1 covered: $output"
		return 1
		;;
	esac
	case "$output" in
	*"Uncovered:"*"1"*) ;;
	*)
		echo "expected exactly 1 uncovered: $output"
		return 1
		;;
	esac
}
