#!/usr/bin/env bats
# covers: hooks/skill-bypass-guard.sh
#
# v0.31 #224 (guard self-defeat): the guard's model-facing deny directives must
# NOT advertise SKILL_WRAPPER=1 as a typable bypass — doing so trains the exact
# escape the guard exists to block (empirically: a blocked model re-issues with
# the prefix and passes). These lock the advert removal from BOTH directives
# (skill + bats) while proving (a) the legitimate GH_SKILL_BYPASS_SKIP emergency
# escape is still offered and (b) the SKILL_WRAPPER matcher itself is untouched
# (wrappers + shared hooks depend on it).

setup() {
	GUARD="${BATS_TEST_DIRNAME}/../../../hooks/skill-bypass-guard.sh"
	[ -f "$GUARD" ]
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t skillguard.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# An inherited bypass env would short-circuit the guard before the deny path.
	unset SKILL_WRAPPER GH_SKILL_BYPASS_SKIP PHASE1_GATE_SKIP
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */skillguard.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Feed a PreToolUse payload (JSON via stdin); command written to a file to avoid
# quoting hazards. cwd = tmp so any git resolution stays out of the plugin repo.
_run_guard() {
	jq -nc --arg c "$1" '{tool_input:{command:$c}}' >"$TEST_TMP/payload.json"
	run bash -c "cd '$TEST_TMP' && bash '$GUARD' < '$TEST_TMP/payload.json'"
}

@test "raw 'gh issue create' is blocked (deny emitted)" {
	_run_guard "gh issue create --title x"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "skill deny directive does NOT advertise SKILL_WRAPPER bypass (#224)" {
	_run_guard "gh issue create --title x"
	# r2 (pr-test-analyzer): assert a real deny FIRST so the negative checks below
	# can't pass vacuously on an error path that emitted no directive.
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	[[ $output != *"Sanctioned skill-wrapper"* ]]
	[[ $output != *"SKILL_WRAPPER=1 <your-command>"* ]]
	# the legitimate emergency escape is still offered
	[[ $output == *"GH_SKILL_BYPASS_SKIP"* ]]
}

@test "bats deny directive does NOT advertise SKILL_WRAPPER bypass (#224)" {
	_run_guard "bats foo.bats"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	[[ $output != *"Sanctioned wrapper path"* ]]
	[[ $output != *"SKILL_WRAPPER=1 bats"* ]]
	[[ $output == *"GH_SKILL_BYPASS_SKIP"* ]]
}

@test "SKILL_WRAPPER=1 prefix still bypasses the guard — matcher intact (#224)" {
	# The advert is removed but the MATCHER must stay: a SKILL_WRAPPER=1-prefixed
	# command passes through (exit 0, no deny) so wrappers + shared hooks keep working.
	_run_guard "SKILL_WRAPPER=1 gh issue create --title x"
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "wrapper/grouping prefixes no longer slip the guard (#2396)" {
	# Pre-#2396 these all failed OPEN: the anchor accepted only the bare form
	# (plus env assignments), so grouping/wrapper prefixes hid the verb.
	_run_guard "{ gh issue create --title x; }"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	_run_guard "(gh pr create --title x)"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	_run_guard "command gh release create v1.0.0"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	_run_guard "sudo -E gh pr merge 5"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	_run_guard "env X=1 bats foo.bats"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "quoted mid-string verbs still pass after #2396 (no new false fires)" {
	_run_guard 'git log --grep "gh issue create" --oneline'
	[ "$status" -eq 0 ]
	[[ $output != *'"permissionDecision":"deny"'* ]]
}
