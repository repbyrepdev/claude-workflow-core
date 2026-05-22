#!/bin/bash
set -euo pipefail
# v4.15.BB — Stop hook: catch hand-off-to-user language in my last assistant
# message and inject a directive to run the command myself.
#
# WHY: 2026-04-20 observed pattern — fix needs a terminal command (install
# a dep, apply sed, chmod, restart a service). I ask user to run it instead
# of executing. User pushed back: "if a fix requires a terminal command
# you do it yourself in the fix session". The memory rule alone isn't
# enforcement; a hook catches the language pattern and forces correction.
#
# HOW: Stop event fires when I try to end a turn. Hook reads transcript,
# scans last assistant message for hand-off phrases. If found, emits JSON
# hookSpecificOutput.additionalContext asking me to execute instead. I see
# the reminder on next turn and follow through.
#
# Conservative matching — only trigger on imperative hand-off to user:
#   - "please run <cmd>" / "run this command yourself"
#   - "you should install" / "you need to install"
#   - "manually run" / "run it manually"
#   - "in your terminal" / "in a terminal"
#   - "exit + reopen" / "restart claude"  (session-restart asks are OK)

# Hook payload includes .transcript_path on Stop events.
# v4.15.DD: fail-closed on stdin/jq errors (surface via stderr). Prior
# `2>/dev/null || echo '{}'` masked broken wiring as no-match.
PAYLOAD=$(cat) || {
	echo "no-handoff-to-user: stdin read failed — skipping" >&2
	exit 0
}
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // ""') || {
	echo "no-handoff-to-user: payload unparseable — skipping" >&2
	exit 0
}
# v4.15.DD: fix short-circuit parse — `A || B && exit` parses as `A || (B && exit)`,
# skipping exit when A is true (empty TRANSCRIPT). Explicit if/then.
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
	exit 0
fi

# Pull the last assistant message's text content. Transcript is JSONL with
# one line per message. Filter to assistant messages, take last.
# v4.15.EE: slurp via jq -s so multi-line messages stay intact as a single
# string; take the last one. Previous awk last-line approach missed earlier
# lines of the final message. -s reads whole file once; transcripts are
# bounded (session-scoped) so memory is acceptable.
LAST_ASSISTANT=$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' "$TRANSCRIPT" 2>/dev/null || true)
[ -z "$LAST_ASSISTANT" ] && exit 0

# Patterns that indicate asking user to run a terminal command.
# Deliberately strict — want to catch real hand-offs, not refs/mentions.
MATCHES=""
if echo "$LAST_ASSISTANT" | grep -qiE '(please|you need to|you should|you must) (run|install|execute|invoke|try)'; then
	MATCHES="$MATCHES · imperative: 'you need/should run/install'"
fi
if echo "$LAST_ASSISTANT" | grep -qiE '(run|execute) (this|that|the) (command|script) (yourself|manually)'; then
	MATCHES="$MATCHES · explicit: 'run this yourself'"
fi
if echo "$LAST_ASSISTANT" | grep -qiE 'in (your|a) terminal'; then
	MATCHES="$MATCHES · phrase: 'in your terminal'"
fi
if echo "$LAST_ASSISTANT" | grep -qiE '(manually install|manually run|install it manually)'; then
	MATCHES="$MATCHES · phrase: 'manually install/run'"
fi

[ -z "$MATCHES" ] && exit 0

# Emit a reminder via additionalContext. Don't block (Stop hook exit 2
# actually prevents the turn from ending, which loops forever — use
# JSON stdout to softly inject a directive).
jq -n --arg ctx "=== v4.15.BB hand-off detected in last response ===
Signals found:$MATCHES

You asked the user to run a terminal command. Per CLAUDE.md/memory rule 'Run Terminal Commands Myself': if a fix needs a shell command (install dep, run migration, apply sed, chmod), execute it yourself in THIS session via Bash. Don't stop and hand off.

Preference: (1) portable alternative that doesn't need install; (2) install if cheap (brew/npm/pip); (3) ask user ONLY if auth-gated or destructive (gcloud auth login, rm -rf, force-push).

Acknowledge + run the command on your next turn. If you intentionally wanted user to run it (auth/destructive case), reply with 'user-gated: <reason>' and proceed." \
	'{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
exit 0
