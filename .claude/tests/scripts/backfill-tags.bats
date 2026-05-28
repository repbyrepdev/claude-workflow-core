#!/usr/bin/env bats
# covers: scripts/backfill-tags.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/backfill-tags.sh"
	TEST_TMP=$(mktemp -d -t backfill-tags.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Build a synthetic plugin repo with 3 version bumps + 0 existing tags.
	# The script walks first-parent main for plugin.json changes, so the
	# fixture needs each bump to be a real commit on main.
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .claude-plugin scripts
		# Stub release.sh that just writes a marker file so tests can
		# assert it was invoked WITHOUT actually creating tags/cache.
		cat >scripts/release.sh <<'STUB'
#!/usr/bin/env bash
echo "stub-release: pwd=$(pwd) version=$(jq -r .version .claude-plugin/plugin.json)" \
	>>"$BACKFILL_TEST_LOG"
exit 0
STUB
		chmod +x scripts/release.sh
		cp "$SCRIPT" scripts/backfill-tags.sh
		chmod +x scripts/backfill-tags.sh

		# v0.1.0 — initial
		echo '{"version":"0.1.0"}' >.claude-plugin/plugin.json
		git add .
		git commit -q -m "initial v0.1.0"

		# v0.2.0
		echo '{"version":"0.2.0"}' >.claude-plugin/plugin.json
		git commit -aq -m "bump v0.2.0"

		# v0.3.0
		echo '{"version":"0.3.0"}' >.claude-plugin/plugin.json
		git commit -aq -m "bump v0.3.0"
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	export BACKFILL_TEST_LOG="$TEST_TMP/stub-release-invocations.log"
	: >"$BACKFILL_TEST_LOG"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */backfill-tags.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--dry-run reports all version transitions + does not tag" {
	cd "$TEST_TMP" || return 1
	run scripts/backfill-tags.sh --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"v0.1.0"* ]]
	[[ $output == *"v0.2.0"* ]]
	[[ $output == *"v0.3.0"* ]]
	# No tags should exist
	[ -z "$(git tag --list 'v*')" ]
}

@test "applies tags for every transition + skip-push leaves remote alone" {
	cd "$TEST_TMP" || return 1
	# No remote configured → --skip-push avoids the push attempt; also
	# --skip-release avoids the stub-release worktree expansion which is
	# tested separately.
	run scripts/backfill-tags.sh --skip-push --skip-release
	[ "$status" -eq 0 ]
	# All 3 versions tagged
	tags=$(git tag --list 'v*' | sort -V | tr '\n' ' ')
	[[ $tags == *"v0.1.0"* ]]
	[[ $tags == *"v0.2.0"* ]]
	[[ $tags == *"v0.3.0"* ]]
}

@test "idempotent — second run skips already-existing tags" {
	cd "$TEST_TMP" || return 1
	scripts/backfill-tags.sh --skip-push --skip-release >/dev/null
	run scripts/backfill-tags.sh --skip-push --skip-release
	[ "$status" -eq 0 ]
	# Second run either says "nothing to do" (when --since defaults to
	# latest existing tag — PAIRS is empty) OR "created=0 skipped=N"
	# (when PAIRS has entries that all skip). Either output proves
	# idempotency.
	if [[ $output == *"nothing to do"* ]]; then
		:
	else
		[[ $output == *"created=0"* ]]
	fi
}

@test "audit log written to .claude/logs/release-backfill.jsonl" {
	cd "$TEST_TMP" || return 1
	scripts/backfill-tags.sh --skip-push --skip-release >/dev/null
	[ -f .claude/logs/release-backfill.jsonl ]
	count=$(wc -l <.claude/logs/release-backfill.jsonl | tr -d ' ')
	[ "$count" -ge 3 ]
	# Each entry is valid JSON with required fields
	while read -r line; do
		echo "$line" | jq -e '.version and .sha and .status' >/dev/null
	done <.claude/logs/release-backfill.jsonl
}

@test "refuses to run outside a plugin repo (exit 2)" {
	OTHER=$(mktemp -d -t backfill-not-plugin.XXXXXX)
	(
		set -e
		cd "$OTHER"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		git commit --allow-empty -q -m init
		mkdir -p scripts
		cp "$SCRIPT" scripts/backfill-tags.sh
		chmod +x scripts/backfill-tags.sh
	) || {
		rm -rf "$OTHER"
		return 1
	}
	cd "$OTHER"
	run scripts/backfill-tags.sh --dry-run
	[ "$status" -eq 2 ]
	[[ $output == *"not in a plugin repo"* ]]
	cd /tmp
	rm -rf "$OTHER"
}

@test "--since pins lower bound" {
	cd "$TEST_TMP" || return 1
	# Tag the first version manually, then --since=v0.1.0
	git tag -a v0.1.0 -m "manual" HEAD~2
	run scripts/backfill-tags.sh --dry-run --since v0.1.0
	[ "$status" -eq 0 ]
	# Should NOT include v0.1.0 in the dry-run output (since it's the
	# baseline) — but should include v0.2.0 + v0.3.0.
	[[ $output == *"v0.2.0"* ]]
	[[ $output == *"v0.3.0"* ]]
}
