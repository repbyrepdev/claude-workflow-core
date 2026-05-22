#!/bin/bash
set -u
# auto-register: false
# v4.28-W5 (#759): shared helper for phase 0.5 launcher end-of-run
# auth-failure summary. Sourced by phase0.5-{codex,copilot,gemini}-prefilter.sh
# so the auth-pattern regex + summary message format live in ONE place.
#
# Mode 100644 (sourced lib, never executed directly — exec-bit-required.yml
# exempt rule per #629).
#
# Usage (from a sourcing launcher):
#   . "$REPO_ROOT/.claude/_lib/phase05-auth-summary.sh"
#   phase05_emit_auth_summary "codex" "codex login" "$ERRORED" "$ATTEMPTED" "$ERR_EXCERPTS"
#
# Behavior:
#   - errored == 0 OR attempted == 0   → no output (silent on success)
#   - errored == attempted AND auth pattern in excerpts → "likely auth — try '<login>'"
#   - else → generic "see prior stderr lines"
#
# All output goes to stderr (operator-facing diagnostic).

# Anchor regex in ONE place. Future tweaks update this constant; bats
# test in .claude/tests/_lib/phase05-auth-summary.bats locks the contract.
PHASE05_AUTH_PATTERN='401|unauthorized|\bauth\b|login|expired|forbidden'

phase05_emit_auth_summary() {
	local cli_name="$1"
	local login_cmd="$2"
	local errored="$3"
	local attempted="$4"
	local err_excerpts="$5"

	# Silent when nothing to summarize.
	if [ "$errored" -le 0 ] || [ "$attempted" -le 0 ]; then
		return 0
	fi

	if [ "$errored" -eq "$attempted" ] &&
		echo "$err_excerpts" | grep -qiE "$PHASE05_AUTH_PATTERN"; then
		echo "phase0.5-${cli_name}: ${errored}/${attempted} agents errored (likely auth — try '${login_cmd}')" >&2
	else
		echo "phase0.5-${cli_name}: ${errored}/${attempted} agents errored — see prior stderr lines" >&2
	fi
}
