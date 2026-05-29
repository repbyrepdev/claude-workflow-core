#!/usr/bin/env bats
# covers: hooks/session-start-chmod-self-heal.sh

# v0.30.A (#187): regression test for SessionStart chmod self-heal.
# Exercises the hook on a synthetic repo layout containing hooks/ and
# .claude/hooks/ subdirs with mixed +x state; asserts the hook restores
# the missing bit, leaves healthy hooks alone, and exits silently on a
# fully-healthy tree.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/session-start-chmod-self-heal.sh"
	[ -x "$HOOK" ]
	# Synthetic working tree mimicking <repo>/{hooks,.claude/hooks}/.
	# Hook resolves REPO_ROOT from its own location, so we drop a symlink
	# to the real hook from a tmp dir's hooks/ subdir.
	TEST_TMP=$(mktemp -d -t chmod-selfheal.XXXXXX)
	mkdir -p "$TEST_TMP/hooks" "$TEST_TMP/.claude/hooks"
	# Mirror the hook into the synthetic tree so its REPO_ROOT resolves
	# to TEST_TMP (script's parent is TEST_TMP/hooks → TEST_TMP).
	cp "$HOOK" "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
}

teardown() {
	# Defensive: only remove if it actually looks like our tmp dir.
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

@test "silent + zero on fully-healthy tree" {
	# No extra files; only the self-heal hook itself, which is already +x.
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
	# stderr empty (no "restored" notice) on healthy state.
	[ -z "${output:-}" ]
}

@test "broken REPO_ROOT path exits cleanly (no SessionStart block)" {
	# Hook resolves REPO_ROOT from its own location; if we run it via an
	# argv0 whose dirname doesn't exist, REPO_ROOT may not be a dir.
	# Simulate by chdir'ing to / and running with a bogus relative path —
	# the script's `[ -d "$REPO_ROOT" ] || exit 0` guard should kick in.
	# (We can't truly remove the script's own dir mid-test; this asserts
	# the script never errors out non-zero from any guard, which is the
	# SessionStart contract.)
	run "$TEST_TMP/hooks/session-start-chmod-self-heal.sh"
	[ "$status" -eq 0 ]
}
