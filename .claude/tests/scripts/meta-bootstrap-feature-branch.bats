#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
	TEST_TMP=$(mktemp -d -t meta-bootstrap-fb.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */meta-bootstrap-fb.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "feature-branch rejects non-git working directory" {
	cd "$TEST_TMP"
	run "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"not inside a git working tree"* ]]
}

@test "feature-branch rejects detached HEAD" {
	cd "$TEST_TMP"
	git init -q
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	git checkout --detach HEAD 2>/dev/null
	run "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"no current branch"* ]]
}

@test "feature-branch flags branch not matching convention" {
	cd "$TEST_TMP"
	git init -q
	git checkout -b random-branch 2>/dev/null
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	run "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"branch name not per convention"* ]]
	[[ $output == *"random-branch"* ]]
}

@test "feature-branch accepts conventional branch name (issue + labels skipped — no gh)" {
	cd "$TEST_TMP"
	git init -q
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	git checkout -b feat/v0.1.0/999-test-slug 2>/dev/null
	# Pre-commit hook stub to satisfy the rule.
	mkdir -p .git/hooks
	echo '#!/bin/sh' >.git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
	# Run with PATH stripped of gh so the issue-existence rule is skipped (ℹ note).
	run env PATH="/usr/bin:/bin" "$SCRIPT" --target feature-branch
	# Without gh, issue + labels checks are skipped; only branch-shape + hook
	# matter. Both satisfied → rc=0.
	[ "$status" -eq 0 ]
	[[ $output == *"prereqs satisfied"* ]]
}

@test "feature-branch warns when pre-commit hook missing" {
	cd "$TEST_TMP"
	git init -q
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	git checkout -b feat/v0.1.0/999-test-slug 2>/dev/null
	# No pre-commit hook installed.
	run env PATH="/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"pre-commit hook not installed"* ]]
}

@test "--target feature-branch --verify-only is accepted (read-only by design)" {
	cd "$TEST_TMP"
	git init -q
	git checkout -b random 2>/dev/null
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	run "$SCRIPT" --target feature-branch --verify-only
	# Should reach the dispatch (rc=1 from the branch-shape rule), NOT the
	# rc=69 refusal that applies to other targets.
	[ "$status" -eq 1 ]
	[[ $output != *"not yet wired"* ]]
}

@test "--target machine --verify-only still refuses (other targets unwired)" {
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -eq 69 ]
	[[ $output == *"not yet wired"* ]]
}
