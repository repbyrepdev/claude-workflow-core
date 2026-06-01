#!/bin/bash
set -u
# auto-register: false
# v0.32.12 (#283): ship-pr-cycle next-step directive emitter — the SSOT for the
# per-stage/edge directive bodies.
#
# ship-pr-cycle.sh sources this + _lib/hook-ack.sh, then calls
# `_emit_stage_directive <label>` at each stage/edge transition. The directive:
#   - ALWAYS prints to stdout (advisory, immediate),
#   - registers an UN-SKIPPABLE hook-ack pending entry (the operator must Read
#     the diagnostic file to ack before the next Bash/Edit/Write) — UNLESS
#     SHIP_PR_IN_RESUME=1, in which case only the stdout print happens.
#
# Why suppress under SHIP_PR_IN_RESUME: cmd_resume auto-walks intermediate
# stages in a loop; a pending entry for each would be stale by the time control
# returns to the operator. Only the stage `resume` STOPS at needs a directive,
# and that stage's own path (e.g. the phase1 agent directive) handles it.
#
# Read-to-clear (hook-ack-clear.sh on PostToolUse Read) ⇒ NO deadlock, unlike a
# stage marker that only clears on advance. Reuses the existing hook-ack infra —
# no parallel system (#283).
#
# Bodies live here (one `case` arm each) so a directive is defined ONCE even
# when emitted from multiple call sites. Add an arm per new stage/edge as #283
# expands (round-complete, push, merge-gate, merge-conflict, skill-usage,
# template/SSOT prereads, efficiency-grouping, ...).

_emit_stage_directive() {
	local label=${1:-} body
	case "$label" in
	two-step-phase1)
		body="Run 'scripts/ship-pr-cycle.sh next' AGAIN now. Advancing INTO phase1 and EMITTING the phase1 agent directive are SEPARATE next calls (the two-step trap). Do NOT fire phase1 agents yet — the 2nd next creates the directive + sentinel; agents fired before it are rejected ('outside active directive'). After that 2nd next: fire 5 READ-ONLY pr-review-toolkit agents + semgrep (a SINGLE bare command, no pipe) + security-review (Agent subagent_type=general-purpose, NOT Skill), then review-log.sh each."
		;;
	*)
		echo "_emit_stage_directive: unknown label '$label' — no directive emitted" >&2
		return 0
		;;
	esac
	printf '\n  ⚠ NEXT — do NOT skip this step:\n%s\n' "$body"
	# Auto-walk (cmd_resume) suppresses the ack-pending; stdout print above still
	# fires so the resume log carries the directive for context.
	if [ "${SHIP_PR_IN_RESUME:-0}" = "1" ]; then
		return 0
	fi
	# Best-effort ack-enforcement: any failure degrades to the stdout print
	# (advisory) — never aborts the orchestrator, never deadlocks.
	command -v hook_ack_diagnostic_write >/dev/null 2>&1 || return 0
	local diag
	diag=$(hook_ack_diagnostic_write "ship-pr-cycle-next" "$label" "$body" 2>/dev/null) || return 0
	[ -n "$diag" ] || return 0
	hook_ack_append "ship-pr-cycle-next" "$label" "$diag" 2>/dev/null || true
}
