#!/usr/bin/env bats
# covers: pre-commit-hooks/commit-scope-to-issue.sh
#
# #2291: commit-msg hook ($1 = commit-msg file) refusing commits whose body
# lacks a #NNN issue reference unless a [no-issue: <reason>] marker is present;
# Revert/Merge/Release commits are exempt. bash-3.2 compatible (no mapfile).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/commit-scope-to-issue.sh"
	[ -f "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t commit-scope.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	MSG="$TEST_TMP/msg.txt"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

@test "commit with a #NNN reference passes" {
	printf 'fix(x): something\n\nCloses #123\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 0 ]
}

@test "commit with [no-issue: reason] passes and is audit-logged" {
	printf 'chore: housekeeping\n\n[no-issue: scratch cleanup]\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 0 ]
	# The hook only writes the audit log when jq is available; skip the log
	# assertion (not the exit-0 behaviour, already checked) when jq is absent.
	command -v jq >/dev/null || skip "jq required for the audit-log assertion"
	[ -f "$TEST_TMP/.claude/logs/no-issue-commits.jsonl" ]
	# Key assertion last: the reason was captured into the audit log.
	grep -q 'scratch cleanup' "$TEST_TMP/.claude/logs/no-issue-commits.jsonl"
}

@test "commit with no issue reference and no bypass is BLOCKED" {
	printf 'fix: a thing with no tracking\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	# Key assertions last: non-zero exit AND the explanatory message prove the
	# hook fired and rejected (not a silent skip).
	[ "$status" -eq 1 ]
	[[ $output == *"issue reference"* ]]
}

@test "empty commit message is a no-op (exit 0)" {
	: >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 0 ]
}

@test "Revert / Merge / Release commits are exempt" {
	n=0
	for prefix in "Revert " "Merge " "Release "; do
		printf '%s\n' "${prefix}a change with no issue ref" >"$MSG"
		run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
		[ "$status" -eq 0 ] || {
			echo "FAIL: '${prefix}' commit not exempt (status=$status)" >&2
			return 1
		}
		n=$((n + 1))
	done
	# Key assertion last: all three exemptions were actually exercised.
	[ "$n" -eq 3 ]
}

@test "missing commit-msg file arg is a no-op (exit 0)" {
	run bash -c "cd '$TEST_TMP' && '$SCRIPT'"
	[ "$status" -eq 0 ]
}

@test "a #NNN reference in the subject line passes (matches anywhere)" {
	printf 'fix #45: inline subject reference\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 0 ]
}

@test "an empty [no-issue:] marker does NOT bypass (BLOCKED)" {
	# The bypass regex requires a non-empty reason ([^]]+), so an empty marker
	# must fall through to the block — not grant a free pass.
	printf 'chore: no real reason\n\n[no-issue:]\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 1 ]
	[[ $output == *"issue reference"* ]]
}

@test "an exemption prefix without the trailing space is NOT exempt (BLOCKED)" {
	# The exemption glob requires a literal trailing space ('Revert '*), so
	# 'Reverting ...' must still be enforced.
	printf 'Reverting an earlier change, no issue ref\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 1 ]
	[[ $output == *"issue reference"* ]]
}
