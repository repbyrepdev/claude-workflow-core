#!/bin/bash
set -euo pipefail
# event: UserPromptSubmit
# UserPromptSubmit hook — detect brainstorm-mode trigger words in the user's
# message and inject a system-reminder so Claude stays in discussion mode
# (structured Problem/Options/Tradeoffs/Recommendation output) instead of
# executing.
#
# Per user directive: "brainstorm" means discuss, don't start. Background
# tasks (Monitor, run_in_background Bash) keep running — the hook does NOT
# stop anything. It just reframes Claude's next response.
#
# Part of v3.22 brainstorm infrastructure.

_HOOK_START=$(date +%s)
# shellcheck source=/dev/null
source "$(dirname "$0")/_lib.sh" 2>/dev/null || true
trap 'hook_log_run "$0" "$?" "$_HOOK_START" 2>/dev/null || true' EXIT

input=$(cat 2>/dev/null || true)
msg=$(echo "$input" | jq -r '.prompt // .user_prompt // .message // empty' 2>/dev/null || true)
[ -z "$msg" ] && exit 0

# Trigger words (case-insensitive). Anchored so "brainstormed" / "brainstormer"
# don't match, but "/brainstorm", "brainstorm:", "brainstorm X" do.
# Keep this list tight — over-matching creates friction.
if echo "$msg" | grep -qiE '(^|\s)(/?brainstorm([:[:space:]]|$))'; then
	mode="explicit"
elif echo "$msg" | grep -qiE "(^|\s)(let'?s (brainstorm|discuss|think about|explore))"; then
	mode="natural"
elif echo "$msg" | grep -qiE "^(what do you think about|should we|how should we approach|what are our options)"; then
	mode="exploratory"
else
	exit 0
fi

# Output to stdout is injected as a system-reminder into Claude's context.
# Keep it short — this fires on every matching prompt.
cat <<EOF
<system-reminder>
Brainstorm mode detected (trigger: $mode). The user wants discussion, not
execution. Follow the \`brainstorm\` skill:

- Output structured Problem / Options / Tradeoffs / Recommendation
- Do NOT start executing — no branches, commits, pushes, writes, destructive ops
- Read-only context-gathering (gh issue view, git log, grep, cat) is fine
- Background tasks (Monitor, run_in_background) keep running — do NOT pause them
- End with "ready when you say go" line and offer to record as a brainstorm issue
- Silence is NOT approval — only explicit "go" / "do it" / pick-an-option exits brainstorm mode
</system-reminder>
EOF
