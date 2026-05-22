#!/bin/bash
set -uo pipefail
# v4.24 (#597): Copilot free-tier fallback chain helper.
#
# Invokes `copilot -p --model=$M` against stdin+prompt across the free-tier
# model preference order until one succeeds, else falls back to no-output.
# 0 premium requests consumed on Enterprise seats (gpt-4.1/gpt-5-mini/gpt-4o
# all have 0x multiplier per 2026 Copilot billing table).
#
# Usage:
#   echo "$CONTEXT" | .claude/scripts/copilot/try-free.sh "prompt text"
#
# Exit codes:
#   0 — a free model returned output (on stdout)
#   1 — all free models failed or unavailable; caller should fall back
#
# Env overrides:
#   COPILOT_FREE_MODELS   comma-separated preference order
#                         (default: gpt-4.1,gpt-5-mini,gpt-4o)
#   COPILOT_MODEL         pin to a single model (skips the chain)
#
# Graceful behavior:
#   - `copilot` binary missing → exit 1 silently, no error
#   - Auth failure → exit 1 silently (caller must have a fallback path)
#   - Model becomes paid → try next free model in chain
#
# Safety: all invocations pass --deny-tool=shell --deny-tool=write by default
# so the model can't execute shell commands or write files in hook contexts.
# Override via COPILOT_EXTRA_ARGS for trusted-context callers.

PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then
	echo "error: prompt argument required" >&2
	echo "usage: echo <context> | $0 \"<prompt>\"" >&2
	exit 2
fi

# Copilot CLI presence check — missing is a valid no-op path.
command -v copilot >/dev/null 2>&1 || {
	echo "copilot CLI not installed — skipping" >&2
	exit 1
}

# Read stdin context (diff, commit log, etc.) if present. Non-blocking: if
# caller didn't pipe anything, CONTEXT stays empty and the prompt is all.
CONTEXT=""
if [ ! -t 0 ]; then
	CONTEXT=$(cat)
fi

# Compose final prompt: context (if any) + instruction.
FULL_PROMPT="$PROMPT"
if [ -n "$CONTEXT" ]; then
	FULL_PROMPT="$PROMPT

Context:
$CONTEXT"
fi

# Determine model preference chain.
if [ -n "${COPILOT_MODEL:-}" ]; then
	MODELS="$COPILOT_MODEL"
else
	MODELS="${COPILOT_FREE_MODELS:-gpt-4.1,gpt-5-mini,gpt-4o}"
fi

# Safety-default flags. Caller can extend via COPILOT_EXTRA_ARGS.
SAFE_ARGS=(-s --deny-tool=shell --deny-tool=write)
EXTRA_ARGS=()
if [ -n "${COPILOT_EXTRA_ARGS:-}" ]; then
	# shellcheck disable=SC2206  # intentional word-split
	EXTRA_ARGS=($COPILOT_EXTRA_ARGS)
fi

# Resolve portable timeout command (GNU timeout on Linux, gtimeout on macOS).
TIMEOUT_CMD="timeout"
if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
	TIMEOUT_CMD="gtimeout"
fi

# Try each free model in order. First to succeed wins.
IFS=',' read -ra MODEL_ARR <<<"$MODELS"
for model in "${MODEL_ARR[@]}"; do
	# Trim whitespace
	model=$(printf '%s' "$model" | tr -d ' ')
	[ -z "$model" ] && continue

	# Run copilot with this model. Timeout kept loose (60s) since free
	# models are usually fast but GPT-4o occasionally spikes.
	# Under set -u, `${ARR[@]}` on an empty array expands to unbound-var.
	# Use the `+"${ARR[@]}"` conditional expansion so empty arrays are safe.
	# Copilot CLI's `-p` uses its arg directly and ignores stdin, so we
	# DON'T pipe FULL_PROMPT into stdin — it would be a silent duplicate.
	if OUTPUT=$("$TIMEOUT_CMD" 60 copilot \
		-p "$FULL_PROMPT" \
		--model="$model" \
		"${SAFE_ARGS[@]}" \
		${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
		2>/dev/null); then
		# Got a response — emit and exit 0.
		printf '%s' "$OUTPUT"
		exit 0
	fi
	# This model failed (not available, auth issue, timeout, paid tier,
	# etc.) — continue to next.
done

# All models failed.
echo "all copilot free models failed or unavailable" >&2
exit 1
