#!/usr/bin/env bats
# covers: scripts/test-touched.sh scripts/refresh-from-source.sh
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
	run grep -cE '\^#\[\[:space:\]\]\*audits:' scripts/refresh-from-source.sh
	# grep -c exits 1 with a count of 0 when nothing matches; either shape is
	# fine as long as the count is zero.
	[ "$output" = "0" ] || {
		echo "the drift gate reads audits: — it must not"
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
	case "$output" in
	*"NOT yet parsed"*)
		echo "AGENTS.md still says audits: is unparsed"
		return 1
		;;
	esac
}
