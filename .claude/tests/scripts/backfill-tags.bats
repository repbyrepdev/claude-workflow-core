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
	# baseline) — but should include v0.2.0 + v0.3.0. Negative + positive
	# assertions per comment-analyzer #139 r1 MED (CR-007 — prior version
	# had only the positive assertions; a future change that includes
	# v0.1.0 in the walk would pass silently).
	[[ $output != *"v0.1.0"* ]]
	[[ $output == *"v0.2.0"* ]]
	[[ $output == *"v0.3.0"* ]]
}

@test "tags point at the FIRST commit where each version first appeared" {
	# pr-test-analyzer #139 r1 CRITICAL BFT-02: tag-name-only assertion
	# would pass even if all 3 tags pointed at HEAD. The whole point of
	# the script is "tag at the RIGHT sha". Pin that explicitly.
	cd "$TEST_TMP" || return 1
	# Capture the 3 fixture shas (oldest → newest) BEFORE running backfill
	v01_sha=$(git log --reverse --format=%H | sed -n '1p')
	v02_sha=$(git log --reverse --format=%H | sed -n '2p')
	v03_sha=$(git log --reverse --format=%H | sed -n '3p')
	scripts/backfill-tags.sh --skip-push --skip-release >/dev/null
	# Each tag must resolve to its introducing commit. Tags are annotated,
	# so peel via `^{commit}` to compare with the commit sha (not the
	# annotated tag object's own sha).
	[ "$(git rev-parse 'v0.1.0^{commit}')" = "$v01_sha" ]
	[ "$(git rev-parse 'v0.2.0^{commit}')" = "$v02_sha" ]
	[ "$(git rev-parse 'v0.3.0^{commit}')" = "$v03_sha" ]
	# AND the plugin.json.version at each tag matches the tag name
	[ "$(git show v0.1.0:.claude-plugin/plugin.json | jq -r .version)" = "0.1.0" ]
	[ "$(git show v0.2.0:.claude-plugin/plugin.json | jq -r .version)" = "0.2.0" ]
	[ "$(git show v0.3.0:.claude-plugin/plugin.json | jq -r .version)" = "0.3.0" ]
}

@test "release.sh fires once per version inside its historical worktree" {
	# pr-test-analyzer #139 r1 CRITICAL BFT-01: the worktree+release.sh
	# code path is the entire reason this script exists. Drop --skip-release
	# and assert the stub fired with the right version per invocation.
	cd "$TEST_TMP" || return 1
	scripts/backfill-tags.sh --skip-push >/dev/null
	# Stub release.sh logs `version=...` per invocation; assert each
	# fixture version appears exactly once
	[ "$(grep -c 'version=0.1.0' "$BACKFILL_TEST_LOG")" -eq 1 ]
	[ "$(grep -c 'version=0.2.0' "$BACKFILL_TEST_LOG")" -eq 1 ]
	[ "$(grep -c 'version=0.3.0' "$BACKFILL_TEST_LOG")" -eq 1 ]
	# AND no worktree directories leak after the run
	leftover=$(git worktree list --porcelain | grep -c '^worktree ')
	# Always at least 1 (the main worktree); MUST NOT be more
	[ "$leftover" -eq 1 ]
}

@test "plugin.json with null .version is skipped, not tagged as vnull" {
	# silent-failure-hunter #139 r1 CRITICAL: jq -r '.version' on null
	# returns the STRING "null" → previously would create a `vnull` tag.
	cd "$TEST_TMP" || return 1
	# Add a 4th commit with null version
	echo '{"version":null}' >.claude-plugin/plugin.json
	git commit -aq -m "null version (should be skipped)"
	# Add a 5th commit with valid version
	echo '{"version":"0.4.0"}' >.claude-plugin/plugin.json
	git commit -aq -m "v0.4.0"
	run scripts/backfill-tags.sh --skip-push --skip-release
	[ "$status" -eq 0 ]
	# Should NOT create vnull
	run git rev-parse -q --verify refs/tags/vnull
	[ "$status" -ne 0 ]
	# But SHOULD have skipped with a WARN to stderr
	[[ $output == *"missing/null/non-string"* ]]
	# And v0.4.0 still gets tagged (the null commit doesn't poison the walk)
	git rev-parse -q --verify refs/tags/v0.4.0 >/dev/null
}

@test "schema_version field present in every audit log entry" {
	# type-design-analyzer #139 r1 HIGH T1: every emitted JSONL row must
	# carry schema_version so downstream consumers can detect format drift.
	cd "$TEST_TMP" || return 1
	scripts/backfill-tags.sh --skip-push --skip-release >/dev/null
	[ -f .claude/logs/release-backfill.jsonl ]
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		echo "$line" | jq -e '.schema_version == 1' >/dev/null
	done <.claude/logs/release-backfill.jsonl
}
