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
