#!/usr/bin/env bats
# covers: hooks/hook-ack-clear.sh
#
# CR-CLI #223 r2 (critical regression): the bare-basename branch built its
# suffix needle from target_base (the Read file's OWN basename) instead of fp
# (the sentinel basename). A path ALWAYS ends with its own basename, so the
# check matched unconditionally — clearing EVERY bare-basename ack on ANY Read.
# These tests lock the fix: a bare-basename entry survives an unrelated Read,
# clears on a matching-basename Read, and a multi-segment fp clears for both the
# plugin and consumer paths but NOT an unrelated same-basename file.

setup() {
	HOOK="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)/hooks/hook-ack-clear.sh"
	[ -x "$HOOK" ]
	command -v jq >/dev/null
	command -v git >/dev/null
	TEST_TMP=$(mktemp -d -t hookack.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude/.session-state
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	SENTINEL="$TEST_TMP/.claude/.session-state/hook-output-pending.txt"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */hookack.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Fire the hook as a PostToolUse Read of $1 (absolute path), from inside the
# fixture repo so git-toplevel resolves to $TEST_TMP.
_read_file() {
	printf '{"tool_input":{"file_path":"%s"}}' "$1" | (cd "$TEST_TMP" && "$HOOK")
}

@test "bare-basename ack SURVIVES an unrelated-basename Read (r2 critical regression)" {
	printf 'h\tr\tt\t%s\n' "settings.json" >"$SENTINEL"
	run _read_file "$TEST_TMP/some/other.json"
	[ "$status" -eq 0 ]
	run grep -c 'settings.json' "$SENTINEL"
	[ "$output" = "1" ] # the bug cleared it on ANY Read; the fix keeps it
}

@test "bare-basename ack CLEARS when the matching basename is Read" {
	printf 'h\tr\tt\t%s\n' "settings.json" >"$SENTINEL"
	run _read_file "$TEST_TMP/deep/dir/settings.json"
	[ "$status" -eq 0 ]
	run grep -c 'settings.json' "$SENTINEL"
	[ "$output" = "0" ]
}

@test "multi-segment fp clears for the consumer (.claude/...) path" {
	printf 'h\tr\tt\t%s\n' "skills/ship-pr-cycle/SKILL.md" >"$SENTINEL"
	run _read_file "$TEST_TMP/.claude/skills/ship-pr-cycle/SKILL.md"
	[ "$status" -eq 0 ]
	run grep -c 'ship-pr-cycle' "$SENTINEL"
	[ "$output" = "0" ] # consumer path suffix-matches the plugin-relative fp
}

@test "multi-segment fp does NOT clear an unrelated same-basename SKILL.md" {
	printf 'h\tr\tt\t%s\n' "skills/ship-pr-cycle/SKILL.md" >"$SENTINEL"
	run _read_file "$TEST_TMP/skills/other-skill/SKILL.md"
	[ "$status" -eq 0 ]
	run grep -c 'ship-pr-cycle' "$SENTINEL"
	[ "$output" = "1" ] # basename collision must NOT clear the gate
}
