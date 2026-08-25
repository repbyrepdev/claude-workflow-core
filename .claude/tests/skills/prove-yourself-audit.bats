#!/usr/bin/env bats
# covers: skills/prove-yourself-audit/run.sh
# shellcheck disable=SC2030,SC2031  # each bats test runs in its own subshell — env exports (PROVE_RETEST_TIMEOUT) are deliberately per-test
#
# #2562: record-fix re-executes its retest evidence. These tests pin the
# three mechanical guarantees: (1) the recorded command is RUN and its
# actual rc must match the claimed --retest-rc (EVIDENCE MISMATCH refusal
# otherwise); (2) the written record carries the retest_verified stamp and
# audit refuses fix records without it (hand-forged / pre-#2562 records
# cannot pass the commit gate); (3) cited cycle-critical files demand the
# real entry point inside the retest command text.
#
# The suite runs the REAL skill inside a throwaway git repo so REPO_ROOT
# (and therefore STATE_DIR + the tracked audit log) resolve to the sandbox,
# never to this repo's live session state.

setup() {
	SKILL="${BATS_TEST_DIRNAME}/../../../skills/prove-yourself-audit/run.sh"
	[ -f "$SKILL" ]
	TEST_TMP=$(mktemp -d -t prove-yourself-audit.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
		git commit -q --allow-empty -m seed
		# A cycle-critical file for the entry-point rule tests. Exits 0 so
		# it can double as the (truthful) retest command itself.
		mkdir -p hooks
		printf '#!/bin/bash\nexit 0\n' >hooks/x.sh
		chmod +x hooks/x.sh
		# A non-critical citable file.
		echo "doc" >README.md
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Shorthand: record a fix with overridable retest cmd/rc + cited files.
_record_fix() {
	local cmd="$1" rc="$2" cited="${3:-}"
	run "$SKILL" record-fix \
		--finding-id t1 \
		--finding-text "sample finding" \
		--fix-summary "sample fix" \
		--retest-cmd "$cmd" \
		--retest-rc "$rc" \
		--source phase1 --confidence 5 \
		${cited:+--cited-files "$cited"}
}

@test "truthful rc-0 evidence records and stamps retest_verified" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
	local f
	f=$(ls .claude/.session-state/prove-yourself/*.json)
	[ "$(jq -r '.decision_data.retest_verified' "$f")" = "true" ]
	[ "$(jq -r '.decision_data.retest_actual_rc' "$f")" = "0" ]
}

@test "false rc claim is refused as EVIDENCE MISMATCH, no record written" {
	cd "$TEST_TMP" || return 1
	_record_fix "false" 0
	[ "$status" -eq 1 ]
	[[ $output == *"EVIDENCE MISMATCH"* ]]
	[[ $output == *"rc=1"* ]]
	# No state file may exist — a refused record must leave nothing behind.
	local n
	n=$(find .claude/.session-state/prove-yourself -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
	[ "$n" = "0" ]
}

@test "claimed NONZERO rc is legitimate evidence when it matches" {
	cd "$TEST_TMP" || return 1
	_record_fix "bash -c 'exit 3'" 3
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "retest timeout refuses with the PROVE_RETEST_TIMEOUT hint" {
	command -v timeout >/dev/null 2>&1 || skip "no timeout binary"
	cd "$TEST_TMP" || return 1
	export PROVE_RETEST_TIMEOUT=1
	_record_fix "sleep 5" 0
	unset PROVE_RETEST_TIMEOUT
	[ "$status" -eq 1 ]
	[[ $output == *"timed out"* ]]
	[[ $output == *"PROVE_RETEST_TIMEOUT"* ]]
}

@test "cycle-critical cited file demands its path inside the retest command" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0 "hooks/x.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]]
	[[ $output == *"hooks/x.sh"* ]]
}

@test "cycle-critical citation passes when the command invokes the entry point" {
	cd "$TEST_TMP" || return 1
	_record_fix "bash hooks/x.sh" 0 "hooks/x.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "non-critical cited file is exempt from the entry-point rule" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0 "README.md"
	[ "$status" -eq 0 ]
}

@test "audit refuses a fix record lacking the retest_verified stamp" {
	cd "$TEST_TMP" || return 1
	mkdir -p .claude/.session-state/prove-yourself
	jq -n '{finding_id: "forged", kind: "fix", finding_text: "x", ts: "2020-01-01T00:00:00Z",
	        covers_count: 1, confidence: 5, source: "phase1", cited_files: [],
	        decision_data: {fix_summary: "s", retest_cmd: "true", retest_rc: 0}}' \
		>.claude/.session-state/prove-yourself/forged.json
	run "$SKILL" audit
	[ "$status" -eq 1 ]
	[[ $output == *"retest_verified"* ]]
}

@test "audit passes a record written by the current recorder" {
	cd "$TEST_TMP" || return 1
	_record_fix "true" 0
	[ "$status" -eq 0 ]
	run "$SKILL" audit
	[ "$status" -eq 0 ]
	[[ $output == *"Fixes recorded:      1"* ]]
}

@test "retest output tail is captured into the record" {
	cd "$TEST_TMP" || return 1
	_record_fix "echo tail-marker-xyz" 0
	[ "$status" -eq 0 ]
	local f
	f=$(ls .claude/.session-state/prove-yourself/*.json)
	[[ $(jq -r '.decision_data.retest_output_tail' "$f") == *"tail-marker-xyz"* ]]
}

@test "no-timeout-binary fallback still verifies match AND mismatch (p1r1)" {
	# The branch that actually runs on stock macOS had zero coverage: hide
	# `timeout` via a PATH that lacks it (jq/git/bash symlinked in).
	cd "$TEST_TMP" || return 1
	mkdir -p bin
	for t in jq git bash grep sed tail date mktemp shasum ls; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "bin/$t"
	done
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" bash -c "cd '$TEST_TMP' && ! command -v timeout >/dev/null && '$SKILL' record-fix --finding-id tf1 --finding-text x --fix-summary y --retest-cmd true --retest-rc 0 --source phase1 --confidence 5"
	if [[ $output == *"timeout"* ]] && [ "$status" -ne 0 ] && [[ $output != *"Recorded fix"* ]]; then
		skip "could not hide timeout from PATH on this host"
	fi
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" bash -c "cd '$TEST_TMP' && '$SKILL' record-fix --finding-id tf2 --finding-text x2 --fix-summary y --retest-cmd false --retest-rc 0 --source phase1 --confidence 5"
	[ "$status" -eq 1 ]
	[[ $output == *"EVIDENCE MISMATCH"* ]]
}

@test "retest runs anchored at REPO_ROOT even when invoked from a subdir (p1r1)" {
	cd "$TEST_TMP" || return 1
	mkdir -p sub/deeper
	cd sub/deeper || return 1
	run "$SKILL" record-fix --finding-id cwd1 --finding-text x --fix-summary y \
		--retest-cmd "bash hooks/x.sh" --retest-rc 0 --cited-files "hooks/x.sh" \
		--source phase1 --confidence 5
	[ "$status" -eq 0 ]
	[[ $output == *"Recorded fix"* ]]
}

@test "a .claude/-prefixed citation still triggers the cycle-critical rule (p1r1)" {
	cd "$TEST_TMP" || return 1
	mkdir -p .claude/hooks
	printf '#!/bin/bash\nexit 0\n' >.claude/hooks/m.sh
	chmod +x .claude/hooks/m.sh
	run "$SKILL" record-fix --finding-id mir1 --finding-text x --fix-summary y \
		--retest-cmd "true" --retest-rc 0 --cited-files ".claude/hooks/m.sh" \
		--source phase1 --confidence 5
	[ "$status" -eq 2 ]
	[[ $output == *"cycle-critical"* ]]
	# And the SSOT-relative spelling of the entry point satisfies it.
	run "$SKILL" record-fix --finding-id mir2 --finding-text x2 --fix-summary y \
		--retest-cmd "bash .claude/hooks/m.sh" --retest-rc 0 --cited-files ".claude/hooks/m.sh" \
		--source phase1 --confidence 5
	[ "$status" -eq 0 ]
}

@test "non-integer PROVE_RETEST_TIMEOUT warns and falls back to 120 (p1r1)" {
	cd "$TEST_TMP" || return 1
	export PROVE_RETEST_TIMEOUT=abc
	_record_fix "true" 0
	unset PROVE_RETEST_TIMEOUT
	[ "$status" -eq 0 ]
	[[ $output == *"not a positive integer"* ]]
	[[ $output == *"Recorded fix"* ]]
}
