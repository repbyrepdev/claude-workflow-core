#!/bin/bash
set -euo pipefail
# event: PostToolUse
# v4.15.G #495 — PostToolUse hook: Phase 1 agent return → log-now reminder.

# v4.15.R: unconditional debug log of hook firing — `|| true` keeps strict
# mode happy if /tmp is unwriteable. Absolute path bypasses any CWD confusion.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) phase1-post-agent-nudge FIRED pid=$$" >>/tmp/claude-phase1-hooks.log 2>/dev/null || true

_HOOK_START=$(date +%s)
# Source the shared lib relative to the hook's own location (not caller CWD).
# `${BASH_SOURCE[0]}` is the hook script path regardless of how it's invoked.
# Fail loud (stderr) on missing lib instead of silently disabling hook_log_run
# — silent failure would turn the EXIT trap into a no-op and break telemetry
# without any visible signal. Match the same fix in phase1-post-commit-resume.sh.
_LIB_DIR=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=/dev/null
if ! source "$_LIB_DIR/_lib.sh"; then
	echo "phase1-post-agent-nudge: failed to source $_LIB_DIR/_lib.sh" >&2
	# Fail closed (exit 1) — silent disable of hook_log_run breaks telemetry
	# AND defeats the stall-prevention purpose of this hook. Match the
	# documented "fail loudly" intent in the comment block above.
	exit 1
fi
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

# WHY: v4.15.F closed the "after log-write" stall but the stall moved
# upstream: agents return → Claude doesn't call review-log.sh →
# v4.15.F trigger never fires. Observed 2026-04-20 the very next
# dogfood round after v4.15.F shipped — same stall, different cause.
#
# HOW: on every Agent/Skill/MCP tool completion, check if the tool
# is a Phase 1 agent (pr-review-toolkit:*, /security-review skill,
# semgrep_scan MCP). If yes, emit a stderr directive with the exact
# review-log.sh command + explicit "do NOT stall" wording. This is
# the upstream trigger that kicks the v4.15.F chain into motion.
#
# The hook cannot know the findings count (that's in the agent's
# textual output). It prints <FINDINGS_COUNT> as a placeholder +
# the explicit log-command template so Claude fills it in.

# v4.15.K: fail-closed on stdin/jq parse. Silent failure here means the
# nudge never fires → Claude stalls (the bug this hook exists to fix).
PAYLOAD=$(cat) || {
	echo "phase1-post-agent-nudge: stdin read failed" >&2
	exit 0
}
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""') || {
	echo "phase1-post-agent-nudge: payload unparseable — skipping" >&2
	exit 0
}
# Skip gracefully on jq errors (NOT fail-closed — exit 0 lets the parent
# tool call proceed, since this hook is advisory). Prior `|| true` form
# coerced real jq failures into empty SUBAGENT/SKILL, making the script
# exit at line 75 as if this wasn't a Phase 1 agent — defeating the
# stall-prevention purpose. Surface the failure to stderr before exiting.
if ! SUBAGENT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.subagent_type // ""' 2>/dev/null); then
	echo "phase1-post-agent-nudge: jq failed extracting tool_input.subagent_type" >&2
	exit 0
fi
if ! SKILL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.skill // ""' 2>/dev/null); then
	echo "phase1-post-agent-nudge: jq failed extracting tool_input.skill" >&2
	exit 0
fi

# Map the completed tool to the canonical agent name used in
# review-log.sh + list-phase1-agents.sh. If it's not a Phase 1
# agent/skill, exit 0 silently (most PostToolUse invocations).
AGENT_NAME=""
case "$TOOL" in
Agent)
	case "$SUBAGENT" in
	pr-review-toolkit:code-reviewer) AGENT_NAME="code-reviewer" ;;
	pr-review-toolkit:silent-failure-hunter) AGENT_NAME="silent-failure-hunter" ;;
	pr-review-toolkit:comment-analyzer) AGENT_NAME="comment-analyzer" ;;
	pr-review-toolkit:pr-test-analyzer) AGENT_NAME="pr-test-analyzer" ;;
	pr-review-toolkit:code-simplifier) AGENT_NAME="code-simplifier" ;;
	# type-design-analyzer intentionally omitted: SSOT (review-config.yml)
	# skips it for shell/YAML-only diffs; mapping it here would emit a
	# log-me directive for an agent review-log.sh will reject.
	esac
	;;
Skill)
	case "$SKILL" in
	security-review) AGENT_NAME="security-review" ;;
	esac
	;;
mcp__plugin_semgrep_semgrep__semgrep_scan)
	AGENT_NAME="semgrep"
	;;
esac

[ -z "$AGENT_NAME" ] && exit 0

# Figure out the likely next round number from the review-log for
# current HEAD. If log missing or empty, round=1. Else max(round)+1
# if the current round already has this agent logged (round moved
# forward), else max(round).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
cd "$REPO_ROOT" || exit 0
SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
[ -z "$SHA" ] && exit 0
LOG="$REPO_ROOT/.claude/review-log/${SHA}.jsonl"

CURRENT_ROUND=1
if [ -f "$LOG" ]; then
	# `|| true` on each jq pipe: a corrupted .jsonl line (partial write from a
	# concurrent invocation) makes jq exit 2; under set -euo pipefail that aborts
	# the hook — the same hook that exists EXPLICITLY to prevent Phase 1 stalls.
	LAST_ROUND=$(jq -r 'select(.phase==1 and .round!=null) | .round' "$LOG" 2>/dev/null | sort -un | tail -1 || true)
	if [ -n "$LAST_ROUND" ]; then
		ALREADY=$(jq -r --arg r "$LAST_ROUND" --arg a "$AGENT_NAME" \
			'select(.phase==1 and (.round|tostring)==$r and .agent==$a)' \
			"$LOG" 2>/dev/null || true)
		if [ -n "$ALREADY" ]; then
			CURRENT_ROUND=$((LAST_ROUND + 1))
		else
			CURRENT_ROUND="$LAST_ROUND"
		fi
	fi
fi

# v4.28-W4 (#721) + r1 fixes: write a per-agent pending file that
# phase1-log-pending-gate.sh reads in its PreToolUse check. The next
# Bash/Agent/Skill/Edit/Write tool call REFUSES until review-log.sh
# fires for this agent (which deletes the pending file). This makes
# the chain MECHANICAL — prior advisory-only directive was missed
# 5+ times mid PR #708.
#
# r1 CR #1 fix: filename schema is `${AGENT_NAME}-${SHA}.txt` — no
# round in filename. Round-drift was a real bug: nudge inferred round
# heuristically from log; operator/launcher passed an explicit round;
# delete missed because filenames diverged → orphan blocked everything.
# One agent has at most one outstanding pending entry per SHA at a
# time, so dropping round simplifies + fixes the schema.
#
# r1 SFH #3+#4 fix: capture mkdir + write stderr + emit loud
# diagnostic so silent failure doesn't degrade the mechanism to
# advisory-only (the regression mode this commit explicitly fixes).
PENDING_DIR="$REPO_ROOT/.claude/.session-state/phase1-log-pending"
PENDING_OK=1
mkdir_err=$(mktemp)
if ! mkdir -p "$PENDING_DIR" 2>"$mkdir_err"; then
	echo "phase1-post-agent-nudge: mkdir $PENDING_DIR failed — gate will NOT fire, mechanism degraded to advisory-only:" >&2
	cat "$mkdir_err" >&2
	PENDING_OK=0
fi
rm -f "$mkdir_err"
PENDING_FILE="$PENDING_DIR/${AGENT_NAME}-${SHA}.txt"
write_err=$(mktemp)
if [ "$PENDING_OK" -eq 1 ] && ! {
	echo "Phase 1 agent returned: $AGENT_NAME (round $CURRENT_ROUND, sha $SHA)"
	echo "Logged at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	echo "Run to clear this pending state:"
	echo "  .claude/hooks/review-log.sh phase1 $CURRENT_ROUND $AGENT_NAME <FINDINGS_COUNT> ok"
} >"$PENDING_FILE" 2>"$write_err"; then
	echo "phase1-post-agent-nudge: write to $PENDING_FILE failed — gate will NOT fire for $AGENT_NAME:" >&2
	cat "$write_err" >&2
	PENDING_OK=0
fi
rm -f "$write_err"

# v4.15.M: use JSON stdout `hookSpecificOutput.additionalContext` —
# the ACTUAL working mechanism per Claude Code hook spec. Exit 2 +
# stderr (v4.15.J attempt) did NOT inject context in live testing on
# 2026-04-20 — 5 Agent calls fired the hook, Claude saw 0 directives.
# Kept alongside the v4.28-W4 pending-file mechanism above as a
# belt-and-suspenders nudge.
# CR Phase 2 minor: the v4.28-W4 line claiming "next tool call WILL BE
# REFUSED" must reflect actual gate state — if mkdir/write failed,
# pending file doesn't exist, gate WON'T fire, and the message would
# lie to the operator. Branch on $PENDING_OK so the message tracks reality.
if [ "$PENDING_OK" -eq 1 ]; then
	GATE_LINE="v4.28-W4 (#721): the next tool call WILL BE REFUSED until you run review-log.sh."
else
	GATE_LINE="v4.28-W4 (#721): pending-file write failed — gate will NOT fire for this agent (advisory-only mode). See stderr above."
fi
jq -n --arg ctx "=== Phase 1 agent returned: $AGENT_NAME (round $CURRENT_ROUND) ===
IMMEDIATE NEXT ACTION (do NOT summarize / stall / wait for user):
  .claude/hooks/review-log.sh phase1 $CURRENT_ROUND $AGENT_NAME <FINDINGS_COUNT> ok
Replace <FINDINGS_COUNT> with the number of actionable findings from the agent's output (0 if clean). When the last expected agent of round $CURRENT_ROUND is logged, review-log.sh emits the next-round directive (v4.15.F). Follow the chain.
$GATE_LINE" \
	'{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
exit 0
