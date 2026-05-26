#!/usr/bin/env bats
# covers: hooks/post-merge-release-fire.sh
#
# Tests for the post-merge release auto-fire hook (#88).

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../hooks/post-merge-release-fire.sh"
	READER="${BATS_TEST_DIRNAME}/../../../hooks/_read-actions-mode.sh"
	TEST_TMP=$(mktemp -d -t pmrf.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p .claude-plugin .claude hooks scripts
		printf '{"name":"t","version":"0.9.5"}\n' >.claude-plugin/plugin.json
		cp "$READER" hooks/_read-actions-mode.sh
		chmod +x hooks/_read-actions-mode.sh
		# Stub release.sh: writes a 'started' breadcrumb relative to its
		# own location so tests don't depend on env-var passthrough.
		cat >scripts/release.sh <<'EOF'
#!/bin/bash
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$ROOT/.claude/logs"
printf 'release.sh fired at %s\n' "$(date -u +%s)" >>"$ROOT/.claude/logs/release-stub.log"
EOF
		chmod +x scripts/release.sh
		git add . && git -c user.email=t@t -c user.name=t commit -q -m baseline
	) || return 1
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	# Wait briefly for any detached release.sh stub to finish writing
	# its breadcrumb before rm-rf — fork+write completes in <50ms.
	sleep 0.2
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */pmrf.* ]]; then
		rm -rf "$TEST_TMP" 2>/dev/null || {
			sleep 0.5
			rm -rf "$TEST_TMP"
		}
	fi
}

# Helper: bump plugin.json.version then commit. Caller runs the hook.
_bump() {
	local new_ver=$1
	(
		cd "$TEST_TMP" || exit 1
		jq --arg v "$new_ver" '.version=$v' .claude-plugin/plugin.json >.claude-plugin/plugin.json.new
		mv .claude-plugin/plugin.json.new .claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git -c user.email=t@t -c user.name=t commit -q -m "bump to $new_ver"
	)
}

# Helper: invoke the hook from TEST_TMP without a subshell-scoped run.
# Returns hook's stdout+stderr via $output and rc via $status.
_run_hook() {
	bash -c "cd '$TEST_TMP' && bash '$SCRIPT' 2>&1"
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
	run _run_hook
	[ "$status" -eq 0 ]
}

@test "malformed plugin.json → exit 2" {
	echo "not json" >"$TEST_TMP/.claude-plugin/plugin.json"
	run _run_hook
	[ "$status" -eq 2 ]
	[[ $output == *"failed jq validation"* ]]
}

@test "ACTIONS_MODE=remote → no-op (workflow authoritative)" {
	printf 'ACTIONS_MODE=remote\n' >"$TEST_TMP/.claude/mode.conf"
	run _run_hook
	[ "$status" -eq 0 ]
	[[ $output == *"ACTIONS_MODE=remote"* ]]
	[[ $output == *"hook no-op"* ]]
}

@test "version unchanged → logs no-version-change + exits 0" {
	# Setup left HEAD at baseline with version 0.9.5. Add a third
	# commit that does NOT touch plugin.json so HEAD~1 also has 0.9.5.
	(
		cd "$TEST_TMP" || exit 1
		echo "noop" >readme.txt
		git add readme.txt
		git -c user.email=t@t -c user.name=t commit -q -m "no version change"
	)
	run _run_hook
	[ "$status" -eq 0 ]
	# JSONL log records the no-op invocation (every invocation logged).
	[ -f "$TEST_TMP/.claude/logs/release-auto-fire.jsonl" ]
	grep -q '"status":"no-version-change"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	# No fire entry.
	run grep -q '"status":"fired"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	[ "$status" -ne 0 ]
}

@test "version bump 0.9.5 → 0.9.6 fires release.sh + writes valid JSONL" {
	_bump "0.9.6"
	run _run_hook
	[ "$status" -eq 0 ]
	[[ $output == *"0.9.5 → 0.9.6"* ]]
	[[ $output == *"release.sh spawned"* ]]
	# JSONL line parses as valid JSON
	jq -c . <"$TEST_TMP/.claude/logs/release-auto-fire.jsonl" >/dev/null
	# Field assertions
	grep -q '"from":"0.9.5"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	grep -q '"to":"0.9.6"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	grep -q '"status":"fired"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
	# Poll for stub.log proving release.sh actually executed (closes
	# the missing detached-spawn-execution verification gap).
	local stub="$TEST_TMP/.claude/logs/release-stub.log"
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		[ -s "$stub" ] && break
		sleep 0.1
	done
	[ -s "$stub" ]
	grep -q "release.sh fired at" "$stub"
}

@test "release.sh missing → exit 2 with missing-release-sh log entry" {
	rm "$TEST_TMP/scripts/release.sh"
	_bump "0.9.7"
	run _run_hook
	[ "$status" -eq 2 ]
	[[ $output == *"cannot fire release"* ]]
	grep -q '"status":"missing-release-sh"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl"
}

@test "semver downgrade 0.9.5 → 0.9.4 still fires (release.sh dedups downstream)" {
	# Hook detects ANY version change. release.sh has its own
	# version-regression check (refuses to tag older versions). Hook
	# stays simple — no policy duplication.
	_bump "0.9.4"
	run _run_hook
	[ "$status" -eq 0 ]
	[[ $output == *"0.9.5 → 0.9.4"* ]]
	[[ $output == *"release.sh spawned"* ]]
}

@test "two consecutive bumps both fire (hook isn't idempotent — release.sh dedups)" {
	_bump "0.9.6"
	run _run_hook
	[ "$status" -eq 0 ]
	_bump "0.9.7"
	run _run_hook
	[ "$status" -eq 0 ]
	[ "$(grep -c '"status":"fired"' "$TEST_TMP/.claude/logs/release-auto-fire.jsonl")" -eq 2 ]
}

@test "first-introduction (no plugin.json on HEAD~1) → fired-first-introduction" {
	# Fresh repo: baseline commit WITHOUT plugin.json, then a commit
	# that introduces plugin.json with .version.
	local newdir
	newdir=$(mktemp -d -t pmrf-fresh.XXXXXX)
	(
		cd "$newdir" || exit 1
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m "no plugin yet"
		mkdir -p .claude-plugin .claude hooks scripts
		cp "$READER" hooks/_read-actions-mode.sh
		chmod +x hooks/_read-actions-mode.sh
		cat >scripts/release.sh <<'EOF'
#!/bin/bash
exit 0
EOF
		chmod +x scripts/release.sh
		printf '{"name":"t","version":"1.0.0"}\n' >.claude-plugin/plugin.json
		git add . && git -c user.email=t@t -c user.name=t commit -q -m "introduce plugin.json"
	)
	run bash -c "cd '$newdir' && bash '$SCRIPT' 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"first-introduction"* ]]
	grep -q '"status":"fired-first-introduction"' "$newdir/.claude/logs/release-auto-fire.jsonl"
	grep -q '"from":""' "$newdir/.claude/logs/release-auto-fire.jsonl"
	grep -q '"to":"1.0.0"' "$newdir/.claude/logs/release-auto-fire.jsonl"
	rm -rf "$newdir"
}

@test "malformed .version on HEAD (numeric) → exit 2" {
	(
		cd "$TEST_TMP" || exit 1
		printf '{"name":"t","version":100}\n' >.claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git -c user.email=t@t -c user.name=t commit -q -m "bad version"
	)
	run _run_hook
	[ "$status" -eq 2 ]
	[[ $output == *"not X.Y.Z"* ]]
}

@test "ACTIONS_MODE reader missing → exit 2" {
	rm "$TEST_TMP/hooks/_read-actions-mode.sh"
	run _run_hook
	[ "$status" -eq 2 ]
	[[ $output == *"missing or not executable"* ]]
}

@test "JSONL log entries survive special characters in version (jq escapes)" {
	# Force a malformed version through validation OFF — set on disk
	# by hand to bypass the gates. Hook should refuse early (exit 2)
	# rather than emit corrupt JSONL with raw special chars.
	(
		cd "$TEST_TMP" || exit 1
		# Construct a manifest with a tricky-but-valid-JSON version.
		printf '{"name":"t","version":"0.9.6\\"evil"}\n' >.claude-plugin/plugin.json
		jq empty .claude-plugin/plugin.json
		git add .claude-plugin/plugin.json
		git -c user.email=t@t -c user.name=t commit -q -m "evil version"
	)
	run _run_hook
	[ "$status" -eq 2 ]
	[[ $output == *"not X.Y.Z"* ]]
}
