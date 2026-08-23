#!/usr/bin/env bats
# covers: hooks/phase1-log-pending-gate.sh _lib/cmd-launder-screen.sh
#
# v0.34.123 (#2535 r1): this gate had two defects, one security and one
# throughput, and NO test file at all.
#
#  1. SECURITY — its review-log.sh escape used the same regex confirmed
#     exploitable in phase1-directive-pending-guard.sh: an arbitrary
#     `NAME=value` env prefix (so `BASH_ENV=./evil.sh …` sourced attacker code,
#     review-log.sh having a `#!/bin/bash` shebang) and no `^`/end anchor (so
#     `<anything>; .claude/hooks/review-log.sh` was admitted whole).
#  2. THROUGHPUT — it blocked Agent calls. Agents are ASYNC: the pending file is
#     written when the Agent tool call RETURNS (i.e. at launch), but the findings
#     count only exists ~10 min later when the agent completes. The gate demanded
#     a number that could not yet exist and refused every call until given it,
#     collapsing the directive's "5 parallel Agent calls" into a serialized
#     fire→block→wait→log chain with the operator wedged between each step.
#
# The #721 property that MUST survive both fixes: productive work (Bash / Edit /
# Write) stays blocked until every pending agent is logged.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/phase1-log-pending-gate.sh"
	[ -f "$HOOK" ] || return 1
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t lpgate.XXXXXX) || return 1
	mkdir -p "$TEST_TMP/.claude/.session-state/phase1-log-pending"
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
	)
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */lpgate.* ]] && rm -rf "$TEST_TMP"
	return 0
}

_pend() { printf 'x\n' >"$TEST_TMP/.claude/.session-state/phase1-log-pending/code-reviewer-abc.txt"; }

# Deny travels as a JSON permissionDecision on stdout with rc 0, OR as a
# non-zero rc from the fallback hook_deny when hook-deny.sh is unreachable.
_verdict() {
	local out st=0
	out=$(cd "$TEST_TMP" && printf '%s' "$1" | "$HOOK" 2>/dev/null) || st=$?
	if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
		echo deny
	elif [ "$st" -eq 2 ]; then
		echo deny
	elif [ "$st" -eq 0 ]; then
		echo allow
	else
		echo "error(st=$st)"
	fi
}

@test "no pending files → everything allowed" {
	run _verdict '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
	[ "$output" = allow ] || return 1
}

# --- throughput fix: async agents ------------------------------------------

@test "Agent calls are ALLOWED while a log is pending (async parallel block)" {
	_pend
	run _verdict '{"tool_name":"Agent","tool_input":{"subagent_type":"pr-review-toolkit:code-reviewer"}}'
	[ "$output" = allow ] || return 1
}

@test "Skill calls are ALLOWED while a log is pending" {
	_pend
	run _verdict '{"tool_name":"Skill","tool_input":{"command":"security-review"}}'
	[ "$output" = allow ] || return 1
}

# --- #721 property preserved -----------------------------------------------

@test "Bash is still DENIED while a log is pending" {
	_pend
	run _verdict '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
	[ "$output" = deny ] || return 1
}

@test "deny message tells the operator Agent/Skill calls are permitted in parallel" {
	# _verdict drops stderr and reduces to allow/deny, so the deny TEXT — the
	# operator-facing instruction that makes the async behavior usable — was
	# unasserted (CR-in-CI #2540). Capture BOTH streams (hook_deny may route the
	# reason to the stdout JSON or to stderr) and assert the instruction survives.
	_pend
	run bash -c "cd '$TEST_TMP' && printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi\"}}' | '$HOOK' 2>&1"
	# It is a deny (JSON decision on stdout, or a non-zero fallback rc)…
	# `{ ...; } || return 1` so this middle check aborts — bats has no set -e.
	{ printf '%s' "$output" | grep -q '"permissionDecision":"deny"' || [ "$status" -eq 2 ]; } || return 1
	# …and it states the async carve-out verbatim.
	printf '%s' "$output" | grep -qF 'Agent/Skill calls ARE permitted while pending' || return 1
}

@test "Edit and Write are still DENIED while a log is pending" {
	_pend
	run _verdict '{"tool_name":"Edit","tool_input":{"file_path":"x"}}'
	[ "$output" = deny ] || return 1
	run _verdict '{"tool_name":"Write","tool_input":{"file_path":"x","content":"c"}}'
	[ "$output" = deny ] || return 1
}

# --- security: the review-log.sh escape ------------------------------------

@test "env-prefixed review-log.sh is DENIED (BASH_ENV arbitrary code exec)" {
	# review-log.sh has a #!/bin/bash shebang, so a non-interactive bash sources
	# $BASH_ENV before the script body — the prefix is arbitrary code execution.
	_pend
	run _verdict '{"tool_name":"Bash","tool_input":{"command":"BASH_ENV=/tmp/evil.sh .claude/hooks/review-log.sh phase1 1 x 0 ok"}}'
	[ "$output" = deny ] || return 1
	run _verdict '{"tool_name":"Bash","tool_input":{"command":"LD_PRELOAD=/tmp/e.so .claude/hooks/review-log.sh phase1 1 x 0 ok"}}'
	[ "$output" = deny ] || return 1
}

@test "a compound command ending in review-log.sh is DENIED (total bypass)" {
	# The old pattern could begin matching after ANY separator and had no end
	# bound, so the whole compound was admitted.
	_pend
	run _verdict '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x; .claude/hooks/review-log.sh"}}'
	[ "$output" = deny ] || return 1
	run _verdict '{"tool_name":"Bash","tool_input":{"command":".claude/hooks/review-log.sh phase1 1 x 0 ok && rm -rf /tmp/x"}}'
	[ "$output" = deny ] || return 1
}

@test "harmless discard redirects are ALLOWED — both gates agree (shared screen)" {
	# The inline copy in this gate lacked the guard's discard-redirect stripping,
	# so `review-log.sh … 2>/dev/null` was allowed by one gate and denied by the
	# other. Both now source _lib/cmd-launder-screen.sh.
	_pend
	run _verdict "$(jq -nc '{tool_name:"Bash",tool_input:{command:".claude/hooks/review-log.sh phase1 1 x 0 ok 2>/dev/null"}}')"
	[ "$output" = allow ] || return 1
	run _verdict "$(jq -nc '{tool_name:"Bash",tool_input:{command:".claude/hooks/review-log.sh phase1 1 x 0 ok 2>&1"}}')"
	[ "$output" = allow ] || return 1
}

@test "a REAL file redirect is still DENIED (stripping is discard-only)" {
	_pend
	run _verdict "$(jq -nc '{tool_name:"Bash",tool_input:{command:".claude/hooks/review-log.sh phase1 1 x 0 ok > /tmp/out"}}')"
	[ "$output" = deny ] || return 1
}

@test "legitimate review-log.sh forms are still ALLOWED (the way out)" {
	_pend
	for c in ".claude/hooks/review-log.sh phase1 1 code-reviewer 3 ok" \
		"./.claude/hooks/review-log.sh phase1 1 code-reviewer 3 ok" \
		"hooks/review-log.sh phase1 1 code-reviewer 3 ok"; do
		run _verdict "$(jq -nc --arg c "$c" '{tool_name:"Bash",tool_input:{command:$c}}')"
		[ "$output" = allow ] || {
			echo "expected allow for: $c (got $output)"
			return 1
		}
	done
}
