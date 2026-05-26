#!/usr/bin/env bats
# covers: pre-commit-hooks/commit-subject-version-gate.sh
#
# Tests for the commit-subject version-scope gate (#74).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/commit-subject-version-gate.sh"
	TEST_TMP=$(cd "$(mktemp -d -t csv-gate.XXXXXX)" && pwd -P) || return 1
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		mkdir -p .claude-plugin
		printf '{"name":"t","version":"0.9.5"}\n' >.claude-plugin/plugin.json
	) || return 1
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */csv-gate.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_run_with_subject() {
	local subject=$1
	local msg_file="$TEST_TMP/msg"
	printf '%s\n' "$subject" >"$msg_file"
	(cd "$TEST_TMP" && bash "$SCRIPT" "$msg_file")
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "missing commit-msg file arg → exit 2" {
	run bash "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ $output == *"expected commit-msg file"* ]]
}

@test "commit-msg file does not exist → exit 2" {
	run bash "$SCRIPT" /nonexistent/path
	[ "$status" -eq 2 ]
	[[ $output == *"not found"* ]]
}

# --- version-scope detection -------------------------------------

@test "feat(v0.9.8): scope > manifest 0.9.5 → FAIL" {
	run _run_with_subject "feat(v0.9.8): new feature"
	[ "$status" -eq 1 ]
	[[ $output == *"0.9.8"* ]]
	[[ $output == *"0.9.5"* ]]
}

@test "fix(v0.10.0): scope semver-aware (> 0.9.5) → FAIL" {
	# 0.10.0 > 0.9.5 under sort -V, but lex would say 0.10.0 < 0.9.5
	run _run_with_subject "fix(v0.10.0): something"
	[ "$status" -eq 1 ]
}

@test "feat(v0.9.5): scope == manifest → passes" {
	run _run_with_subject "feat(v0.9.5): a change at current version"
	[ "$status" -eq 0 ]
}

@test "chore(v0.9.0): scope < manifest → passes (backport allowed)" {
	run _run_with_subject "chore(v0.9.0): backport fix"
	[ "$status" -eq 0 ]
}

# --- non-version scopes pass ------------------------------------

@test "non-version scope passes (feat(skills): ...)" {
	run _run_with_subject "feat(skills): add new skill"
	[ "$status" -eq 0 ]
}

@test "no scope at all passes (chore: ...)" {
	run _run_with_subject "chore: misc cleanup"
	[ "$status" -eq 0 ]
}

@test "scope with version-like-but-not-v prefix passes" {
	run _run_with_subject "feat(0.9.8): no v prefix"
	[ "$status" -eq 0 ]
}

# --- bypass + edge ------------------------------------------------

@test "COMMIT_SUBJECT_VERSION_SKIP=1 bypasses + audits" {
	msg_file="$TEST_TMP/msg"
	printf 'feat(v9.9.9): bypass test\n' >"$msg_file"
	run bash -c "cd '$TEST_TMP' && export COMMIT_SUBJECT_VERSION_SKIP=1 && bash '$SCRIPT' '$msg_file' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"COMMIT_SUBJECT_VERSION_SKIP=1"* ]]
}

@test "no plugin.json (not a plugin repo) → passes through" {
	rm -rf "$TEST_TMP/.claude-plugin"
	run _run_with_subject "feat(v9.9.9): not in plugin"
	[ "$status" -eq 0 ]
}

@test "malformed plugin.json → exit 2" {
	echo "not json" >"$TEST_TMP/.claude-plugin/plugin.json"
	run _run_with_subject "feat(v0.9.8): something"
	[ "$status" -eq 2 ]
	[[ $output == *"malformed JSON"* ]]
}

@test "empty commit message passes" {
	msg_file="$TEST_TMP/msg"
	: >"$msg_file"
	run bash "$SCRIPT" "$msg_file"
	[ "$status" -eq 0 ]
}

@test "subject is comment-only (# header) passes" {
	msg_file="$TEST_TMP/msg"
	printf '# editor preamble\n#\n' >"$msg_file"
	run bash "$SCRIPT" "$msg_file"
	[ "$status" -eq 0 ]
}
