#!/bin/bash
set -euo pipefail
# bats-required: 0
# (Thin wrapper over the GitHub Copilot CLI — exercising it needs the CLI +
#  network, so it carries no standalone bats; the ship-pr-cycle dogfoods it
#  live. #223.)
# v4.24 (#597): Copilot free-tier fallback chain helper.
#
# Invokes `copilot -p [--model=$M]` against a prompt, trying any configured
# free-tier models then ALWAYS the CLI's configured DEFAULT model (#223) until
# one succeeds. The old gpt-4.1/gpt-5-mini/gpt-4o "0x" IDs were RETIRED from
# Copilot CLI 1.0.57 (its default is now claude-sonnet-4.6) — pinning them
# silently disabled phase0.5; the default-model fallback is drift-proof.
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
#                         (default: empty — appends the CLI default model as a
#                         drift-proof fallback; the old gpt-* free IDs were
#                         retired from Copilot CLI 1.0.57, #223)
#   COPILOT_MODEL         pin to a single model (tried FIRST, but the chain still
#                         appends the CLI default as a final fallback — it does
#                         NOT skip the chain; see #223)
#   COPILOT_TIMEOUT_SEC   per-model timeout in seconds (default 150). The old
#                         hard-coded 60s timed out the agentic CLI default model
#                         (claude-sonnet-4.6) on a real diff — #223 phase0.5
#                         dogfood logged rc=124 (timeout) for all 5 agents.
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

# Determine model preference chain. The old gpt-4.1/gpt-5-mini/gpt-4o "free"
# IDs were RETIRED from the GitHub Copilot CLI (1.0.57's default is
# claude-sonnet-4.6) — passing them yields `Model "X" from --model flag is not
# available` and silently disabled phase0.5 (#223). So: honor an explicit
# COPILOT_MODEL / COPILOT_FREE_MODELS override, then ALWAYS fall back to the
# CLI's CONFIGURED DEFAULT model (an appended empty entry => no --model flag) so
# a stale pinned ID can never again take the prefilter offline.
if [ -n "${COPILOT_MODEL:-}" ]; then
	MODELS="$COPILOT_MODEL"
else
	MODELS="${COPILOT_FREE_MODELS:-}"
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
# Fail fast if NEITHER timeout nor gtimeout exists: otherwise TIMEOUT_CMD stays
# "timeout", every model invocation fails on the missing binary, and the loop
# falls through to the misleading "auth/outage?" message below (#223). A clear
# dependency error is far easier to triage. exit 1 = caller falls back.
command -v "$TIMEOUT_CMD" >/dev/null 2>&1 || {
	echo "copilot prefilter: requires a timeout wrapper (GNU 'timeout' or 'gtimeout') — install coreutils" >&2
	exit 1
}
# Validate COPILOT_TIMEOUT_SEC up front (only defaulted before, never checked):
# a malformed value makes `timeout <bad> copilot` fail for EVERY model → the same
# misleading auth/outage fallback. Must be a positive integer.
TIMEOUT_SEC="${COPILOT_TIMEOUT_SEC:-150}"
[[ $TIMEOUT_SEC =~ ^[1-9][0-9]*$ ]] || {
	echo "copilot prefilter: COPILOT_TIMEOUT_SEC must be a positive integer (got: '$TIMEOUT_SEC')" >&2
	exit 2
}

# Try each model in order; first to succeed wins. A trailing EMPTY entry is
# appended unconditionally = "use the CLI's default model" (no --model flag) —
# the drift-proof fallback so phase0.5 keeps working through Copilot lineup
# changes (#223).
# `read` returns 1 at EOF (here-string has no trailing delimiter) but still
# populates the array — `|| true` keeps it -e-safe (CR #478 r3 added set -e).
IFS=',' read -ra MODEL_ARR <<<"$MODELS" || true
MODEL_ARR+=("")
for model in "${MODEL_ARR[@]}"; do
	# Strip ALL whitespace (model IDs contain none, so this also drops any stray
	# internal spaces from a sloppy comma list). An EMPTY model => omit --model =>
	# CLI default model.
	model=$(printf '%s' "$model" | tr -d '[:space:]')
	MODEL_ARG=()
	[ -n "$model" ] && MODEL_ARG=(--model="$model")

	# Timeout configurable via COPILOT_TIMEOUT_SEC (default 150s). The old
	# hard-coded 60s timed out the agentic default model (claude-sonnet-4.6) on a
	# real diff (#223 phase0.5 dogfood: rc=124 for all 5 agents). Under set -u,
	# expand possibly-empty arrays with the `+"${ARR[@]}"` guard. Copilot CLI's
	# `-p` uses its arg directly and ignores stdin, so we DON'T pipe FULL_PROMPT
	# into stdin (silent duplicate).
	if OUTPUT=$("$TIMEOUT_CMD" "$TIMEOUT_SEC" copilot \
		-p "$FULL_PROMPT" \
		${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
		"${SAFE_ARGS[@]}" \
		${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
		2>/dev/null); then
		# Got a response — emit and exit 0.
		printf '%s' "$OUTPUT"
		exit 0
	fi
	# This model failed (retired ID, auth, timeout, paid tier) — try next.
done

# Even the CLI default model failed — a genuine outage or auth problem.
echo "copilot prefilter: all candidate models AND the CLI default failed (auth/outage?)" >&2
exit 1
