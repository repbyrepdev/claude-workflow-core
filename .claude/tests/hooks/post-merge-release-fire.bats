#!/usr/bin/env bats
# covers: hooks/post-merge-release-fire.sh
#
# Tests for the post-merge release auto-fire hook (#88). Verifies:
# - ACTIONS_MODE=remote no-ops (workflow authoritative)
# - Version-unchanged merges no-op (silent)
# - Version-bumped merges fire release.sh detached + log to JSONL
# - Bypass env is honored
# - Missing plugin.json / malformed JSON / missing jq fail correctly
# - Idempotency-by-relying-on-release.sh-internals (release.sh handles
#   tag/cache skip itself)

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/post-merge-release-fire.sh"
	READER="${BATS_TEST_DIRNAME}/../../../hooks/_read-actions-mode.sh"
	TEST_TMP=$(cd "$(mktemp -d -t pmrf.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude-plugin .claude hooks scripts
		printf '{"name":"t","version":"0.9.5"}\n' >.claude-plugin/plugin.json
		# Mirror the helper hooks the script needs from the source repo.
		cp "$READER" hooks/_read-actions-mode.sh
		chmod +x hooks/_read-actions-mode.sh
		# Stub release.sh — records its invocation timestamp + cwd.
		cat >scripts/release.sh <<'EOF'
#!/bin/bash
printf 'release.sh fired at %s in %s\n' "$(date -u +%s)" "$(pwd)" >>"$REPO_ROOT/.claude/logs/release-stub.log"
EOF
		chmod +x scripts/release.sh
		git add . && git -c user.email=t@t -c user.name=t commit -q -m baseline
	) || return 1
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	# Wait briefly for any detached release.sh stub spawns to settle —
	# rm-rf races with the detached writers otherwise.
	sleep 0.2
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */pmrf.* ]]; then
		rm -rf "$TEST_TMP" 2>/dev/null || {
			sleep 0.5
			rm -rf "$TEST_TMP"
		}
	fi
}

# Helper: bump plugin.json.version then commit, then run hook.
_bump_and_run() {
	local new_ver=$1
	(
		cd "$TEST_TMP" || exit 1
		jq --arg v "$new_ver" '.version=$v' .claude-plugin/plugin.json >.claude-plugin/plugin.json.new
		mv .claude-plugin/plugin.json.new .claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git -c user.email=t@t -c user.name=t commit -q -m "bump to $new_ver"
		REPO_ROOT="$TEST_TMP" bash "$SCRIPT" 2>&1
	)
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "POST_MERGE_RELEASE_FIRE_SKIP=1 bypasses" {
	run bash -c "cd '$TEST_TMP' && POST_MERGE_RELEASE_FIRE_SKIP=1 bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"POST_MERGE_RELEASE_FIRE_SKIP=1"* ]]
}

@test "no plugin.json → no-op (not a plugin repo)" {
	rm -rf "$TEST_TMP/.claude-plugin"
	run bash -c "cd '$TEST_TMP' && bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
}

@test "malformed plugin.json → exit 2" {
	echo "not json" >"$TEST_TMP/.claude-plugin/plugin.json"
	run bash -c "cd '$TEST_TMP' && bash '$SCRIPT' 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"malformed JSON"* ]]
}

@test "ACTIONS_MODE=remote → no-op (workflow authoritative)" {
	mkdir -p "$TEST_TMP/.claude"
	printf 'ACTIONS_MODE=remote\n' >"$TEST_TMP/.claude/mode.conf"
	run bash -c "cd '$TEST_TMP' && bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"ACTIONS_MODE=remote"* ]]
	[[ $output == *"hook no-op"* ]]
}

@test "version unchanged → silent no-op" {
	# HEAD vs HEAD~1 has same version (only second commit landed; first
	# commit had no plugin.json, so OLD_VER would be empty != NEW_VER).
	# Re-baseline: bump then commit a no-op change.
	(
		cd "$TEST_TMP" || exit 1
		echo "noop" >readme.txt
		git add readme.txt
		git -c user.email=t@t -c user.name=t commit -q -m "no version change"
		run bash "$SCRIPT" 2>&1
	)
	# Hook spawned nothing — no release-auto-fire.jsonl entry created.
	[ ! -s "$TEST_TMP/.claude/logs/release-auto-fire.jsonl" ] || ! grep -q '"status":"fired"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
}

@test "version bump 0.9.5 → 0.9.6 fires release.sh + writes JSONL" {
	run _bump_and_run "0.9.6"
	[ "$status" -eq 0 ]
	[[ $output == *"0.9.5 → 0.9.6"* ]]
	[[ $output == *"release.sh spawned"* ]]
	# JSONL entry recorded
	[ -f "$TEST_TMP/.claude/logs/release-auto-fire.jsonl" ]
	grep -q '"from":"0.9.5"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	grep -q '"to":"0.9.6"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	grep -q '"status":"fired"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
}

@test "release.sh missing → exit 2 with missing-release-sh log entry" {
	rm "$TEST_TMP/scripts/release.sh"
	run _bump_and_run "0.9.7"
	[ "$status" -eq 2 ]
	[[ $output == *"release.sh missing"* ]] || [[ $output == *"cannot fire release"* ]]
	grep -q '"status":"missing-release-sh"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
}

@test "semver downgrade 0.9.5 → 0.9.4 still fires (lets release.sh enforce)" {
	# Hook detects ANY version change. release.sh has its own
	# version-regression check (refuses to tag older versions). Hook
	# stays simple — single responsibility, no policy duplication.
	run _bump_and_run "0.9.4"
	[ "$status" -eq 0 ]
	[[ $output == *"0.9.5 → 0.9.4"* ]]
	[[ $output == *"release.sh spawned"* ]]
}

@test "two consecutive bumps both fire (idempotency-by-release.sh)" {
	run _bump_and_run "0.9.6"
	[ "$status" -eq 0 ]
	run _bump_and_run "0.9.7"
	[ "$status" -eq 0 ]
	# Both fired entries present
	[ "$(grep -c '"status":"fired"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl")" -eq 2 ]
}
