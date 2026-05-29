#!/usr/bin/env bats
# covers: pre-commit-hooks/memory-drift-check.sh
#
# v0.30.J (#177): the .memory-aliases migration map. A plugin restructure that
# renames an internal path leaves memory files referencing the OLD path; the
# gate honors `old -> new` mappings so a stale OLD reference passes when its
# mapped NEW path resolves. These tests pin that behavior plus the pre-existing
# live/stale contract.
#
# The drift checker only extracts paths under `.claude/` or `scripts/` from
# memory files, so memory references use the OLD `.claude/...` form; the NEW
# target (e.g. `skills/...`) is reached only via the alias + an existence check.

# @bats test bodies run as subshells, so shellcheck flags the per-test `export
# MEMORY_DRIFT_EXTERNAL_ROOTS=...` (SC2030/SC2031) as "lost in subshell" — false
# positive here: each export feeds the PATH-stubbed hook child WITHIN the same
# test and is never read across tests.
# shellcheck disable=SC2030,SC2031

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/memory-drift-check.sh"
	[ -f "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t memory-drift.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
		mkdir -p memory
	) || {
		echo "FATAL: TEST_TMP fixture init failed" >&2
		return 1
	}
	export CLAUDE_MEMORY_DIR="$TEST_TMP/memory"
	# Pin external roots to a non-existent dir so the hook's default peer-repo
	# roots ($HOME/media-server:...) never resolve test paths. Non-empty so the
	# hook does NOT fall back to those defaults.
	export MEMORY_DRIFT_EXTERNAL_ROOTS="$TEST_TMP/no-external-root"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */memory-drift.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Create + stage a repo-relative file (so the index existence check sees it).
_stage() {
	local p="$TEST_TMP/$1"
	mkdir -p "$(dirname "$p")"
	printf '#!/bin/bash\n' >"$p"
	git -C "$TEST_TMP" add "$1"
}

_run_hook() {
	run bash -c "cd '$TEST_TMP' && bash '$SCRIPT'"
}

@test "live .claude/ path reference passes (rc 0)" {
	_stage .claude/hooks/live.sh
	printf 'See `.claude/hooks/live.sh` for X.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
}

@test "stale path with no alias is flagged (rc 1)" {
	printf 'See `.claude/skills/foo/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
	[[ $output == *".claude/skills/foo/run.sh"* ]]
}

@test "stale OLD path resolves via .memory-aliases prefix when NEW path exists (rc 0) (#177)" {
	_stage skills/foo/run.sh
	printf '.claude/skills/ -> skills/\n' >"$TEST_TMP/.memory-aliases"
	printf 'See `.claude/skills/foo/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
}

@test "alias whose NEW target does not exist still flags drift (rc 1) (#177)" {
	printf '.claude/skills/ -> skills/\n' >"$TEST_TMP/.memory-aliases"
	printf 'See `.claude/skills/ghost/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
	[[ $output == *".claude/skills/ghost/run.sh"* ]]
}

@test "exact-path alias rewrites the whole path (#177)" {
	_stage scripts/new-name.sh
	printf '.claude/hooks/old-name.sh -> scripts/new-name.sh\n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/hooks/old-name.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
}

@test "alias comments + blank lines ignored; unmapped stale path still flagged (rc 1) (#177)" {
	printf '# a comment\n\n.claude/skills/ -> skills/\n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/hooks/unmapped.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
	[[ $output == *".claude/hooks/unmapped.sh"* ]]
}

# Create a worktree file WITHOUT staging it (index-is-SSOT / anti-shadow tests).
_touch_only() {
	local p="$TEST_TMP/$1"
	mkdir -p "$(dirname "$p")"
	printf '#!/bin/bash\n' >"$p"
}

@test "worktree-present but UNSTAGED ref is flagged — index is SSOT (rc 1) (#177 anti-shadow)" {
	# CR #634 finding 73: existence is validated against the staged index, not
	# the worktree, so an untracked shadow file can't weaken the gate. _stage
	# always git-adds, so this is the one path that exercises index-vs-worktree.
	_touch_only .claude/hooks/shadow.sh
	printf 'Ref `.claude/hooks/shadow.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
	[[ $output == *".claude/hooks/shadow.sh"* ]]
}

@test "alias NEW target worktree-present-but-unstaged is flagged; staged passes (#177 anti-shadow)" {
	printf '.claude/skills/ -> skills/\n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/skills/sh/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_touch_only skills/sh/run.sh
	_run_hook
	[ "$status" -eq 1 ]
	git -C "$TEST_TMP" add skills/sh/run.sh
	_run_hook
	[ "$status" -eq 0 ]
}

@test "ref resolved via MEMORY_DRIFT_EXTERNAL_ROOTS passes (rc 0) (#177 refactor lock)" {
	local extroot="$TEST_TMP/ext"
	mkdir -p "$extroot/scripts"
	printf '#!/bin/bash\n' >"$extroot/scripts/ext.sh"
	export MEMORY_DRIFT_EXTERNAL_ROOTS="$extroot"
	printf 'Ref `scripts/ext.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
}

@test ".claude/ ref resolves via external-root prefix-strip (rc 0) (#177 refactor lock)" {
	local extroot="$TEST_TMP/ext"
	mkdir -p "$extroot/skills/x"
	printf '#!/bin/bash\n' >"$extroot/skills/x/run.sh"
	export MEMORY_DRIFT_EXTERNAL_ROOTS="$extroot"
	# Memory says .claude/skills/x/run.sh; external root has it WITHOUT the
	# .claude/ prefix → resolves via _path_resolves's prefix-strip retry.
	printf 'Ref `.claude/skills/x/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
}

@test "gitignored + worktree-present ref passes; absent worktree fails (#177 refactor lock)" {
	printf 'scripts/gen.sh\n' >"$TEST_TMP/.gitignore"
	_touch_only scripts/gen.sh
	printf 'Ref `scripts/gen.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
	rm -f "$TEST_TMP/scripts/gen.sh"
	_run_hook
	[ "$status" -eq 1 ]
}

@test "alias line missing '->' is ignored; mapped-looking ref stays stale (rc 1) (#177)" {
	printf '.claude/hooks/noarrow.sh\n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/hooks/noarrow.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
	[[ $output == *".claude/hooks/noarrow.sh"* ]]
}

@test "alias whitespace around '->' is trimmed and still resolves (rc 0) (#177)" {
	_stage skills/ws/run.sh
	printf '   .claude/skills/   ->   skills/   \n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/skills/ws/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 0 ]
}

@test "alias first-match-wins: earlier mapping to a missing target shadows a later correct one (rc 1) (#177)" {
	_stage skills/fm/run.sh
	printf '.claude/skills/ -> ghost/\n.claude/skills/ -> skills/\n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/skills/fm/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
}

@test "non-trailing-slash alias 'old' is exact-only — no broad prefix match (rc 1) (#177 SFH-177-1)" {
	# `old` without a trailing slash must NOT prefix-match .claude/skills/X.
	_stage skills/ns/run.sh
	printf '.claude/skills -> skills\n' >"$TEST_TMP/.memory-aliases"
	printf 'Ref `.claude/skills/ns/run.sh`.\n' >"$TEST_TMP/memory/m.md"
	_run_hook
	[ "$status" -eq 1 ]
	[[ $output == *".claude/skills/ns/run.sh"* ]]
}
