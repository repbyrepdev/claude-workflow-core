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

# Build a stub gh in $TEST_TMP/bin that returns whatever its caller wants.
# Args: stub-mode (e.g. "issue-missing", "labels-empty", "labels-priority-only", "ok").
_install_gh_stub() {
	local mode=$1
	mkdir -p "$TEST_TMP/bin"
	case "$mode" in
	issue-missing)
		cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
	echo "GraphQL: Could not resolve to an Issue with the number 999" >&2
	exit 1
fi
exit 0
STUB
		;;
	labels-empty)
		cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
	# First call (--json state) succeeds; second call (--json labels) returns no labels.
	for a in "$@"; do
		if [ "$a" = "labels" ]; then
			exit 0
		fi
	done
	exit 0
fi
exit 0
STUB
		;;
	labels-priority-only)
		cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
	for a in "$@"; do
		if [ "$a" = "labels" ]; then
			echo "priority:p2"
			exit 0
		fi
	done
	exit 0
fi
exit 0
STUB
		;;
	ok)
		cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
	for a in "$@"; do
		if [ "$a" = "labels" ]; then
			echo "priority:p2"
			echo "area:infrastructure"
			exit 0
		fi
	done
	exit 0
fi
exit 0
STUB
		;;
	esac
	chmod +x "$TEST_TMP/bin/gh"
}

_minimal_repo() {
	# Cd into the test tmp dir + init repo + checkout conventional branch + install pre-commit hook.
	cd "$TEST_TMP" || return 1
	git init -q
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	git checkout -b feat/v0.1.0/999-test-slug 2>/dev/null
	mkdir -p .git/hooks
	echo '#!/bin/sh' >.git/hooks/pre-commit
	chmod +x .git/hooks/pre-commit
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

@test "feature-branch rejects non-conventional branch name" {
	cd "$TEST_TMP"
	git init -q
	git checkout -b random-branch 2>/dev/null
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	run "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"branch name not per convention"* ]]
}

@test "feature-branch gh-missing reports PARTIAL verdict (not silent ✓)" {
	_minimal_repo
	# gh stripped from PATH: Rules 2+3 skipped, but verdict downgrades to PARTIAL.
	run env PATH="/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 0 ]
	[[ $output == *"PARTIAL"* ]]
	[[ $output == *"rule(s) skipped"* ]]
	# Critically NOT a silent ✓.
	[[ $output != *"✓ feature-branch prereqs satisfied"* ]]
}

@test "feature-branch missing pre-commit hook fails" {
	cd "$TEST_TMP"
	git init -q
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	git checkout -b feat/v0.1.0/999-test-slug 2>/dev/null
	# Intentionally no .git/hooks/pre-commit
	run env PATH="/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"pre-commit hook not installed"* ]]
}

@test "feature-branch detects issue-not-found on GitHub (stubbed gh)" {
	_minimal_repo
	_install_gh_stub issue-missing
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"issue not found"* ]] || [[ $output == *"gh issue view failed"* ]]
}

@test "feature-branch detects missing area:* label (stubbed gh with priority only)" {
	_minimal_repo
	_install_gh_stub labels-priority-only
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"missing an area:* label"* ]]
}

@test "feature-branch detects missing priority:* AND area:* (stubbed gh with no labels)" {
	_minimal_repo
	_install_gh_stub labels-empty
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 1 ]
	[[ $output == *"missing a priority:* label"* ]]
	[[ $output == *"missing an area:* label"* ]]
}

@test "feature-branch happy path with stubbed gh + both labels present" {
	_minimal_repo
	_install_gh_stub ok
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" "$SCRIPT" --target feature-branch
	[ "$status" -eq 0 ]
	[[ $output == *"prereqs satisfied"* ]]
}

@test "feature-branch accepts all conventional type prefixes" {
	for type in feat fix chore docs refactor perf test build ci revert; do
		cd "$TEST_TMP"
		rm -rf .git
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		git checkout -b "${type}/v0.1.0/999-test" 2>/dev/null
		mkdir -p .git/hooks
		echo '#!/bin/sh' >.git/hooks/pre-commit
		chmod +x .git/hooks/pre-commit
		run env PATH="/usr/bin:/bin" "$SCRIPT" --target feature-branch
		# rc=0 (PARTIAL since gh stripped) is acceptable; no "not per convention" error.
		[ "$status" -eq 0 ]
		[[ $output != *"branch name not per convention"* ]]
	done
}

@test "--target feature-branch --verify-only is accepted (read-only by design)" {
	cd "$TEST_TMP"
	git init -q
	git checkout -b random 2>/dev/null
	git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
	run "$SCRIPT" --target feature-branch --verify-only
	[ "$status" -eq 1 ]
	[[ $output != *"not yet wired"* ]]
}

@test "--target machine --verify-only is now implemented (covered by meta-bootstrap-machine.bats)" {
	# As of #110 machine --verify-only is wired against the manifest. This
	# test pins that the rc=69 stub doesn't accidentally come back; detailed
	# coverage lives in the per-flow bats file.
	run "$SCRIPT" --target machine --verify-only
	[ "$status" -ne 69 ]
	[[ $output != *"not yet wired"* ]]
}
