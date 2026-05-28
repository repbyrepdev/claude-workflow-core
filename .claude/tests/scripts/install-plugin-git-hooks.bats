#!/usr/bin/env bats
# covers: scripts/install-plugin-git-hooks.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/install-plugin-git-hooks.sh"
	TEST_TMP=$(mktemp -d -t plugin-git-hooks.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Fixture: tmp dir with plugin.json + git init + minimal source hook so
	# the installer treats it as a plugin checkout. The installer detects
	# plugin-repo via .claude-plugin/plugin.json presence.
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude-plugin hooks scripts
		echo '{"name":"test","version":"0.0.0"}' >.claude-plugin/plugin.json
		# Real source hook content not required; just executable presence
		cat >hooks/post-merge-release-fire.sh <<'STUB'
#!/usr/bin/env bash
echo "release-fire fired"
STUB
		chmod +x hooks/post-merge-release-fire.sh
		cp "$SCRIPT" scripts/install-plugin-git-hooks.sh
		chmod +x scripts/install-plugin-git-hooks.sh
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */plugin-git-hooks.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "install creates .git/hooks/post-merge wrapper" {
	cd "$TEST_TMP" || return 1
	run scripts/install-plugin-git-hooks.sh
	[ "$status" -eq 0 ]
	[ -x .git/hooks/post-merge ]
	# Wrapper invokes the source hook
	grep -Fq "post-merge-release-fire.sh" .git/hooks/post-merge
}

@test "install is idempotent — second run no-ops + exits 0" {
	cd "$TEST_TMP" || return 1
	scripts/install-plugin-git-hooks.sh >/dev/null
	# Capture mtime so we know if file was rewritten
	mtime_before=$(stat -f '%m' .git/hooks/post-merge 2>/dev/null || stat -c '%Y' .git/hooks/post-merge)
	sleep 1 # allow mtime resolution
	run scripts/install-plugin-git-hooks.sh
	[ "$status" -eq 0 ]
	[[ $output == *"already installed"* ]]
	mtime_after=$(stat -f '%m' .git/hooks/post-merge 2>/dev/null || stat -c '%Y' .git/hooks/post-merge)
	[ "$mtime_before" = "$mtime_after" ]
}

@test "--check fails with rc=1 when hook is missing" {
	cd "$TEST_TMP" || return 1
	run scripts/install-plugin-git-hooks.sh --check
	[ "$status" -eq 1 ]
	[[ $output == *"missing"* ]]
}

@test "--check passes after install" {
	cd "$TEST_TMP" || return 1
	scripts/install-plugin-git-hooks.sh >/dev/null
	run scripts/install-plugin-git-hooks.sh --check
	[ "$status" -eq 0 ]
	[[ $output == *"wired"* ]]
}

@test "--uninstall removes the hook" {
	cd "$TEST_TMP" || return 1
	scripts/install-plugin-git-hooks.sh >/dev/null
	[ -x .git/hooks/post-merge ]
	run scripts/install-plugin-git-hooks.sh --uninstall
	[ "$status" -eq 0 ]
	[ ! -e .git/hooks/post-merge ]
}

@test "refuses to install outside plugin repo (exit 2)" {
	# Make a non-plugin tmp checkout (no .claude-plugin/plugin.json) +
	# copy the installer in so REPO_ROOT resolution lands on the non-plugin.
	OTHER=$(mktemp -d -t not-a-plugin.XXXXXX)
	(
		set -e
		cd "$OTHER"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p scripts
		cp "$SCRIPT" scripts/install-plugin-git-hooks.sh
		chmod +x scripts/install-plugin-git-hooks.sh
	) || {
		rm -rf "$OTHER"
		echo "FATAL: non-plugin fixture init failed" >&2
		return 1
	}
	cd "$OTHER"
	run scripts/install-plugin-git-hooks.sh
	[ "$status" -eq 2 ]
	[[ $output == *"not inside the plugin repo"* ]]
	cd /tmp
	rm -rf "$OTHER"
}

@test "preserves prior post-merge content as backup" {
	cd "$TEST_TMP" || return 1
	# Pre-existing hook with different content (operator's custom logic)
	cat >.git/hooks/post-merge <<'OLD'
#!/bin/bash
echo "my custom hook"
OLD
	chmod +x .git/hooks/post-merge
	run scripts/install-plugin-git-hooks.sh
	[ "$status" -eq 0 ]
	[[ $output == *"backed up"* ]]
	# Backup file exists with the old content
	[ -f .git/hooks/post-merge.pre-v0.18.0.bak ]
	grep -q "my custom hook" .git/hooks/post-merge.pre-v0.18.0.bak
	# New hook is the wrapper
	grep -Fq "post-merge-release-fire.sh" .git/hooks/post-merge
}

@test "exits 2 if source hook is missing" {
	cd "$TEST_TMP" || return 1
	rm hooks/post-merge-release-fire.sh
	run scripts/install-plugin-git-hooks.sh
	[ "$status" -eq 2 ]
	[[ $output == *"source hook missing"* ]]
}
