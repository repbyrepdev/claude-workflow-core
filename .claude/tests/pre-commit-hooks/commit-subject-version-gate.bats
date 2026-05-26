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
	[[ $output == *"failed jq validation"* ]]
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

# --- realistic git-editor regression locks -----------------------

@test "comment header + blank line + version subject → FAIL (regression #74-r1)" {
	# Canonical git editor flow: instructions, then a blank line,
	# then the real subject. Earlier `grep -m1 | sed` extraction had
	# a silent-bypass bug here (blank line consumed the match).
	msg_file="$TEST_TMP/msg"
	printf '# Please enter the commit message...\n#\n\nfeat(v9.9.9): real subject after preamble\n' >"$msg_file"
	run bash -c "cd '$TEST_TMP' && bash '$SCRIPT' '$msg_file' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"9.9.9"* ]]
}

@test "indented comment line is treated as comment, not subject" {
	# Editor may indent `#` instructions. Regex skips leading whitespace
	# before checking for `#`.
	msg_file="$TEST_TMP/msg"
	printf '   # indented instruction\nfeat(v9.9.9): real subject\n' >"$msg_file"
	run bash -c "cd '$TEST_TMP' && bash '$SCRIPT' '$msg_file' 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"9.9.9"* ]]
}

# --- regex-completeness regression locks -------------------------

@test "feat(v0.9.8)! breaking-change marker > manifest → FAIL" {
	# Conventional Commits 1.0.0 breaking-change `!` between scope
	# and `:` must be tolerated by the regex.
	run _run_with_subject "feat(v0.9.8)!: breaking change"
	[ "$status" -eq 1 ]
	[[ $output == *"0.9.8"* ]]
}

@test "uppercase type Feat(v9.9.9): is detected → FAIL" {
	# Case-insensitive regex prevents silent bypass on typo'd type.
	run _run_with_subject "Feat(v9.9.9): uppercase type"
	[ "$status" -eq 1 ]
	[[ $output == *"9.9.9"* ]]
}

@test "two-segment version scope feat(v1.0): does NOT match → passes" {
	# Regex requires full X.Y.Z; partial versions pass silently.
	run _run_with_subject "feat(v1.0): two segment"
	[ "$status" -eq 0 ]
}

@test "leading whitespace before type → skipped, passes silently" {
	# Indented subject doesn't match the type-anchored regex; gate
	# does not fire (commit-template-check catches the indent).
	run _run_with_subject "   feat(v9.9.9): leading ws"
	[ "$status" -eq 0 ]
}

# --- FAIL output guidance regression locks -----------------------

@test "FAIL output includes manifest path, fix guidance, and bypass hint" {
	# Operator-facing guidance is the gate's product; lock it against
	# inadvertent stripping in future edits.
	run _run_with_subject "feat(v0.9.8): x"
	[ "$status" -eq 1 ]
	[[ $output == *".claude-plugin/plugin.json"* ]]
	[[ $output == *"Fix:"* ]]
	[[ $output == *"COMMIT_SUBJECT_VERSION_SKIP=1"* ]]
}

# --- manifest precondition regression locks ----------------------

@test "plugin.json with no .version field → exit 2" {
	printf '{"name":"t"}\n' >"$TEST_TMP/.claude-plugin/plugin.json"
	run _run_with_subject "feat(v0.9.8): x"
	[ "$status" -eq 2 ]
	[[ $output == *"no usable .version field"* ]]
}

@test "plugin.json with null .version → exit 2" {
	printf '{"name":"t","version":null}\n' >"$TEST_TMP/.claude-plugin/plugin.json"
	run _run_with_subject "feat(v0.9.8): x"
	[ "$status" -eq 2 ]
	[[ $output == *"no usable .version field"* ]]
}

# --- Phase 1 r2 regression locks --------------------------------

@test "uppercase V prefix feat(V9.9.9): is detected → FAIL (r2)" {
	# r2 found asymmetric case: regex made type case-insensitive but
	# `v` was still literal lowercase, so `Feat` was caught but
	# `feat(V...)` slipped through. Fixed in r2 with [vV].
	run _run_with_subject "feat(V9.9.9): uppercase V prefix"
	[ "$status" -eq 1 ]
	[[ $output == *"9.9.9"* ]]
}

@test "subdir-relative commit-msg path → still detects (r2)" {
	# r2 found: line-48 `[ -f ]` check passes against original CWD,
	# then `cd $REPO_ROOT` happens, then sed reads relative path
	# from new CWD and fails. r2 fix resolves COMMIT_MSG_FILE to
	# absolute path BEFORE the cd.
	mkdir -p "$TEST_TMP/sub"
	printf 'feat(v9.9.9): subdir relative\n' >"$TEST_TMP/sub/msg"
	run bash -c "cd '$TEST_TMP/sub' && bash '$SCRIPT' msg 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"9.9.9"* ]]
}

@test "feat(v0.9.5)! breaking-change == manifest → passes (r2)" {
	# Locks the inverse of the breaking-change FAIL case: equal
	# version with `!` marker should pass through `!?` regex branch
	# without firing the gate.
	run _run_with_subject "feat(v0.9.5)!: breaking at current version"
	[ "$status" -eq 0 ]
}

@test "non-version scope with breaking-change marker feat(skills)!: passes (r2)" {
	# Lock bang-in-non-version-scope as silent-pass.
	run _run_with_subject "feat(skills)!: drop legacy skill"
	[ "$status" -eq 0 ]
}

@test "four-segment version feat(v9.9.9.1): does NOT match → passes (r2)" {
	# Regex requires exactly X.Y.Z. Mirrors the existing two-segment
	# test. Locks SemVer-strict regex behavior.
	run _run_with_subject "feat(v9.9.9.1): four segment"
	[ "$status" -eq 0 ]
}
