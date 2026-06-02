#!/usr/bin/env bats
# covers: _lib/ship-cycle-directives.sh
# shellcheck disable=SC2030,SC2031,SC2317  # bats @test subshells: per-test SHIP_PR_IN_RESUME mods + indirectly-invoked mock fns are intentional
#
# v0.32.12 (#283): the ship-pr-cycle next-step directive emitter. Locks:
# _emit_stage_directive prints the directive to stdout; CALLS hook_ack_append
# (the un-skippable, Read-to-clear ack-pending) when NOT in a resume auto-walk;
# SUPPRESSES that call under SHIP_PR_IN_RESUME=1 (stdout still prints); and
# no-ops safely on an unknown label (never aborts the orchestrator).
#
# The hook-ack primitives are STUBBED so this tests THIS lib's behavior in
# isolation — no real .claude sentinel pollution (hook-ack.sh has its own tests,
# and it resolves the sentinel via git-toplevel, not REPO_ROOT).

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/ship-cycle-directives.sh"
	[ -f "$LIB" ]
	TEST_TMP=$(mktemp -d -t shipdir.XXXXXX) || return 1
	CALLS="$TEST_TMP/append-calls.log"
	: >"$CALLS"
	# Stubs: command -v finds these, so _emit_stage_directive calls them.
	# shellcheck disable=SC2317,SC2329 # invoked indirectly by the sourced lib (command -v + call)
	hook_ack_diagnostic_write() { printf '%s/diag-%s.txt\n' "$TEST_TMP" "${2:-x}"; }
	# shellcheck disable=SC2317,SC2329 # invoked indirectly by the sourced lib
	hook_ack_append() { printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" >>"$CALLS"; }
	# shellcheck source=../../../_lib/ship-cycle-directives.sh
	. "$LIB"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */shipdir.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "two-step-phase1 directive prints to stdout (status 0)" {
	run _emit_stage_directive two-step-phase1
	[ "$status" -eq 0 ]
	[[ $output == *"do NOT skip"* ]]
	[[ $output == *"AGAIN"* ]]
	[[ $output == *"two-step"* ]]
	# F3 (#253 r1 pr-test-analyzer): lock the load-bearing trap instruction, not
	# just the word "two-step" — a body rewrite that drops the warning must fail.
	[[ $output == *"Do NOT fire phase1 agents"* ]]
	[[ $output == *"2nd next"* ]]
}

@test "calls hook_ack_append with the label (not in resume)" {
	run _emit_stage_directive two-step-phase1
	[ "$status" -eq 0 ]
	grep -q 'ship-pr-cycle-next' "$CALLS"
	grep -q 'two-step-phase1' "$CALLS"
}

@test "SHIP_PR_IN_RESUME=1 (exported) suppresses the ack-pending (stdout still prints)" {
	export SHIP_PR_IN_RESUME=1
	run _emit_stage_directive two-step-phase1
	[ "$status" -eq 0 ]
	[[ $output == *"do NOT skip"* ]] # stdout still emitted during resume
	[ ! -s "$CALLS" ]                # hook_ack_append NOT called
}

@test "SHIP_PR_IN_RESUME via DYNAMIC SCOPE (local in caller) suppresses ack" {
	# F7 (#253 r1): the real cmd_resume→cmd_next path sets `local
	# SHIP_PR_IN_RESUME=1` and relies on bash dynamic scope — NOT an export.
	# Prove a `local` in a caller is visible to _emit_stage_directive.
	_outer() {
		local SHIP_PR_IN_RESUME=1
		_emit_stage_directive two-step-phase1
	}
	run _outer
	[ "$status" -eq 0 ]
	[[ $output == *"do NOT skip"* ]] # stdout still prints
	[ ! -s "$CALLS" ]                # append suppressed via dynamic scope
}

@test "unknown label → warns, status 0, no ack-pending" {
	run _emit_stage_directive bogus-label
	[ "$status" -eq 0 ]
	[[ $output == *"unknown label"* ]]
	[ ! -s "$CALLS" ]
}

@test "no-arg (empty label) → warns, status 0, no ack-pending" {
	# F4 (#253 r1): the `${1:-}` default routes a no-arg call to the `*)` arm.
	run _emit_stage_directive
	[ "$status" -eq 0 ]
	[[ $output == *"unknown label"* ]]
	[ ! -s "$CALLS" ]
}

@test "push-to-pr directive prints + appends (server-side CR-in-CI reminder)" {
	run _emit_stage_directive push-to-pr
	[ "$status" -eq 0 ]
	[[ $output == *"SERVER-SIDE"* ]]
	[[ $output == *"@coderabbitai review"* ]] # the NEVER reminder
	grep -q 'push-to-pr' "$CALLS"
}

@test "merge-conflict directive prints + appends (cr-resolve-conflict skill)" {
	run _emit_stage_directive merge-conflict
	[ "$status" -eq 0 ]
	[[ $output == *"cr-resolve-conflict"* ]]
	grep -q 'merge-conflict' "$CALLS"
}

@test "merge-gate directive prints + appends (APPROVE=1 only + merge!=deploy)" {
	run _emit_stage_directive merge-gate
	[ "$status" -eq 0 ]
	[[ $output == *"APPROVE=1"* ]]
	[[ $output == *"merge != deploy"* ]]
	grep -q 'merge-gate' "$CALLS"
}

@test "pr-create-preread prints directive naming the PR template" {
	# #223 CREATION-TIME PREREAD GATE: the directive must name the template
	# the operator has to Read before drafting the PR body.
	run _emit_stage_directive pr-create-preread
	[ "$status" -eq 0 ]
	[[ $output == *"do NOT skip"* ]]
	[[ $output == *"PREREAD GATE"* ]]
	[[ $output == *".github/pull_request_template.md"* ]]
	# Load-bearing: names the creation-skill SSOT too.
	[[ $output == *"github-pr-creation"* ]]
}

@test "pr-create-preread writes ack-pending KEYED at the PR-template path" {
	# The enforced preread: hook_ack_append's file_path (3rd field) MUST be
	# the PR template, so a PostToolUse Read of that file clears the block.
	# (The stub logs "<hook>\t<label>\t<file_path>" to $CALLS.)
	run _emit_stage_directive pr-create-preread
	[ "$status" -eq 0 ]
	grep -q 'ship-pr-cycle-preread' "$CALLS"
	grep -q 'pr-create-preread' "$CALLS"
	# The 3rd tab-field (file_path) is the template — assert it precisely so a
	# regression that keys the ack at a diagnostic file (the advisory pattern)
	# instead of the template fails this test.
	grep -qE $'\t''\.github/pull_request_template\.md$' "$CALLS"
}

@test "pr-create-preread under SHIP_PR_IN_RESUME=1 → stdout only, no ack" {
	# Resume auto-walk must NOT register a (soon-stale) ack-pending; the
	# directive still prints for the resume log.
	export SHIP_PR_IN_RESUME=1
	run _emit_stage_directive pr-create-preread
	[ "$status" -eq 0 ]
	[[ $output == *"PREREAD GATE"* ]]
	[ ! -s "$CALLS" ]
}

@test "pr-create-preread does NOT use the diagnostic-file ack path" {
	# Regression guard: the preread arm returns BEFORE the advisory
	# diagnostic-file branch. If hook_ack_diagnostic_write were reached its
	# stub path would appear in $CALLS as the file_path. Make the diagnostic
	# writer FAIL — a preread arm that wrongly fell through would degrade to
	# no-append, but a correct preread arm still appends the TEMPLATE path.
	hook_ack_diagnostic_write() { return 1; }
	run _emit_stage_directive pr-create-preread
	[ "$status" -eq 0 ]
	grep -qE $'\t''\.github/pull_request_template\.md$' "$CALLS"
}

@test "phase2-preread prints directive + keys ack at ship-pr-cycle SKILL.md" {
	run _emit_stage_directive phase2-preread
	[ "$status" -eq 0 ]
	[[ $output == *"PREREAD GATE"* ]]
	[[ $output == *"phase2"* ]]
	[[ $output == *"skills/ship-pr-cycle/SKILL.md"* ]]
	grep -q 'ship-pr-cycle-preread' "$CALLS"
	grep -q 'phase2-preread' "$CALLS"
	grep -qE $'\t''skills/ship-pr-cycle/SKILL\.md$' "$CALLS"
}

@test "phase2-preread under SHIP_PR_IN_RESUME=1 → stdout only, no ack" {
	export SHIP_PR_IN_RESUME=1
	run _emit_stage_directive phase2-preread
	[ "$status" -eq 0 ]
	[[ $output == *"PREREAD GATE"* ]]
	[ ! -s "$CALLS" ]
}

@test "preread arm: hook_ack_append absent → stdout-only degradation (no crash)" {
	# Mirrors the advisory-arm degradation test, but for the preread path:
	# _emit_preread_ack guards on `command -v hook_ack_append`.
	unset -f hook_ack_append
	run _emit_stage_directive pr-create-preread
	[ "$status" -eq 0 ]
	[[ $output == *"PREREAD GATE"* ]] # directive still printed
	[ ! -s "$CALLS" ]                 # no append, no crash
}

@test "hook-ack primitives absent → stdout-only degradation (status 0, no append)" {
	# F5 (#253 r1): the `command -v hook_ack_diagnostic_write || return 0` guard
	# is the advisory-only fallback when hook-ack.sh was NOT sourced. Unset the
	# stubs to exercise it (setup always defines them otherwise).
	unset -f hook_ack_diagnostic_write hook_ack_append
	run _emit_stage_directive push-to-pr
	[ "$status" -eq 0 ]
	[[ $output == *"SERVER-SIDE"* ]] # directive still printed
	[ ! -s "$CALLS" ]                # no append, no crash
}

@test "diagnostic-write failure → stdout-only degradation (status 0, no append)" {
	# F6 (#253 r1): when hook_ack_diagnostic_write returns non-zero, the
	# `$(...) || return 0` arm degrades to advisory — append NOT reached.
	hook_ack_diagnostic_write() { return 1; }
	run _emit_stage_directive push-to-pr
	[ "$status" -eq 0 ]
	[[ $output == *"SERVER-SIDE"* ]]
	[ ! -s "$CALLS" ]
}
