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
# args to $GH_EDIT_LOG (the relabel assertions read it). An optional 2nd arg
# (a case-glob) makes any `gh issue edit` whose "$*" matches it exit 1 AFTER
# logging — to exercise the relabel-failure branches. Other gh calls no-op.
_write_gh_stub() {
	local fail_glob="${2:-}"
	{
		echo '#!/usr/bin/env bash'
		echo 'if [ "$1" = "issue" ] && [ "$2" = "view" ]; then [ -n "${GH_VIEW_LOG:-}" ] && echo "$*" >>"$GH_VIEW_LOG"; printf "%s" "$GH_VIEW_JSON"; exit 0; fi'
		if [ "${1:-}" = "edit-log" ]; then
			echo 'if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then'
			echo '  echo "$*" >>"$GH_EDIT_LOG"'
			if [ -n "$fail_glob" ]; then
				echo "  case \"\$*\" in $fail_glob) echo \"gh: edit failed (stub)\" >&2; exit 1 ;; esac"
			fi
			echo '  exit 0'
			echo 'fi'
			echo 'if [ "$1" = "label" ]; then echo "$*" >>"$GH_EDIT_LOG"; exit 0; fi'
		fi
		echo 'exit 0'
	} >"$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"
}

# One fixture builder (p1r1 code-reviewer): the gh view payload lives in
# ONE place, so the next `--json` field addition edits this function, not
# every literal in the file (the state/body addition needed a 4-fixture
# hand-sweep — never again).
#   $1 = labels csv ("plan-me,epic"; "" = none)
#   $2 = state ("" = field ABSENT, for the missing-state edge)
#   $3 = body
#   $4 = issue number (default 999)
_issue_json() {
	local labels_json
	labels_json=$(printf '%s' "$1" | jq -Rc 'split(",") | map(select(length > 0) | {name: .})')
	jq -nc --argjson labels "$labels_json" --arg state "$2" --arg body "$3" \
		--argjson num "${4:-999}" \
		'{labels: $labels, number: $num, title: "feat: x",
		  comments: [{author: {login: "coderabbitai"}, body: "## Implementation Steps - foo"}],
		  createdAt: "2026-01-01T00:00:00Z"}
		 + (if $state != "" then {state: $state} else {} end)
		 + {body: $body}'
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
	local j
	j=$(_issue_json "epic,plan-me" OPEN "ordinary hand-written issue body")
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
	local j
	j=$(_issue_json "plan-me" OPEN "ordinary hand-written issue body")
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
	local j
	j=$(_issue_json "plan-me" OPEN "ordinary hand-written issue body" 777)
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
	# CR-CLI r4+r6: assert the label-create AND its PRECEDENCE — the runaway
	# root-fix creates the plan-parsed label BEFORE the relabel (a missing label
	# was what made the combined relabel fail wholesale -> plan-me stayed ->
	# re-parse runaway). Prove label-create's log line precedes the first edit.
	run grep -q -- 'label create.*plan-parsed' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
	lc_line=$(grep -n -- 'label create.*plan-parsed' "$TEST_TMP/gh-edit.log" | head -1 | cut -d: -f1)
	ie_line=$(grep -n -- 'issue edit' "$TEST_TMP/gh-edit.log" | head -1 | cut -d: -f1)
	[ -n "$lc_line" ] && [ -n "$ie_line" ] && [ "$lc_line" -lt "$ie_line" ]
}

@test "plan-parsed ADD failure is non-fatal AND plan-me removal still runs (marker-first)" {
	# CR #223 follow-on: the relabel detection must NOT depend on `set -o
	# pipefail`, and a FAILED `--add-label plan-parsed` must be non-fatal AND must
	# NOT abort the subsequent `--remove-label plan-me` (the marker-first design
	# still drops plan-me so the poll set is bounded). Stub gh so ONLY the
	# add-label-plan-parsed edit returns non-zero; all other gh calls behave
	# normally + log their args.
	local j
	j=$(_issue_json "plan-me" OPEN "ordinary hand-written issue body" 777)
	cd "$TEST_TMP"
	# cr-plan no-op success (parse "succeeds") so we reach the relabel block.
	mkdir -p "$TEST_TMP/.claude/skills/cr-plan"
	{
		echo '#!/usr/bin/env bash'
		echo 'exit 0'
	} >"$TEST_TMP/.claude/skills/cr-plan/run.sh"
	chmod +x "$TEST_TMP/.claude/skills/cr-plan/run.sh"
	# Reuse the shared stub with a fail-glob so ONLY the --add-label plan-parsed
	# edit returns non-zero (after logging); every other gh call behaves normally.
	# NOTE: the inner double-quotes are REQUIRED. The helper interpolates this glob
	# UNQUOTED into a `case "$*" in <glob>)` pattern; the embedded space in
	# `--add-label plan-parsed` is a case-SYNTAX-ERROR without them (they are
	# shell-quoting in the pattern, NOT literal chars to match). Verified: `bash -n`
	# errors on the unquoted form (stub crashes rc=2, logs nothing) while the quoted
	# form matches + exits 1 correctly. (CR-CLI #223 flagged these as vacuous — wrong.)
	_write_gh_stub edit-log '*"--add-label plan-parsed"*'
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" GH_EDIT_LOG="$TEST_TMP/gh-edit.log" "$AP" --issue 777
	# Non-fatal: the script still exits 0 even though the marker-add failed.
	[ "$status" -eq 0 ]
	# Operator-facing WARN on the output channel.
	[[ $output == *"WARN: plan-parsed add failed"* ]]
	# Structured log records the failure event.
	run grep -q '"event":"label-add-failed"' "$LOG"
	[ "$status" -eq 0 ]
	# The marker-first design: the --remove-label plan-me edit STILL runs after
	# the add fails (so the poll set is bounded even on a marker-add failure).
	run grep -q -- '--remove-label plan-me' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
	# The marker-add WAS attempted (the stub logs the args BEFORE failing it) —
	# proves the failure path ran through the real add op, not a skip.
	run grep -q -- '--add-label plan-parsed' "$TEST_TMP/gh-edit.log"
	[ "$status" -eq 0 ]
}

@test "auto-created SUB-issue is SKIPPED — scaffolding never re-enters the parser (2026-08-25 explosion)" {
	# The June guard covered epic-labelled outputs only; ai-triage plan-me'd
	# the auto-created SUBS and the parser decomposed decompositions three
	# levels deep. Any body carrying the auto-created markers must skip.
	local j
	j=$(_issue_json "plan-me" OPEN "Sub-issue auto-created from CodeRabbit plan on epic for #2548.")
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	[[ $output != *"WOULD parse"* ]]
	run grep -q '"event":"skip-auto-scaffolding"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "epic that LOST its label is still skipped via the body marker (defense in depth)" {
	local j
	j=$(_issue_json "plan-me" OPEN "Epic auto-created from CodeRabbit plan on issue #2574.")
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	[[ $output != *"WOULD parse"* ]]
	run grep -q '"event":"skip-auto-scaffolding"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "a CLOSED source issue is never decomposed (close-race / --issue guard)" {
	# The bulk poll lists --state open, but --issue <N> and sources closed
	# mid-flight (batch-PR merge) reached the parser closed — creating
	# scaffolding for work that is already done (#2578 → #2623-#2625).
	local j
	j=$(_issue_json "plan-me" CLOSED "ordinary issue")
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	[[ $output != *"WOULD parse"* ]]
	run grep -q '"event":"skip-not-open"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "the tail marker ALONE is caught — degraded-body defense (p1r1 test-analyzer vs simplifier)" {
	# Pristine generated bodies carry BOTH markers (simplifier verified they
	# co-occur in one heredoc), so the second regex alternative fires alone
	# only on a DEGRADED body — top line edited/lost, tail Context intact.
	# That is precisely the case worth defending; this pins the alternative
	# as the SOLE matcher, answering both p1r1 findings.
	local j
	j=$(_issue_json "plan-me" OPEN 'Operator rewrote this intro. Auto-generated by `cr-plan parse 42`. Refer to parent epic.')
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	[[ $output != *"WOULD parse"* ]]
	run grep -q '"event":"skip-auto-scaffolding"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "MERGED state is skipped — the guard is an OPEN allowlist, not a CLOSED blocklist (p1r1)" {
	local j
	j=$(_issue_json "plan-me" MERGED "ordinary issue")
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	[[ $output != *"WOULD parse"* ]]
	run grep -q '"event":"skip-not-open"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "MISSING state field fails closed to skip (p1r1)" {
	local j
	j=$(_issue_json "plan-me" "" "ordinary issue")
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	[[ $output != *"WOULD parse"* ]]
	run grep -q '"event":"skip-not-open"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "the fetch REQUESTS state+body — stub-fidelity lock (p1r1 test-analyzer)" {
	# The gh stub echoes $GH_VIEW_JSON regardless of the --json field list,
	# so reverting the field additions would pass every fixture test while
	# production fail-closed-skipped EVERY issue on the missing .state.
	# Lock the requested fields via the stub's view-args log.
	local j
	j=$(_issue_json "plan-me" OPEN "ordinary hand-written issue body")
	cd "$TEST_TMP"
	run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" GH_VIEW_LOG="$TEST_TMP/gh-view.log" "$AP" --issue 999 --dry-run
	[ "$status" -eq 0 ]
	run grep -qE -- '--json [^ ]*state' "$TEST_TMP/gh-view.log"
	[ "$status" -eq 0 ]
	run grep -qE -- '--json [^ ]*body' "$TEST_TMP/gh-view.log"
	[ "$status" -eq 0 ]
}

@test "DRIFT LOCK: the guard regex matches the REAL producer templates (p1r1 code-reviewer)" {
	# The markers are prose emitted by heredocs in skills/cr-plan/run.sh; a
	# wording edit there must break THIS test loudly, not silently un-arm a
	# fail-closed guard. Extract each literal from the producer source and
	# drive it through the real guard.
	local producer="$PLUGIN/skills/cr-plan/run.sh"
	local m1 m2 m3
	m1=$(grep -o 'Epic auto-created from CodeRabbit plan on issue' "$producer" | head -1)
	m2=$(grep -o 'Sub-issue auto-created from CodeRabbit plan on epic' "$producer" | head -1)
	# The producer SOURCE escapes the backtick inside its heredoc (\`);
	# rendered issue bodies carry a plain backtick. Anchor to line-start —
	# the heredoc template begins its line with the marker, while the
	# skill's own guard REGEX carries the same words mid-line (grepping
	# unanchored extracted the regex, not the template). Then RENDER
	# (strip the backslash) — the guard sees bodies, never source.
	m3=$(grep -oE '^Auto-generated by ..?cr-plan parse' "$producer" | head -1 | sed 's/\\//g')
	[ -n "$m1" ] || {
		echo "producer EPIC marker moved — update the guard regex + this test"
		return 1
	}
	[ -n "$m2" ] || {
		echo "producer SUB marker moved — update the guard regex + this test"
		return 1
	}
	[ -n "$m3" ] || {
		echo "producer Context marker moved — update the guard regex + this test"
		return 1
	}
	cd "$TEST_TMP"
	local body j
	for body in "$m1 #9." "$m2 for #9." "prose intro. $m3 9\`."; do
		j=$(_issue_json "plan-me" OPEN "$body")
		rm -f "$LOG"
		run env PATH="$TEST_TMP/bin:$PATH" GH_VIEW_JSON="$j" "$AP" --issue 999 --dry-run
		[ "$status" -eq 0 ]
		run grep -q '"event":"skip-auto-scaffolding"' "$LOG"
		[ "$status" -eq 0 ] || {
			echo "guard MISSED a real producer marker: $body"
			return 1
		}
	done
}
