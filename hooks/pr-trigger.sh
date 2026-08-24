#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# enforcement: inform — advisory directive on PR-open
# Hook script for PostToolUse - triggers PR dashboard after gh pr create

# Silently exit if jq is not available
command -v jq >/dev/null 2>&1 || {
	echo "pr-trigger: jq not found — no directive emitted (advisory hook, exiting 0)" >&2
	exit 0
}

# Read JSON input from stdin
INPUT=$(cat)

# Extract the Bash command and exit code from tool input/response
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
	echo "pr-trigger: command parse failed — no directive emitted" >&2
	exit 0
}
EXIT_CODE=$(printf '%s' "$INPUT" | jq -r '.tool_response.exitCode // 1' 2>/dev/null) || {
	echo "pr-trigger: exitCode parse failed — assuming failure, no directive" >&2
	exit 0
}

# v4.17.O: emit JSON hookSpecificOutput.additionalContext directing
# Claude to /pr after a successful `gh pr create`. Hook is advisory and
# always exits 0 — even on parse errors — because blocking would abort
# the user's gh pr create tool-result; we just lose the /pr nudge. All
# failure paths log to stderr. jq output is captured to a variable
# before printing so a jq failure can't leak partial stdout (which
# Claude might try to parse as malformed JSON hookSpecificOutput).
# v4.17.Y: anchor the match to command-start or shell-separator to avoid
# firing on quoted substrings like `echo "Run gh pr create"`.
# v4.23-Q (#563): also allow env-var prefixes at start-of-command so that
# wrapper invocations like `SKILL_WRAPPER=1 gh pr create ...` match. Prior
# anchor required gh at ^ or after [;&|] — silently missed every PR
# opened via `.claude/skills/github-pr-creation/run.sh` which prefixes
# SKILL_WRAPPER=1. Result: /pr dashboard never auto-nudged for wrapper-
# created PRs, watch-until-done.sh never fired, session-long manual
# polling was the fallback.
if printf '%s' "$COMMAND" | grep -qE '((^|[;&|][[:space:]]*)([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*)gh[[:space:]]+pr[[:space:]]+create' && [[ $EXIT_CODE == "0" ]]; then
	# v4.17.Z: keep stderr OUT of STDOUT — a success case with a benign jq
	# warning would otherwise pollute the PR# grep input. Accept the
	# tradeoff of less-detailed error log for deterministic STDOUT.
	if ! STDOUT=$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // ""' 2>/dev/null); then
		echo "pr-trigger: could not parse tool_response — no directive emitted" >&2
		exit 0
	fi
	# `|| true`: under set -euo pipefail, grep-no-match propagates through
	# pipefail and aborts the assignment before the no-match else-branch
	# at line ~76 (which exists to emit a generic "PR was created" directive).
	PR_NUM=$(printf '%s' "$STDOUT" | grep -oE 'pull/[0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
	if [ -n "$PR_NUM" ]; then
		CTX="PR #${PR_NUM} just created. IMMEDIATE NEXT ACTION: invoke /pr ${PR_NUM} dashboard to watch checks + CodeRabbit. Per CLAUDE.md §5 Step 8, required after every PR create."
		# v4.27 (#632) item #11: also auto-fire autofix-cycle.sh in the
		# background. Prior pattern was discipline-only — operator had to
		# remember to run the cycle after PR open. Background invocation
		# (& + nohup-style detach via setsid where available, otherwise
		# bash &) lets the cycle poll for CR's review on its own schedule
		# while Claude continues with other work.
		REPO_ROOT_HOOK=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
		AUTOFIX_CYCLE="${REPO_ROOT_HOOK}/.claude/scripts/cr/autofix-cycle.sh"
		if [ -n "$REPO_ROOT_HOOK" ] && [ -x "$AUTOFIX_CYCLE" ]; then
			# Detach from controlling terminal so the cycle survives the
			# Claude Code session that triggered it. Log to a per-PR file
			# under .claude/logs/ for forensics.
			mkdir -p "$REPO_ROOT_HOOK/.claude/logs" 2>/dev/null || true
			LOG_FILE="$REPO_ROOT_HOOK/.claude/logs/autofix-cycle-pr${PR_NUM}.log"
			(setsid nohup "$AUTOFIX_CYCLE" --pr "$PR_NUM" >"$LOG_FILE" 2>&1 &) 2>/dev/null ||
				(nohup "$AUTOFIX_CYCLE" --pr "$PR_NUM" >"$LOG_FILE" 2>&1 &) 2>/dev/null ||
				true
			CTX="${CTX} (autofix-cycle.sh fired in background → ${LOG_FILE})"
		fi
	else
		echo "pr-trigger: PR# not extracted from stdout ($(printf '%s' "$STDOUT" | head -c 100)) — generic directive only" >&2
		CTX="A PR was just created. Invoke /pr to display the dashboard."
	fi
	if DIRECTIVE=$(jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'); then
		printf '%s\n' "$DIRECTIVE"
	else
		echo "pr-trigger: jq emit failed — no directive emitted" >&2
	fi
fi
