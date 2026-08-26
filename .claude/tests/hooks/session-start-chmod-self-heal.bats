#!/usr/bin/env bats
# covers: hooks/session-start-chmod-self-heal.sh

# v0.30.A (#187): regression test for SessionStart chmod self-heal.
# Exercises the hook on a synthetic repo layout with mixed +x state;
# asserts the hook restores the missing bit, leaves healthy hooks alone,
# respects scope boundaries (only *.sh, only hooks/ + .claude/hooks/),
# and surfaces chmod failures on stderr.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/session-start-chmod-self-heal.sh"
	[ -x "$HOOK" ]
	# Synthetic working tree mimicking <repo>/{hooks,.claude/hooks}/.
	# Hook resolves REPO_ROOT from its own location, so we drop a copy
	# of the real hook into a tmp dir's hooks/ subdir.
	TEST_TMP=$(mktemp -d -t chmod-selfheal.XXXXXX)
	mkdir -p "$TEST_TMP/hooks" "$TEST_TMP/.claude/hooks"
	# Hook's REPO_ROOT sanity check requires .claude/ marker exists.
	[ -d "$TEST_TMP/.claude" ]
	cp "$HOOK" "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
}

teardown() {
	[ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

@test "restores +x on a hook that lost it" {
	echo '#!/bin/bash' >"$TEST_TMP/hooks/lost-bit.sh"
	chmod 644 "$TEST_TMP/hooks/lost-bit.sh"
	[ ! -x "$TEST_TMP/hooks/lost-bit.sh" ]
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[ -x "$TEST_TMP/hooks/lost-bit.sh" ]
}

@test "restores +x in .claude/hooks subtree too" {
	echo '#!/bin/bash' >"$TEST_TMP/.claude/hooks/lost-bit.sh"
	chmod 644 "$TEST_TMP/.claude/hooks/lost-bit.sh"
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[ -x "$TEST_TMP/.claude/hooks/lost-bit.sh" ]
}

@test "multi-subdir single invocation fixes BOTH dirs + counts correctly" {
	# Regression guard: a stray `break` in the outer for-loop would pass
	# the per-subdir isolated tests above but fail this combined case.
	echo '#!/bin/bash' >"$TEST_TMP/hooks/a.sh"
	echo '#!/bin/bash' >"$TEST_TMP/.claude/hooks/b.sh"
	chmod 644 "$TEST_TMP/hooks/a.sh" "$TEST_TMP/.claude/hooks/b.sh"
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[ -x "$TEST_TMP/hooks/a.sh" ]
	[ -x "$TEST_TMP/.claude/hooks/b.sh" ]
	# stderr should report "on 2 hook(s)" — guards off-by-one + double-count
	[[ $output == *"on 2 hook(s)"* ]]
}

@test "silent + zero on fully-healthy tree" {
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[ -z "${output:-}" ]
}

@test "non-.sh files are NOT touched (scope boundary guard)" {
	# Regression guard: a stray glob broadening (e.g. *.{sh,bash} or *)
	# would silently chmod README / configs / binaries. Drop a non-.sh
	# file at mode 644 and assert it stays 644 after the hook runs.
	echo "# readme" >"$TEST_TMP/hooks/README.md"
	chmod 644 "$TEST_TMP/hooks/README.md"
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[ ! -x "$TEST_TMP/hooks/README.md" ]
}

@test "directory named *.sh is NOT chmod'd (regular-file guard)" {
	# Regression guard: [ -f "$h" ] should reject directories that match
	# the *.sh glob. If a future refactor drops the -f check, a directory
	# would still be chmod-able (chmod follows -R isn't used here, but
	# chmod +x on a dir would change its searchability bit).
	mkdir "$TEST_TMP/hooks/notashook.sh"
	chmod 644 "$TEST_TMP/hooks/notashook.sh" 2>/dev/null || true
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	# Output must NOT mention the directory path (it shouldn't have been
	# in fixed[] OR failed[]).
	[[ $output != *"notashook.sh"* ]]
}

@test "missing one subdir does not break the other (per-subdir guard)" {
	# Regression guard: `[ -d "$d" ] || continue` becoming `break` would
	# cause the second iteration to be skipped silently when the first
	# subdir is missing. Delete the .claude/hooks/ subdir (keeping .claude/
	# itself so the REPO_ROOT marker check passes) and put a fixable file
	# in hooks/. The hook should skip the missing .claude/hooks/ via the
	# `[ -d ]` guard and still fix hooks/lost.sh.
	rm -rf "$TEST_TMP/.claude/hooks"
	[ -d "$TEST_TMP/.claude" ] # marker still present
	[ ! -d "$TEST_TMP/.claude/hooks" ]
	echo '#!/bin/bash' >"$TEST_TMP/hooks/lost.sh"
	chmod 644 "$TEST_TMP/hooks/lost.sh"
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[ -x "$TEST_TMP/hooks/lost.sh" ]
}

@test "broken script-dir resolution surfaces stderr + exits 0" {
	# Regression guard for the new fail-loud-but-non-blocking path:
	# when SCRIPT_DIR resolves to an empty/missing path, hook should
	# print a stderr notice and exit 0 (never block SessionStart).
	# Construct a path where dirname BASH_SOURCE doesn't have a .claude
	# sibling — the REPO_ROOT marker check refuses + emits warning.
	BARE=$(mktemp -d -t chmod-selfheal-bare.XXXXXX)
	mkdir -p "$BARE/hooks"
	cp "$HOOK" "$BARE/hooks/session-start-chmod-self-heal.sh"
	# No .claude/ created — REPO_ROOT marker check refuses.
	run "$BARE/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"missing .claude/ marker"* ]] || [[ $output == *"refusing self-heal"* ]] || return 1
	rm -rf "$BARE"
}

@test "REPO_ROOT/.claude existing as a regular file is REJECTED (-d guard)" {
	# Regression guard for the marker tightening from `-e` to `-d`
	# (CR-in-CI finding on PR #192). Under the old `-e` check, a regular
	# file at REPO_ROOT/.claude would pass and the hook would proceed to
	# chmod hooks/*.sh inside an unverified parent. The new `-d` check
	# correctly rejects this case. CRITICAL assertion: the non-executable
	# .sh under hooks/ must NOT be chmod'd — that's what distinguishes
	# `-d` from `-e` semantics. A revert to `-e` would silently re-open
	# the unverified-parent-dir chmod path and flip this assertion.
	BARE=$(mktemp -d -t chmod-selfheal-file-marker.XXXXXX)
	mkdir -p "$BARE/hooks"
	cp "$HOOK" "$BARE/hooks/session-start-chmod-self-heal.sh"
	# Create .claude as a REGULAR FILE — passes `-e` but fails `-d`.
	touch "$BARE/.claude"
	[ -f "$BARE/.claude" ]
	[ ! -d "$BARE/.claude" ]
	# Drop a non-executable .sh under hooks/ that the OLD guard would
	# have chmod'd; the new guard must refuse before touching it.
	echo '#!/bin/bash' >"$BARE/hooks/lost.sh"
	chmod 644 "$BARE/hooks/lost.sh"
	run "$BARE/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"missing .claude/ marker"* ]] || [[ $output == *"refusing self-heal"* ]] || return 1
	# THE LOAD-BEARING ASSERTION — chmod must NOT have run.
	[ ! -x "$BARE/hooks/lost.sh" ]
	rm -rf "$BARE"
}
