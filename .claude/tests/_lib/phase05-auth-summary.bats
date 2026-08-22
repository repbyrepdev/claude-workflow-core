#!/usr/bin/env bats
# covers: _lib/phase05-auth-summary.sh
#
# Locks two contracts of the shared phase0.5 launcher lib:
#   - phase05_log_no_reviewable_agents (#2530): backfills a phase0.5-run.jsonl
#     record when NO copilot/codex/gemini-callable agent ran, so a code-less
#     diff (version-bump / doc-only) still logs a run and ship-pr-cycle's
#     phase0.5 gate can advance. attempted>0 must be a no-op (per-agent records
#     already exist — double-logging would inflate the audit trail).
#   - phase05_emit_auth_summary: silent unless errored>0 AND attempted>0.

setup() {
	LIB_SRC="${BATS_TEST_DIRNAME}/../../../_lib/phase05-auth-summary.sh"
	[ -f "$LIB_SRC" ] || return 1
	command -v jq >/dev/null 2>&1 || return 1
	TEST_TMP=$(mktemp -d -t p05as.XXXXXX) || return 1
	LOG="$TEST_TMP/phase0.5-run.jsonl"
	# shellcheck source=../../../_lib/phase05-auth-summary.sh
	. "$LIB_SRC"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */p05as.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "#2530 attempted==0 → writes one record with the VERBATIM full sha + cli" {
	# ship-pr-cycle's phase0.5 gate matches on .sha == $(git rev-parse HEAD)
	# — the full 40 chars — so the record must carry the sha untruncated. A
	# full-length sha here locks that contract against a future truncation
	# refactor; the cli tag makes the backfill row attributable.
	sha="0123456789abcdef0123456789abcdef01234567"
	run phase05_log_no_reviewable_agents "codex" "$sha" "$LOG" "2026-07-09T00:00:00Z" 0
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -f "$LOG" ]
	[ "$(wc -l <"$LOG" | tr -d ' ')" -eq 1 ]
	run jq -e --arg sha "$sha" '.sha==$sha and .cli=="codex" and .status=="skipped-no-reviewable-agents" and .findings==0 and .phase=="0.5" and .agent=="<all>"' "$LOG"
	[ "$status" -eq 0 ]
}

@test "#2530 CR: an ABBREVIATED sha pin is normalized to the full 40-char commit" {
	# Exercises the git rev-parse --verify branch in the helper — the phase0.5
	# gate matches `.sha == $(git rev-parse HEAD)` EXACTLY, so a short pin (the
	# copilot --sha form) must be widened or the row never advances the gate.
	command -v git >/dev/null 2>&1 || skip "git unavailable"
	full=$(git rev-parse HEAD 2>/dev/null) || skip "not in a git repo"
	# Derive the short form by TRUNCATION, not `--short`: under core.abbrev=40
	# `--short` returns the full 40 chars, the helper takes its already-full
	# fast path, and this test would pass GREEN without ever exercising the
	# normalization branch it exists to cover (passes-for-the-wrong-reason).
	short=${full:0:8}
	# Assert the SOURCE is a full 40-char sha — that is what makes the
	# truncation above meaningful (and catches a rev-parse returning empty or
	# short). Asserting ${#short} instead would be vacuous: it is 8 by
	# construction. (CR simplifier, conf 10.)
	[ "${#full}" -eq 40 ]
	run phase05_log_no_reviewable_agents "copilot" "$short" "$LOG" "2026-07-09T00:00:00Z" 0
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run jq -e --arg sha "$full" '.sha == $sha' "$LOG"
	[ "$status" -eq 0 ]
}

@test "#2530 attempted>0 → no-op (per-agent records already cover the SHA)" {
	run phase05_log_no_reviewable_agents "codex" "0123456789abcdef0123456789abcdef01234567" "$LOG" "2026-07-09T00:00:00Z" 3
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	# setup() gives a fresh empty dir and nothing writes $LOG before this,
	# so the no-op is proven by the log file never being created.
	[ ! -f "$LOG" ]
}

@test "#2530 repeated appends accrue one valid JSON object per line" {
	# Two sequential same-process appends (NOT a concurrency test): each
	# record is its own well-formed JSONL line the SHA-presence gate reads.
	# Each append is run via bats `run` so its exit status + (empty) stdout are
	# asserted independently — a helper that started printing to stdout or
	# returning non-zero would surface here, not just in the file contents (CR).
	run phase05_log_no_reviewable_agents "copilot" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$LOG" "2026-07-09T00:00:00Z" 0
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run phase05_log_no_reviewable_agents "gemini" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$LOG" "2026-07-09T00:00:01Z" 0
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ "$(wc -l <"$LOG" | tr -d ' ')" -eq 2 ]
	# EVERY line must parse as JSON AND carry phase 0.5 — slurp + all(), so a
	# single bad record fails the assertion (the prior per-line `-e` reflected
	# only the LAST line's truth value, masking an earlier failure — CR).
	run jq -es 'length == 2 and all(.[]; .phase == "0.5")' "$LOG"
	[ "$status" -eq 0 ]
}

@test "auth-summary: silent when errored==0" {
	run phase05_emit_auth_summary "codex" "codex login" 0 3 "some stderr"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "auth-summary: silent when attempted==0" {
	# errored>0 here (2) so this case ISOLATES the attempted==0 guard — a silent
	# result cannot be attributed to errored==0 (CR: the prior 0 0 co-satisfied
	# both guards). attempted==0 alone must still silence the summary.
	run phase05_emit_auth_summary "codex" "codex login" 2 0 "401 unauthorized"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "auth-summary: all-errored + auth pattern → 'likely auth' hint" {
	run phase05_emit_auth_summary "copilot" "copilot login" 2 2 "401 unauthorized"
	[ "$status" -eq 0 ]
	[[ $output == *"likely auth"* ]]
	[[ $output == *"copilot login"* ]]
}

@test "auth-summary: partial errors, no auth pattern → generic hint" {
	run phase05_emit_auth_summary "gemini" "gemini login" 1 3 "network reset"
	[ "$status" -eq 0 ]
	[[ $output == *"see prior stderr lines"* ]]
}
