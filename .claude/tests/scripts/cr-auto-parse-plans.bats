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

# Writes the PATH-stubbed `gh` to $TEST_TMP/bin/gh. `gh issue view` echoes
# $GH_VIEW_JSON; pass "edit-log" to ALSO record `gh issue edit` AND `gh label`
# args to $GH_EDIT_LOG (the relabel assertions read it). Other gh calls no-op.
_write_gh_stub() {
	{
		echo '#!/usr/bin/env bash'
		echo 'if [ "$1" = "issue" ] && [ "$2" = "view" ]; then printf "%s" "$GH_VIEW_JSON"; exit 0; fi'
		if [ "${1:-}" = "edit-log" ]; then
			echo 'if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then echo "$*" >>"$GH_EDIT_LOG"; exit 0; fi'
			echo 'if [ "$1" = "label" ]; then echo "$*" >>"$GH_EDIT_LOG"; exit 0; fi'
		fi
		echo 'exit 0'
	} >"$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"
}

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
	# gh stub: the --issue --dry-run path only calls `gh issue view` (echoes
	# $GH_VIEW_JSON); all other gh calls are benign no-ops.
	_write_gh_stub
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
	# CR #223: assert the OUTPUT channel too (not just the log file) — the epic
	# is skipped on the `epic` label BEFORE the would-parse stderr line, so the
	# "WOULD parse" message must be ABSENT from $output (stdout+stderr merged).
	[[ $output != *"WOULD parse"* ]]
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
	# CR #223: the dry-run would-parse path emits a "WOULD parse" stderr line and
	# never the epic-skip — assert both on the output channel.
	[[ $output == *"WOULD parse issue #999"* ]]
	run grep -q '"event":"would-parse"' "$LOG"
	[ "$status" -eq 0 ]
	run grep -q '"event":"skip-epic"' "$LOG"
	[ "$status" -ne 0 ]
}

@test "non-dry-run parse relabels plan-parsed + REMOVES plan-me (poll-bounding)" {
	# CR #478 phase2 r1: the relabel path (post-parse `gh issue edit --add-label
	# plan-parsed --remove-label plan-me`, which BOUNDS the poll set so parsed
	# issues leave it) ran only under --dry-run, so it was never exercised. Stub
	# cr-plan (no-op success) at the first-candidate path + capture the gh edit;
	# assert BOTH the parse event and the exact relabel fire.
	local j='{"labels":[{"name":"plan-me"}],"number":777,"title":"feat: y","comments":[{"author":{"login":"coderabbitai"},"body":"## Implementation Steps - foo"}],"createdAt":"2026-01-01T00:00:00Z"}'
	cd "$TEST_TMP"
	# cr-plan resolves $REPO_ROOT/.claude/skills/cr-plan/run.sh first (REPO_ROOT
	# == this tmp git repo) — stub it as a no-op success so parse "succeeds".
	mkdir -p "$TEST_TMP/.claude/skills/cr-plan"
	{
		echo '#!/usr/bin/env bash'
		echo 'exit 0'
	} >"$TEST_TMP/.claude/skills/cr-plan/run.sh"
	chmod +x "$TEST_TMP/.claude/skills/cr-plan/run.sh"
	# gh stub WITH edit-logging: `issue view` echoes the payload; `issue edit`
	# args are recorded to $GH_EDIT_LOG so the relabel can be asserted.
	_write_gh_stub edit-log
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" GH_EDIT_LOG="$TEST_TMP/gh-edit.log" "$AP" --issue 777
	[ "$status" -eq 0 ]
	# CR #223: assert the parse progress message on the output channel too (not
	# just the log/gh-edit side effects) so a stderr-message regression is caught.
	[[ $output == *"parsed issue #777"* ]]
	run grep -q '"event":"parsed"' "$LOG"
	[ "$status" -eq 0 ]
	# CR #478 r2: assert each flag independently (order-/coalescing-agnostic).
	run grep -q 'issue edit 777' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
	run grep -q -- '--add-label plan-parsed' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
	run grep -q -- '--remove-label plan-me' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
	# CR-CLI r4: assert the label-create too — the runaway root-fix ensures the
	# plan-parsed label EXISTS before the relabel (a missing label was what let
	# the combined relabel fail wholesale -> plan-me stayed -> re-parse runaway).
	run grep -q -- 'label create.*plan-parsed' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
}
