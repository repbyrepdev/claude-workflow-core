#!/usr/bin/env bats
# covers: _lib/canonical-consumer-skip.sh
# shellcheck disable=SC2030,SC2031  # bats @test bodies run in subshells; per-test cd is intentional + isolated
#
# #2235 consumer-aware canonical-skip: plugin gates must skip files that are
# byte-identical to the pinned canonical when running in a CONSUMER (validated
# upstream), but NEVER skip in the plugin itself or for modified/non-canonical
# files. The lib is copied into a synthetic <plugin>/_lib/ so its
# BASH_SOURCE-relative plugin-root resolution points at the fixture, and a
# separate synthetic <repo> (no plugin.json) plays the consumer.

setup() {
	LIB_SRC="${BATS_TEST_DIRNAME}/../../../_lib/canonical-consumer-skip.sh"
	[ -f "$LIB_SRC" ]
	TEST_TMP=$(mktemp -d -t ccs.XXXXXX) || return 1
	PLUGIN="$TEST_TMP/plugin"
	REPO="$TEST_TMP/repo"
	mkdir -p "$PLUGIN/_lib" "$PLUGIN/hooks" "$PLUGIN/.claude-plugin" "$REPO/.claude/hooks"
	cp "$LIB_SRC" "$PLUGIN/_lib/canonical-consumer-skip.sh"
	LIB="$PLUGIN/_lib/canonical-consumer-skip.sh"
	# Synthetic plugin must look like the plugin (has plugin.json) + be a git
	# repo so the lib's `git rev-parse --show-toplevel` resolves to it.
	printf '{"name":"x"}\n' >"$PLUGIN/.claude-plugin/plugin.json"
	printf 'canonical body\n' >"$PLUGIN/hooks/foo.sh"
	(cd "$PLUGIN" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x) || return 1
	# Synthetic consumer: a git repo with NO plugin.json.
	(cd "$REPO" && git init -q && git config user.email t@t && git config user.name t) || return 1
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ccs.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "consumer + byte-identical canonical → SKIP (rc 0)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/hooks/foo.sh"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "consumer + modified canonical → NO skip (rc 1)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	printf '# local drift\n' >>"$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "consumer + non-canonical file (no plugin counterpart) → NO skip (rc 1)" {
	printf 'domain-only\n' >"$REPO/.claude/hooks/domain.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/hooks/domain.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "plugin repo (has plugin.json) → NEVER skip even if identical (rc 1)" {
	cd "$PLUGIN"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip "hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "empty arg → NO skip (rc 1)" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ""
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "consumer file absent on disk → NO skip (rc 1)" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/hooks/missing.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "as-is path mapping: shared-path file (.claude/tests/) identical → SKIP (rc 0)" {
	# .claude/tests/ lives at the SAME path in plugin + consumer, so the
	# stripped candidate (tests/foo.bats) misses and the as-is candidate
	# (.claude/tests/foo.bats) must fire. Locks the 2nd loop candidate.
	mkdir -p "$PLUGIN/.claude/tests" "$REPO/.claude/tests"
	printf 'shared-path canonical\n' >"$PLUGIN/.claude/tests/foo.bats"
	cp "$PLUGIN/.claude/tests/foo.bats" "$REPO/.claude/tests/foo.bats"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/tests/foo.bats"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "as-is path mapping: shared-path file modified → NO skip (rc 1)" {
	mkdir -p "$PLUGIN/.claude/tests" "$REPO/.claude/tests"
	printf 'shared-path canonical\n' >"$PLUGIN/.claude/tests/foo.bats"
	cp "$PLUGIN/.claude/tests/foo.bats" "$REPO/.claude/tests/foo.bats"
	printf '# drift\n' >>"$REPO/.claude/tests/foo.bats"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/tests/foo.bats"
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "fail-safe: lib resolved from consumer tree (plugin_root lacks plugin.json) → NO skip even if identical (rc 1)" {
	# The security-critical guard: if the lib is resolved from the consumer's
	# OWN tree (not the pinned cache), plugin_root has no plugin.json → the
	# byte-identical file must NOT be skipped (a consumer can't self-authorize
	# skipping enforcement on its own files).
	mkdir -p "$REPO/.claude/_lib"
	cp "$LIB" "$REPO/.claude/_lib/canonical-consumer-skip.sh"
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$REPO/.claude/_lib/canonical-consumer-skip.sh"
	run canonical_consumer_skip ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

# --- canonical_consumer_skip_committed (#2250/#2328: committed-blob variant) ---

@test "#2328 committed: consumer + committed byte-identical canonical → SKIP (rc 0)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm mirror
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip_committed ".claude/hooks/foo.sh"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "#2328 committed: consumer + committed-DIFFERS from canonical → NO skip (rc 1)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	printf '# committed drift\n' >>"$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm drift
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip_committed ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "#2250 TOCTOU: committed-DRIFT then worktree-REVERTED — worktree skips but committed does NOT" {
	# The exact TOCTOU #2250 fixes: a consumer COMMITTED a mirror drift (a real
	# finding on the committed blob CR reviewed via -t committed) then reverted the
	# WORKING TREE to canonical. The working-tree predicate is fooled (worktree ==
	# canonical) and would SKIP → silently drop the real finding. The committed
	# predicate sees the DIFFERING committed blob → must NOT skip.
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	printf '# committed drift\n' >>"$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm drift
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh" # worktree reverted to canonical
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip ".claude/hooks/foo.sh" # working-tree → fooled → SKIP
	[ "$status" -eq 0 ]
	run canonical_consumer_skip_committed ".claude/hooks/foo.sh" # committed → NO skip (the fix)
	[ "$status" -eq 1 ]
}

@test "#2328 committed: file present in worktree but NOT committed (not in HEAD) → NO skip (rc 1)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh" # untracked, not committed
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip_committed ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "#2328 committed: plugin repo (has plugin.json) → NEVER skip (rc 1)" {
	cd "$PLUGIN"
	# shellcheck source=../../../_lib/canonical-consumer-skip.sh
	. "$LIB"
	run canonical_consumer_skip_committed "hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}
