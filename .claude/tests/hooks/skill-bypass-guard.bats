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
#
# #2396: plus coverage that wrapper/grouping/env prefixes (CMD_HARDENED_PREFIX)
# no longer slip the guard, a quoted-mid-string no-false-fire regression, and
# the documented widened bound for quoted "separator + wrapper + verb" text.

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

@test "mixed-version degradation: pre-#2396 lib still DENIES bare + env-prefixed verbs (phase2 r2)" {
	# Sandbox layout: copy the guard into .claude/hooks + stub a pre-#2396
	# cmd-anchor (no CMD_HARDENED_PREFIX) into .claude/_lib, symlinking the
	# other real libs the guard sources. The else-branch ENV_PREFIX fallback
	# must keep the deny working (an aborting PreToolUse hook is non-blocking
	# = fail-open).
	local real_hooks real_libs
	real_hooks="${BATS_TEST_DIRNAME}/../../../hooks"
	real_libs="${BATS_TEST_DIRNAME}/../../../_lib"
	mkdir -p "$TEST_TMP/.claude/hooks" "$TEST_TMP/.claude/_lib"
	cp "$real_hooks/skill-bypass-guard.sh" "$TEST_TMP/.claude/hooks/"
	for lib in "$real_libs"/*.sh; do
		base=$(basename "$lib")
		[ "$base" = "cmd-anchor.sh" ] && continue
		ln -s "$lib" "$TEST_TMP/.claude/_lib/$base"
	done
	cat >"$TEST_TMP/.claude/_lib/cmd-anchor.sh" <<'EOF'
#!/bin/bash
CMD_SEGMENT_ANCHOR='(^|[;&|][[:space:]]*)'
CMD_SEGMENT_END='([[:space:]]|$)'
EOF
	jq -nc --arg c "gh issue create --title x" '{tool_input:{command:$c}}' >"$TEST_TMP/payload.json"
	run bash -c "cd '$TEST_TMP' && bash '$TEST_TMP/.claude/hooks/skill-bypass-guard.sh' < '$TEST_TMP/payload.json'"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
	jq -nc --arg c "FOO=bar gh pr merge 5" '{tool_input:{command:$c}}' >"$TEST_TMP/payload.json"
	run bash -c "cd '$TEST_TMP' && bash '$TEST_TMP/.claude/hooks/skill-bypass-guard.sh' < '$TEST_TMP/payload.json'"
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "documented bound: quoted 'separator + wrapper + verb' text false-fires by design (#2396)" {
	# The hardened prefix cannot see quote context, so a quoted string that
	# contains a separator followed by a grouping/wrapper token and a guarded
	# verb now DENIES even when the OUTER command is benign — an accepted
	# fail-toward-deny trade-off (pre-#2396 the `{ ` after the quoted `;`
	# broke the env-only prefix and it passed). Pinned so a future false-deny
	# report is triaged as known-bound, and a deliberate fix must consciously
	# rewrite this test.
	_run_guard 'echo "fix; { gh pr merge 1; } later"'
	[ "$status" -eq 0 ]
	[[ $output == *'"permissionDecision":"deny"'* ]]
}
