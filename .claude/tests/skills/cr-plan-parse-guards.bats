#!/usr/bin/env bats
# covers: skills/cr-plan/run.sh
#
# 2026-08-25 board explosion, p1r1 code-reviewer (c9): the recursion/state
# guards must live at the CHOKE POINT every entrypoint funnels through —
# auto-parse-plans is only ONE caller; ship-pr-cycle `epic parse` execs
# this skill directly and SKILL.md documents direct `APPROVE=1 run.sh
# parse <N>`. These tests drive the REAL skill with a PATH-stubbed gh and
# pin: scaffolding bodies refuse, non-OPEN sources refuse, and a clean
# open issue passes BOTH guards (proven by reaching the NEXT check's
# distinct error, not by absence of failure).
# shellcheck disable=SC2030,SC2031

_issue_json() { # $1=labels csv  $2=state (""=absent)  $3=body
	local labels_json
	labels_json=$(printf '%s' "$1" | jq -Rc 'split(",") | map(select(length > 0) | {name: .})')
	jq -nc --argjson labels "$labels_json" --arg state "$2" --arg body "$3" \
		'{number: 999, labels: $labels, title: "feat: x"}
		 + (if $state != "" then {state: $state} else {} end)
		 + {body: $body}'
}

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SKILL="$PLUGIN/skills/cr-plan/run.sh"
	[ -x "$SKILL" ]
	TEST_TMP=$(mktemp -d -t cr-plan-guards.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q
		git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
		mkdir -p bin
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	printf '#!/usr/bin/env bash\nif [ "$1" = "issue" ] && [ "$2" = "view" ]; then printf "%%s" "$GH_VIEW_JSON"; exit 0; fi\nexit 0\n' >"$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"
}

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */cr-plan-guards.* ]] && rm -rf "$TEST_TMP"
}

_run_parse() {
	run env PATH="$TEST_TMP/bin:$PATH" APPROVE=1 GH_VIEW_JSON="$1" "$SKILL" parse 999
}

@test "choke point: a scaffolding BODY refuses parse regardless of caller (p1r1 c9)" {
	cd "$TEST_TMP"
	_run_parse "$(_issue_json "plan-me" OPEN "Sub-issue auto-created from CodeRabbit plan on epic for #2548.")"
	[ "$status" -eq 2 ]
	[[ $output == *"SCAFFOLDING"* ]]
	[[ $output == *"never parse inputs"* ]]
}

@test "choke point: a CLOSED source refuses parse regardless of caller (p1r1 c9)" {
	cd "$TEST_TMP"
	_run_parse "$(_issue_json "plan-me" CLOSED "ordinary issue body")"
	[ "$status" -eq 2 ]
	[[ $output == *"not OPEN"* ]]
	[[ $output == *"never decomposed"* ]]
}

@test "choke point: MISSING state fails closed (p1r1 c9)" {
	cd "$TEST_TMP"
	_run_parse "$(_issue_json "plan-me" "" "ordinary issue body")"
	[ "$status" -eq 2 ]
	[[ $output == *"not OPEN"* ]]
}

@test "choke point: a clean OPEN issue passes BOTH guards (not over-broad)" {
	# Positive control: guards must NOT trip — proven by reaching a check
	# WELL BEYOND both guards: the stub ignores --jq and echoes the whole
	# payload as the "plan body", so the run reaches the plan-STRUCTURE
	# validation (several checks past the guards) and fails with its
	# distinct error.
	cd "$TEST_TMP"
	_run_parse "$(_issue_json "plan-me" OPEN "ordinary hand-written issue body")"
	[ "$status" -eq 2 ]
	[[ $output != *"SCAFFOLDING"* ]]
	[[ $output != *"not OPEN"* ]]
	[[ $output == *"CR plan structure differs"* ]]
}
