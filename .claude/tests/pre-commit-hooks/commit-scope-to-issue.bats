#!/usr/bin/env bats
# covers: pre-commit-hooks/commit-scope-to-issue.sh
#
# #2291: commit-msg hook ($1 = commit-msg file) refusing commits whose body
# lacks a #NNN issue reference unless a [no-issue: <reason>] marker is present;
# Revert/Merge/Release commits are exempt. bash-3.2 compatible (no mapfile).
#
# Every pass-path test asserts stdout/stderr behaviour (explicit emptiness for
# silent exits, the expected message otherwise) — not just exit status — so a
# regression that changes WHAT the hook says, not just whether it passes, fails
# loudly. Outputs were dogfooded against the live hook.

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
	# A #NNN match exits 0 silently.
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "commit with [no-issue: reason] passes (exit 0)" {
	printf 'chore: housekeeping\n\n[no-issue: scratch cleanup]\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	# The bypass is allowed WITH an explanatory message on stderr (not silent),
	# so assert the message — a silent pass would be a behaviour regression.
	[ "$status" -eq 0 ]
	[[ $output == *allowing* ]]
}

@test "commit with [no-issue: reason] writes the audit log (jq required)" {
	# jq is a hard dependency of this workflow (the hook AND the bats runner
	# both require it), so make it a fail-closed precondition rather than a
	# skip-as-pass that would silently neuter this assertion.
	command -v jq >/dev/null
	printf 'chore: housekeeping\n\n[no-issue: scratch cleanup]\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 0 ]
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
	# An empty message short-circuits silently.
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "Revert / Merge / Release commits are exempt" {
	n=0
	for prefix in "Revert " "Merge " "Release "; do
		printf '%s\n' "${prefix}a change with no issue ref" >"$MSG"
		run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
		# Each exemption exits 0 silently; assert BOTH so a regression that starts
		# emitting a block message (or a non-zero exit) for an exempt prefix fails.
		[ "$status" -eq 0 ] && [ -z "$output" ] || {
			echo "FAIL: '${prefix}' not silently exempt (status=$status, output=$output)" >&2
			return 1
		}
		n=$((n + 1))
	done
	# Key assertion last: all three exemptions were actually exercised.
	[ "$n" -eq 3 ]
}

@test "missing commit-msg file arg is a no-op (exit 0)" {
	run bash -c "cd '$TEST_TMP' && '$SCRIPT'"
	# Exits 0 but with a diagnostic on stderr — assert the message, not silence.
	[ "$status" -eq 0 ]
	[[ $output == *missing* ]]
}

@test "a #NNN reference in the subject line passes (matches anywhere)" {
	printf 'fix #45: inline subject reference\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	# A subject-line match exits 0 silently, same as a body match.
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "an empty [no-issue:] marker does NOT bypass (BLOCKED)" {
	# The bypass regex requires a non-empty reason ([^]]+), so an empty marker
	# must fall through to the block — not grant a free pass.
	printf 'chore: no real reason\n\n[no-issue:]\n' >"$MSG"
	run bash -c "cd '$TEST_TMP' && '$SCRIPT' '$MSG'"
	[ "$status" -eq 1 ]
	[[ $output == *"issue reference"* ]]
}
