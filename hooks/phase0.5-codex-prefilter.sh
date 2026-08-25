#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W4 (#661) — Phase 0.5 Codex CLI free-tier pre-filter.
#
# Mirrors phase0.5-copilot-prefilter.sh shape (per-agent canonical_brief →
# CLI invocation → JSON findings → dedup) but uses OpenAI Codex CLI 0.125
# `codex exec` non-interactive mode. Project-level config at .codex/config.toml
# defines the `review` profile (gpt-5.3-codex) and `fast-triage` profile
# (gpt-5.4-mini). CODEX_HOME=$REPO_ROOT/.codex required — Codex 0.125 only
# loads $CODEX_HOME/config.toml, NOT auto-discovered from cwd.
#
# Zero Claude tokens. Runs alongside Copilot + Gemini prefilters at Phase 0.5.
#
# Usage:
#   .claude/hooks/phase0.5-codex-prefilter.sh [--base main]
#
# Output:
#   stdout: JSON array of dedup'd findings (may be [])
#   .claude/logs/phase0.5-run.jsonl: per-agent entry with cli=codex
# Exit:
#   0 = ran successfully (findings may be present; caller decides), OR
#       codex CLI genuinely absent (graceful skip, logged skipped-no-codex-cli
#       — parity with the copilot pre-filter, #2259)
#   1 = tooling error (yq missing / config missing / codex present but broken)
#   2 = arg error, or unusable environment (not a git repo, LOG_DIR
#       uncreatable/unwritable, canonical_brief read failure)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$REPO_ROOT" ] || {
	echo "phase0.5: must be run inside a git repo" >&2
	exit 2
}
cd "$REPO_ROOT" || exit 2

BASE="main"
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		[ "$#" -ge 2 ] || {
			echo "phase0.5: --base requires value" >&2
			exit 2
		}
		BASE="$2"
		shift 2
		;;
	-h | --help)
		sed -n '4,27p' "$0"
		exit 0
		;;
	*)
		echo "phase0.5: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# v0.6.5 (#39): plugin-cache fallback for shared config.
PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
# shellcheck source=../_lib/resolve-plugin-helper.sh
. "$PLUGIN_LIB/resolve-plugin-helper.sh"

CONFIG="$(resolve_plugin_helper "review-config.yml" 2>/dev/null || echo "")"
DEDUP_HOOK="$(dirname "$0")/phase1-dedup.sh"
LOG_DIR="$REPO_ROOT/.claude/logs"
LOG="$LOG_DIR/phase0.5-run.jsonl"
CODEX_HOME_REPO="$REPO_ROOT/.codex"

if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
	echo "phase0.5-codex: review-config.yml missing (checked $REPO_ROOT/.claude/ + plugin cache)" >&2
	exit 1
fi
# Sourced BEFORE the CLI check so the shared graceful-skip helper is
# available (function definitions only — no side effects beyond the
# audit-dedup path var). Preflight still runs later, pre-invocation.
# shellcheck source=../_lib/phase05-dedupe.sh
. "$PLUGIN_LIB/phase05-dedupe.sh"
command -v codex >/dev/null 2>&1 || {
	# Absent CLI = graceful skip (#2259): parity with the copilot
	# pre-filter's absent-helper path. An OPTIONAL pre-filter that is not
	# installed must not hard-fail the walk; the cli-tagged skip status is
	# logged so phase1-scaler treats it as "no pre-filter signal", not
	# "ran clean". (Present-but-broken preconditions below still
	# hard-fail.) Shared helper: logs, emits [], exits 0.
	phase05_emit_skip_and_exit codex "$LOG" "skipped-no-codex-cli" "Install via brew + 'codex login' to enable"
}
[ -d "$CODEX_HOME_REPO" ] || {
	echo "phase0.5-codex: $CODEX_HOME_REPO missing — Codex 0.125 needs project-level config" >&2
	exit 1
}
# CR Phase 3 Major: require config.toml specifically, not just the dir.
# Without it, Codex falls back to ~/.codex/config.toml (or built-in defaults)
# which breaks the repo-local CODEX_HOME contract — review profile + sandbox_mode
# settings would silently come from elsewhere with nondeterministic launcher behavior.
[ -f "$CODEX_HOME_REPO/config.toml" ] || {
	echo "phase0.5-codex: $CODEX_HOME_REPO/config.toml missing — required for repo-local Codex profiles" >&2
	exit 1
}
# Export CODEX_HOME so codex picks up our review/fast-triage profiles
# (Codex 0.125 only loads $CODEX_HOME/config.toml, not auto-discovered).
export CODEX_HOME="$CODEX_HOME_REPO"
[ -x "$DEDUP_HOOK" ] || {
	echo "phase0.5: phase1-dedup.sh missing at $DEDUP_HOOK" >&2
	exit 1
}
# v4.28-W5 #827: 2-stage dedup wiring extracted to shared lib (sourced
# above, before the CLI check). Preflight runs BEFORE invoking Codex so a
# missing audit-dedup hook fails-loud instead of wasting CLI quota.
phase05_preflight_audit_dedup_hook
command -v yq >/dev/null 2>&1 || {
	echo "phase0.5: yq required" >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	echo "phase0.5: jq required" >&2
	exit 1
}

# v4.28-W3 r2 SFH F4: validate LOG_DIR is writable upfront so per-write
# `2>/dev/null || true` can be dropped (was silently disabling audit on
# disk-full / perm-error / readonly-fs). Fail loud with rc=2 if not writable.
_mkdir_err=$(mktemp)
if ! mkdir -p "$LOG_DIR" 2>"$_mkdir_err"; then
	echo "phase0.5: cannot create LOG_DIR=$LOG_DIR: $(cat "$_mkdir_err")" >&2
	rm -f "$_mkdir_err"
	exit 2
fi
rm -f "$_mkdir_err"
if ! [ -w "$LOG_DIR" ]; then
	echo "phase0.5: LOG_DIR=$LOG_DIR not writable — refusing to run with silent audit-disabled" >&2
	exit 2
fi
# v4.28-W3 r2 SFH F2: capture git stderr so SHA failures surface to operator
# even when the empty-fallback keeps the script running. Empty SHA in log
# entries is metadata-loss-but-not-fatal; silent suppression of git error
# (broken HEAD, gc'd ref) was masking real ops issues.
_git_err=$(mktemp)
# CR Phase 2 final4: trap-on-EXIT guarantees cleanup even if any of the
# git calls below cause early exit under set -eo pipefail. Without it
# the tempfile would leak in /tmp on git-failure paths.
trap 'rm -f "$_git_err" 2>/dev/null' EXIT
SHA=$(git rev-parse HEAD 2>"$_git_err" || echo "")
[ -s "$_git_err" ] && echo "phase0.5: warning — git rev-parse stderr: $(cat "$_git_err")" >&2
# v4.28-W3 r2 SFH F6: capture git diff stderr too — bad base ref or shallow
# clone would silently produce empty diff, hitting the "nothing to pre-filter"
# branch as if the diff were legitimately empty.
DIFF_FILES_JOINED=$(git diff --name-only "${BASE}..HEAD" 2>"$_git_err" | tr '\n' ' ' | sed 's/ $//')
[ -s "$_git_err" ] && echo "phase0.5: warning — git diff --name-only stderr: $(cat "$_git_err")" >&2
DIFF_CONTENT=$(git diff "${BASE}..HEAD" 2>"$_git_err")
[ -s "$_git_err" ] && echo "phase0.5: warning — git diff stderr: $(cat "$_git_err")" >&2
trap - EXIT
rm -f "$_git_err"
if [ -z "$DIFF_CONTENT" ]; then
	echo "phase0.5: empty ${BASE}..HEAD diff — nothing to pre-filter" >&2
	echo "[]"
	exit 0
fi

# Size guard — Codex free-tier has a context window we can blow through
# on monster diffs. ~100KB (default) is well within Codex context limits after
# prompt overhead, but configurable via env for experimentation.
DIFF_MAX_BYTES="${PHASE05_DIFF_MAX_BYTES:-102400}"
diff_bytes=$(printf '%s' "$DIFF_CONTENT" | wc -c | tr -d ' ')
if [ "$diff_bytes" -gt "$DIFF_MAX_BYTES" ]; then
	echo "phase0.5: diff size ${diff_bytes}B exceeds PHASE05_DIFF_MAX_BYTES=${DIFF_MAX_BYTES} — skipping pre-filter (Phase 1 Claude agents handle large diffs)" >&2
	# Log skip so scaler sees 0 findings but knows Phase 0.5 didn't run.
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$SHA" \
		--argjson bytes "$diff_bytes" --argjson max "$DIFF_MAX_BYTES" \
		'{ts:$ts, sha:$sha, phase:"0.5", cli:"codex", agent:"<all>", findings:0, status:"skipped-diff-too-large", diff_bytes:$bytes, max_bytes:$max}' \
		>>"$LOG"
	echo "[]"
	exit 0
fi

# v4.28-W3 #660: Phase 0.5 agent selection delegates to list-phase1-agents.sh
# for diff-aware scoping (instead of excluding ALL scoped agents). Pre-filter
# only the agents that already qualify for Phase 1 on this diff. Prior logic
# excluded code-reviewer + silent-failure-hunter once they got proper
# required_extensions, which would have silently disabled Phase 0.5.
#
# Phase 1 r1 silent-failure-hunter + pr-test-analyzer findings (#660):
# distinguish list-phase1-agents.sh exit codes — rc=0 with empty stdout = no
# agents matched (legitimate empty/doc-only diff); rc=1 = no-agents-matched
# explicit (per script's contract); rc=2 = tooling/config broken (yq missing,
# bad base ref, missing review-config). Don't collapse them all to "exit 0
# with []" — that masks broken installations as "Phase 0.5 ran clean."
# review-config-check.sh enforces canonical_brief on every agent at commit
# time (schema invariant), but we still warn-and-skip per-agent at runtime
# as defense-in-depth — no guarantee the schema check ran in arbitrary
# execution contexts (cherry-pick, manual override, broken pre-commit).
# See r3 SFH F6 fix below.
LIST_HOOK="$(dirname "$0")/list-phase1-agents.sh"
LIST_ERR=$(mktemp)
LIST_RC=0
PHASE1_AGENTS=$("$LIST_HOOK" "$BASE" 2>"$LIST_ERR") || LIST_RC=$?

if [ "$LIST_RC" -eq 2 ]; then
	echo "phase0.5: list-phase1-agents.sh failed (rc=2 — tooling/config broken):" >&2
	cat "$LIST_ERR" >&2
	rm -f "$LIST_ERR"
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$SHA" \
		'{ts:$ts, sha:$sha, phase:"0.5", cli:"codex", agent:"<all>", findings:0, status:"errored-list-agents-broken"}' \
		>>"$LOG"
	exit 1
fi

# v4.28-W3 r3 SFH: any rc not in {0, 1, 2} is unexpected — SIGKILL=137,
# segfault=139, OOM-killed, signal-15/9. Prior code fell through to the
# empty-PHASE1_AGENTS skip-path, masking a crashed sub-process as a benign
# "no work" skip. Fail loud with surfaced rc + LIST_ERR contents.
if [ "$LIST_RC" -ne 0 ] && [ "$LIST_RC" -ne 1 ]; then
	echo "phase0.5: list-phase1-agents.sh exited with unexpected rc=$LIST_RC (signal/crash):" >&2
	cat "$LIST_ERR" >&2
	rm -f "$LIST_ERR"
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$SHA" --argjson rc "$LIST_RC" \
		'{ts:$ts, sha:$sha, phase:"0.5", cli:"codex", agent:"<all>", findings:0, status:"errored-list-agents-crashed", list_rc:$rc}' \
		>>"$LOG"
	exit 1
fi

if [ -z "$PHASE1_AGENTS" ]; then
	# rc=0 (empty stdout) OR rc=1 (script's "no agents matched" contract).
	# Either way: nothing for Phase 0.5 to do. Log the skip so the run-log
	# shows Phase 0.5 was attempted (not silently disabled).
	# v4.28-W3 r3 SFH: surface LIST_ERR (non-empty on rc=1) so operator sees
	# the script's "no Phase 1 agents matched" diagnostic, not just our
	# generic message.
	echo "phase0.5: list-phase1-agents.sh returned no agents for diff vs $BASE — nothing to pre-filter" >&2
	if [ -s "$LIST_ERR" ]; then
		echo "phase0.5: list-phase1-agents.sh stderr:" >&2
		cat "$LIST_ERR" >&2
	fi
	rm -f "$LIST_ERR"
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$SHA" --arg base "$BASE" \
		'{ts:$ts, sha:$sha, phase:"0.5", cli:"codex", agent:"<all>", findings:0, status:"skipped-no-agents-matched-diff", base:$base}' \
		>>"$LOG"
	echo "[]"
	exit 0
fi
rm -f "$LIST_ERR"
AGENTS="$PHASE1_AGENTS"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ALL_FINDINGS="[]"
TOTAL=0
# v4.28-W4 #716: track per-agent error count + collect stderr excerpts
# for end-of-run auth-failure heuristic. Empty array on success path.
ERRORED=0
ATTEMPTED=0
ERR_EXCERPTS=""

for agent in $AGENTS; do
	# Skip security-review (invokes a Claude skill, not prompt-able via Codex)
	# + semgrep (CLI, not agent — runs separately).
	case "$agent" in
	security-review | semgrep) continue ;;
	esac

	# v4.28-W4 #716: ATTEMPTED counts only codex-callable agents (post-skip)
	# so the all-errored heuristic doesn't get diluted by skipped agents.
	ATTEMPTED=$((ATTEMPTED + 1))
	# Phase 1 r1 silent-failure-hunter (#660): capture yq stderr so a
	# corrupted review-config.yml fails loud instead of dropping the
	# agent silently via empty `brief`.
	yq_err=$(mktemp)
	if ! brief=$(A="$agent" yq -r '.agents[strenv(A)].canonical_brief // ""' "$CONFIG" 2>"$yq_err"); then
		echo "phase0.5: yq failed reading canonical_brief for agent=$agent:" >&2
		cat "$yq_err" >&2
		rm -f "$yq_err"
		exit 2
	fi
	rm -f "$yq_err"
	# v4.28-W3 r3 SFH (defense-in-depth runtime guard, see schema-check
	# comment above): silent skip on empty canonical_brief masks config
	# drift in arbitrary execution contexts (cherry-pick, manual override,
	# broken pre-commit). Record + warn instead.
	if [ -z "$brief" ]; then
		echo "phase0.5: agent=$agent has empty canonical_brief in review-config.yml — skipping (run review-config-check.sh)" >&2
		jq -nc --arg ts "$TS" --arg sha "$SHA" --arg agent "$agent" \
			'{ts:$ts, sha:$sha, phase:"0.5", cli:"codex", agent:$agent, findings:0, status:"skipped-empty-canonical-brief"}' \
			>>"$LOG"
		continue
	fi

	# Placeholder substitution — matches phase1-launcher.sh semantics.
	brief=${brief//\{BASE_REF\}/$BASE}
	brief=${brief//\{HEAD_SHA\}/${SHA:0:12}}
	brief=${brief//\{ROUND\}/0.5}
	brief=${brief//\{DIFF_FILES\}/$DIFF_FILES_JOINED}

	# Tack on explicit output format contract so Codex emits parseable JSON.
	full_prompt="$brief

DIFF TO REVIEW:
\`\`\`diff
$DIFF_CONTENT
\`\`\`

OUTPUT: Return ONLY a JSON array of findings (or []). Shape:
[{\"agent\": \"$agent\", \"file\": \"path\", \"line\": <int>, \"category\": \"<str>\", \"severity\": \"high|medium|low\", \"description\": \"<1 sentence>\", \"confidence\": <1-10>}]
No prose. No markdown fence. Just the array."

	# v4.28-W4 (#661): Invoke `codex exec` with the canonical_brief prompt.
	# `codex exec` is non-interactive (matches the try-free.sh contract).
	# Phase 1 r3 code-reviewer (conf 7): use --output-last-message to write
	# the model's response to a file (avoids stdout session preamble like
	# 'OpenAI Codex v0.125.0 ... workdir: ... model: ...' that would defeat
	# the jq array-type check). Redirect stdin from /dev/null so codex 0.125
	# doesn't block waiting on inherited tty stdin (it always reads stdin
	# even with a positional prompt — verified in code-reviewer dogfood).
	# Use --skip-git-repo-check (uncommitted state OK) + --color=never.
	_helper_err=$(mktemp)
	_helper_out=$(mktemp)
	_helper_rc=0
	# 90s timeout — Codex review prompts run reasoning end-to-end + can take
	# longer than Copilot (gpt-5.3-codex with high effort). Bumped from 60s.
	timeout 90 codex exec --skip-git-repo-check --color=never \
		--output-last-message "$_helper_out" \
		-- "$full_prompt" </dev/null >/dev/null 2>"$_helper_err" || _helper_rc=$?
	# Read the model's response from the output file (just the JSON, no preamble).
	raw=$(cat "$_helper_out" 2>/dev/null || echo "")
	rm -f "$_helper_out"
	if [ "$_helper_rc" -ne 0 ]; then
		_err_excerpt=$(head -c 500 "$_helper_err" | tr '\n' ' ' | tr -d '"')
		_failure_mode=other
		case "$_helper_rc" in
		124) _failure_mode=timeout ;;
		137) _failure_mode=sigkill ;;
		139) _failure_mode=segfault ;;
		143) _failure_mode=sigterm ;;
		esac
		echo "phase0.5-codex: codex exec failed for agent=$agent (rc=$_helper_rc, mode=$_failure_mode): ${_err_excerpt:-<empty stderr>}" >&2
		jq -nc --arg ts "$TS" --arg sha "$SHA" --arg agent "$agent" --arg err "$_err_excerpt" \
			--argjson rc "$_helper_rc" --arg mode "$_failure_mode" \
			'{ts:$ts, sha:$sha, phase:"0.5", cli:"codex", agent:$agent, findings:0, status:"errored", helper_rc:$rc, failure_mode:$mode, stderr_excerpt:$err}' \
			>>"$LOG"
		# v4.28-W4 #716: collect for end-of-run auth heuristic
		ERRORED=$((ERRORED + 1))
		ERR_EXCERPTS="$ERR_EXCERPTS"$'\n'"$_err_excerpt"
		rm -f "$_helper_err"
		continue
	fi
	rm -f "$_helper_err"

	# (#2563 p1r1) Parse → salvage → stamp → count → log via the SHARED
	# helper in _lib/phase05-dedupe.sh — round 1 caught this prefilter
	# still discarding prose-wrapped arrays and passing agent-less
	# findings into dedup after the fix landed copilot-only. rc 1 = no
	# array recoverable (non-array-output row already logged).
	if ! cleaned=$(phase05_parse_and_log_findings "$raw" "$agent" "$TS" "$SHA" "$LOG" "codex"); then
		continue
	fi
	count=$(printf '%s' "$cleaned" | jq 'length')

	# Merge into ALL_FINDINGS.
	ALL_FINDINGS=$(jq -nc --argjson a "$ALL_FINDINGS" --argjson b "$cleaned" '$a + $b')
	TOTAL=$((TOTAL + count))
done

# v4.28-W5 #759: aggregated end-of-run summary via shared helper.
# (Was inlined per-launcher in #716; refactored here to share the auth-pattern
# regex + message format across codex/copilot/gemini.)
# shellcheck source=../_lib/phase05-auth-summary.sh
. "$(dirname "$0")/../_lib/phase05-auth-summary.sh"
phase05_emit_auth_summary "codex" "codex login" "$ERRORED" "$ATTEMPTED" "$ERR_EXCERPTS"

# (#2530) Backfill a run record when no codex-callable agent ran (diff
# matched only security-review — its unique .conf/.json extensions, e.g. a
# version bump — which the loop skips above) so ship-pr-cycle's phase0.5
# gate can advance.
phase05_log_no_reviewable_agents "codex" "$SHA" "$LOG" "$TS" "$ATTEMPTED"

# Two-stage dedup (#817 + #823 + #827): phase1-dedup → audit-dedup.
# (#2563 p1r1) _logged wrap: emit failures collapse to documented rc 1
# with an errored-emit row instead of leaking jq's rc through pipefail.
phase05_emit_findings_logged "$TOTAL" "$ALL_FINDINGS" "$DEDUP_HOOK" "$LOG" "$SHA" "$TS" || exit 1
