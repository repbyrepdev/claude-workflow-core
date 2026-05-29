#!/usr/bin/env bats
# covers: hooks/phase1-directive-pending-guard.sh
#
# Tests for v0.27.0 #173 Layer 1 self-heal.
# Full integration tests of the PreToolUse hook require the full plugin
# layout (_lib/ + dirname BASH_SOURCE resolution). Until a fixture
# harness exists for that, these tests assert the regression-guard
# patterns are present in the source.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/phase1-directive-pending-guard.sh"
	[ -f "$HOOK" ]
}

@test "Layer 1 origin/main reachability check present" {
	# v0.27.0 #173 Layer 1
	grep -q 'git merge-base --is-ancestor "\$sha" origin/main' "$HOOK"
}

@test "Layer 1 v0.28.0 #174 abandoned-commit check present" {
	# v0.28.0 #174 extension — for-each-ref --contains for any-local-ref
	grep -q 'git for-each-ref --contains "\$sha"' "$HOOK"
}

@test "Layer 1 v0.28.0 #174 hex-sha basename validation present" {
	# v0.28.x #174/#178 P1 r1 fix: validate basename is hex sha before
	# for-each-ref so editor swap files / .DS_Store don't trigger mass-rm
	grep -qF '$sha =~ ^[0-9a-f]{7,40}$' "$HOOK"
}
