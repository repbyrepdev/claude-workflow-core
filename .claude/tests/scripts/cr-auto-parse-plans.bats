#!/usr/bin/env bats
# covers: scripts/cr/auto-parse-plans.sh
#
# cr-auto-parse runaway (2026-06-02): auto-parse-plans.sh re-parsed `epic`
# issues — which are its OWN outputs — re-decomposing them into nested
# "EPIC: EPIC: ..." duplicates (800+ created in a single day, all under the
# user token, in SessionStart poll bursts). Root fix: skip any issue carrying
# the `epic` label (an epic is a parse OUTPUT, never an INPUT). These tests
# lock that guard AND prove it isn't over-broad (a non-epic plan-me issue with
# a CR plan still parses). Drives the REAL script with a PATH-stubbed `gh` in a
# tmp git repo, mirroring cr-local-review.bats.
# shellcheck disable=SC2030,SC2031

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	AP="$PLUGIN/scripts/cr/auto-parse-plans.sh"
	[ -x "$AP" ]
	command -v git >/dev/null
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t cr-autoparse.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p bin .claude/logs
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	# gh stub: the --issue --dry-run path only calls `gh issue view`; echo the
	# per-test JSON from $GH_VIEW_JSON. All other gh calls are benign no-ops.
	{
		echo '#!/usr/bin/env bash'
		echo 'if [ "$1" = "issue" ] && [ "$2" = "view" ]; then printf "%s" "$GH_VIEW_JSON"; exit 0; fi'
		echo 'exit 0'
	} >"$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"
	LOG="$TEST_TMP/.claude/logs/cr-auto-parse.jsonl"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cr-autoparse.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "epic-labelled issue is SKIPPED, never parsed (anti-nesting guard)" {
	# epic + plan-me + a CR plan present: the OLD code WOULD parse it (creating a
	# nested epic); the fix must skip it on the `epic` label.
	local j='{"labels":[{"name":"epic"},{"name":"plan-me"}],"number":999,"title":"EPIC: x","comments":[{"author":{"login":"coderabbitai"},"body":"## Implementation Steps - foo"}],"createdAt":"2026-01-01T00:00:00Z"}'
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	run grep -q '"event":"skip-epic"' "$LOG"
	[ "$status" -eq 0 ]
	run grep -q '"event":"would-parse"' "$LOG"
	[ "$status" -ne 0 ]
}

@test "non-epic plan-me issue WITH a CR plan WOULD parse (guard not over-broad)" {
	local j='{"labels":[{"name":"plan-me"}],"number":999,"title":"feat: x","comments":[{"author":{"login":"coderabbitai"},"body":"## Implementation Steps - foo"}],"createdAt":"2026-01-01T00:00:00Z"}'
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	run grep -q '"event":"would-parse"' "$LOG"
	[ "$status" -eq 0 ]
	run grep -q '"event":"skip-epic"' "$LOG"
	[ "$status" -ne 0 ]
}
