#!/bin/bash
set -u
# auto-register: false
# v4.28-W5 (#759): shared phase-0.5 launcher end-of-run helpers, sourced by
# phase0.5-{codex,copilot,gemini}-prefilter.sh so their common logic lives in
# ONE place. Two functions:
#   - phase05_emit_auth_summary (#759): the end-of-run auth-failure summary
#     (anchors the auth-pattern regex + message format).
#   - phase05_log_no_reviewable_agents (#2530): backfills a phase0.5-run.jsonl
#     run record when no CLI-callable agent ran, so a code-less diff still
#     logs a run and ship-pr-cycle's phase0.5 gate can advance.
#
# Mode 100644 (sourced lib, never executed directly — exec-bit-required.yml
# exempt rule per #629).
#
# Usage (from a sourcing launcher):
#   . "$REPO_ROOT/.claude/_lib/phase05-auth-summary.sh"
#   phase05_emit_auth_summary "codex" "codex login" "$ERRORED" "$ATTEMPTED" "$ERR_EXCERPTS"
#   phase05_log_no_reviewable_agents "codex" "$SHA" "$LOG" "$TS" "$ATTEMPTED"
#
# Behavior:
#   phase05_emit_auth_summary (all output to stderr, operator-facing):
#   - errored == 0 OR attempted == 0   → no output (silent on success)
#   - errored == attempted AND auth pattern in excerpts → "likely auth — try '<login>'"
#   - else → generic "see prior stderr lines"
#   phase05_log_no_reviewable_agents (appends one JSONL record, no stdout):
#   - attempted == 0 → append one skipped-no-reviewable-agents record
#   - attempted  > 0 → no-op (per-agent records already cover the SHA)

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

# (#2530) Guarantee phase0.5 logs at least one run record per SHA even when
# NO copilot/codex/gemini-callable agent ran. That happens when the diff
# matches ONLY security-review — i.e. it touches only security-review's
# unique extensions (.conf/.json, e.g. a plugin.json version bump): the
# per-agent loop skips security-review (and semgrep) WITHOUT incrementing
# ATTEMPTED or writing a record, and no CLI-callable agent matched.
# (semgrep can never be the SOLE match — its required_extensions equal
# code-reviewer's, so any semgrep-matching diff also matches a CLI-callable
# agent → ATTEMPTED>0.) Without a record for the SHA, ship-pr-cycle's
# phase0.5 gate stays "not yet logged" forever, so such a code-less change
# (version-bump / pure-config PR) can never advance to phase1/phase2 and
# pre-push refuses — previously only escapable via PIPELINE_GATE_SKIP. The
# per-agent loop already logs when attempted>0, so this backfills ONLY the
# attempted==0 case (no-op when attempted>0).
#
# The record carries `cli` (matching the codex/gemini per-agent records;
# copilot's own per-agent records omit it) so the backfill row is
# attributable to the launcher that wrote it. The `sha` is written
# VERBATIM — callers MUST pass the full 40-char `git rev-parse HEAD`,
# because ship-pr-cycle's phase0.5 gate matches on `.sha == HEAD` exactly;
# a truncated sha would silently fail to advance.
# Args: <cli> <sha> <log-path> <iso-ts> <attempted-count>.
phase05_log_no_reviewable_agents() {
	local cli="$1"
	local sha="$2"
	local log="$3"
	local ts="$4"
	local attempted="$5"

	# attempted>0 → per-agent records already cover this SHA; nothing to do.
	[ "$attempted" -eq 0 ] || return 0

	# Normalize a possibly-abbreviated pin to the full 40-char commit SHA — the
	# phase0.5 gate matches `.sha == HEAD` exactly, so a short pin would log a
	# non-matching row that never advances the gate. Normalized HERE (the ONE
	# shared call site) so EVERY prefilter — copilot, codex, gemini — gets it,
	# not just whichever caller remembered to (#2530 CR: SSOT, not per-caller).
	# Only invoke git when the sha is NOT already full-40-hex: the normal HEAD
	# case skips git entirely (fast + keeps unit tests with synthetic SHAs
	# git-independent); a genuine short pin resolves; an unresolvable value
	# falls back to as-given (better a row than none — the gate simply won't
	# match, same as before this backfill existed).
	if ! printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$'; then
		sha=$(git rev-parse --verify "${sha}^{commit}" 2>/dev/null || printf '%s' "$sha")
	fi

	jq -nc --arg ts "$ts" --arg sha "$sha" --arg cli "$cli" \
		'{ts:$ts, sha:$sha, phase:"0.5", cli:$cli, agent:"<all>", findings:0, status:"skipped-no-reviewable-agents"}' \
		>>"$log"
}
