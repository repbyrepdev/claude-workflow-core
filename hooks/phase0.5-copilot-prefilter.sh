#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.24-R (#605) — Phase 0.5 Copilot free-tier pre-filter.
#
# For each agent defined in .claude/review-config.yml with a canonical_brief,
# render the brief against the current diff + invoke Copilot free-tier
# (gpt-4.1 / gpt-5-mini) via .claude/scripts/copilot/try-free.sh. Collect
# JSON findings, dedup via phase1-dedup.sh, emit actionable list.
#
# Zero Claude tokens. Runs BEFORE Claude Phase 1 — lets cheap model catch
# structural issues upfront. Scaler (phase1-scaler.sh) reads the output to
# decide Claude round count.
#
# OPTIONAL pre-filter (#2258): if the Copilot helper (scripts/copilot/
# try-free.sh) is genuinely absent, it logs a skip + emits [] + exits 0 so
# Phase 1 still runs; a BROKEN helper (resolver hard-error rc=2, or present
# but not executable) hard-fails loudly rather than skipping silently.
#
# Usage:
#   .claude/hooks/phase0.5-copilot-prefilter.sh [--base main]
#
# Output:
#   stdout: JSON array of dedup'd findings (may be [])
#   .claude/logs/phase0.5-run.jsonl: per-agent entry {ts, sha, agent, findings, status}
# Exit:
#   0 = ran successfully (findings may be present; caller decides) OR the
#       optional Copilot helper was absent → pre-filter skipped, emits []
#       (#2258 — keeps the canonical hook portable to consumers w/o Copilot)
#   1 = tooling error: review-config / dedup-hook / yq / jq missing;
#       list-phase1-agents.sh broken or crashed; OR a BROKEN Copilot helper
#       (resolver hard-error rc=2, or present-but-non-executable) — #2258
#   2 = arg error

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$REPO_ROOT" ] || {
	echo "phase0.5: must be run inside a git repo" >&2
	exit 2
}
cd "$REPO_ROOT" || exit 2

BASE="main"
SHA_PIN=""
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
	--sha)
		# CR-CI fix (#710 #711): pin to the commit SHA that triggered the
		# hook, NOT runtime `git rev-parse HEAD`. Without this, a 2nd
		# commit landing while the detached prefilter is still running
		# causes the prefilter to analyze the newer commit's diff —
		# logged under the wrong sha + skewing scaler / phase1 inputs.
		# r13 SFH fix: validate non-empty hex SHA (7-40 chars) so an
		# empty caller var or ref-name (HEAD/main/branch) typo hard-
		# fails instead of silently demoting to runtime HEAD — that
		# demotion would re-introduce the very race this fix prevents.
		[ "$#" -ge 2 ] || {
			echo "phase0.5: --sha requires value" >&2
			exit 2
		}
		[[ $2 =~ ^[0-9a-fA-F]{7,40}$ ]] || {
			echo "phase0.5: --sha must be a hex SHA (7-40 chars); got '$2'" >&2
			exit 2
		}
		SHA_PIN="$2"
		shift 2
		;;
	-h | --help)
		sed -n '4,25p' "$0"
		exit 0
		;;
	*)
		echo "phase0.5: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# v0.6.5 (#39): plugin-cache fallback for shared helpers. Lets consumer
# repos that don't ship their own .claude/scripts/ pull these from the
# plugin cache. Same pattern as v0.6.4 memory-drift-check alt_path.
PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
# shellcheck source=../_lib/resolve-plugin-helper.sh
. "$PLUGIN_LIB/resolve-plugin-helper.sh"

CONFIG="$(resolve_plugin_helper "review-config.yml" 2>/dev/null || echo "")"
# (#2258): capture the resolver rc so the deferred availability
# check (after the SHA/diff block) distinguishes a GENUINE absence (rc=1 →
# graceful-skip) from a resolver HARD-ERROR (rc=2 → plugin broken, hard-fail).
_copilot_rc=0
COPILOT_HELPER=$(resolve_plugin_helper "scripts/copilot/try-free.sh" 2>/dev/null) || _copilot_rc=$?
DEDUP_HOOK="$(dirname "$0")/phase1-dedup.sh"
LOG_DIR="$REPO_ROOT/.claude/logs"
LOG="$LOG_DIR/phase0.5-run.jsonl"

if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
	echo "phase0.5: review-config.yml missing (checked $REPO_ROOT/.claude/ + plugin cache)" >&2
	exit 1
fi
# (#2258): $COPILOT_HELPER + $_copilot_rc resolved above; the
# availability check is deferred to after the SHA/diff block (see below).
[ -x "$DEDUP_HOOK" ] || {
	echo "phase0.5: phase1-dedup.sh missing at $DEDUP_HOOK" >&2
	exit 1
}
# v4.28-W5 #827: 2-stage dedup wiring extracted to shared lib (was
# duplicated across copilot/codex/gemini). Preflight runs BEFORE invoking
# Copilot so a missing audit-dedup hook fails-loud instead of wasting CLI quota.
# CR-in-CI Phase 2 r3: source script-relative (dirname BASH_SOURCE) to
# match hook path-resolution contract (independent of REPO_ROOT detection).
# shellcheck source=../_lib/phase05-dedupe.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/phase05-dedupe.sh"
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
# CR-CI fix: prefer caller-pinned --sha over runtime HEAD for race-safety
# (see --sha arg parsing above). Falls back to `git rev-parse HEAD` when
# the caller didn't pin (e.g. manual operator invocation).
if [ -n "$SHA_PIN" ]; then
	SHA="$SHA_PIN"
else
	SHA=$(git rev-parse HEAD 2>"$_git_err" || echo "")
	[ -s "$_git_err" ] && echo "phase0.5: warning — git rev-parse stderr: $(cat "$_git_err")" >&2
fi
# v4.28-W3 r2 SFH F6: capture git diff stderr too — bad base ref or shallow
# clone would silently produce empty diff, hitting the "nothing to pre-filter"
# branch as if the diff were legitimately empty.
# CR-CI fix: diff against pinned SHA (or fall through to HEAD) rather than
# always-HEAD. Preserves the hook-time commit semantics under detach.
DIFF_REF="${SHA:-HEAD}"
DIFF_FILES_JOINED=$(git diff --name-only "${BASE}..${DIFF_REF}" 2>"$_git_err" | tr '\n' ' ' | sed 's/ $//')
[ -s "$_git_err" ] && echo "phase0.5: warning — git diff --name-only stderr: $(cat "$_git_err")" >&2
DIFF_CONTENT=$(git diff "${BASE}..${DIFF_REF}" 2>"$_git_err")
[ -s "$_git_err" ] && echo "phase0.5: warning — git diff stderr: $(cat "$_git_err")" >&2
trap - EXIT
rm -f "$_git_err"
# (#2258): the Copilot pre-filter is OPTIONAL, but degrade SAFELY —
# only a GENUINE absence skips; a broken plugin install must stay loud (a
# blanket graceful-skip would silently swallow a broken install — silent-
# failure-hunter HIGH). Four-way on $COPILOT_HELPER / $_copilot_rc:
#   rc=2 (resolver hard-error, e.g. plugin root unresolvable) → hard-fail.
#   helper present but not executable → hard-fail (broken install / bad perms).
#   empty + rc=0 (resolver reported success but returned no path = resolver
#     bug) → hard-fail (do NOT treat a resolver bug as a benign absence).
#   helper absent from BOTH local .claude/scripts/copilot/ AND the plugin
#     cache (empty, rc=1) → graceful-skip: log + emit [] + exit 0 so Phase 1
#     still runs (the consumer-portability path that unparks no-Copilot repos).
# jq (checked above), LOG_DIR (writable-checked), SHA are all ready here.
if [ "$_copilot_rc" -eq 2 ]; then
	echo "phase0.5: plugin-helper resolver hard-error (rc=2) resolving scripts/copilot/try-free.sh — plugin install likely broken; refusing to skip silently" >&2
	exit 1
fi
if [ -n "$COPILOT_HELPER" ] && [ ! -x "$COPILOT_HELPER" ]; then
	echo "phase0.5: Copilot helper $COPILOT_HELPER present but NOT executable — likely broken install (fix perms: chmod +x); refusing to skip silently" >&2
	exit 1
fi
if [ -z "$COPILOT_HELPER" ] && [ "$_copilot_rc" -eq 0 ]; then
	echo "phase0.5: resolver returned success (rc=0) but empty path for scripts/copilot/try-free.sh — resolver bug; plugin install likely broken; refusing to skip silently" >&2
	exit 1
fi
if [ -z "$COPILOT_HELPER" ]; then
	echo "phase0.5: Copilot helper absent from both $REPO_ROOT/.claude/scripts/copilot/ and the plugin cache — skipping optional pre-filter; Phase 1 Claude agents proceed" >&2
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$SHA" \
		'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:0, status:"skipped-no-copilot-helper"}' \
		>>"$LOG"
	echo "[]"
	exit 0
fi
if [ -z "$DIFF_CONTENT" ]; then
	echo "phase0.5: empty ${BASE}..${DIFF_REF} diff — nothing to pre-filter" >&2
	echo "[]"
	exit 0
fi

# Size guard — Copilot free-tier has a context window we can blow through
# on monster diffs. ~100KB (default) is well within gpt-4.1 limits after
# prompt overhead, but configurable via env for experimentation.
DIFF_MAX_BYTES="${PHASE05_DIFF_MAX_BYTES:-102400}"
diff_bytes=$(printf '%s' "$DIFF_CONTENT" | wc -c | tr -d ' ')
if [ "$diff_bytes" -gt "$DIFF_MAX_BYTES" ]; then
	echo "phase0.5: diff size ${diff_bytes}B exceeds PHASE05_DIFF_MAX_BYTES=${DIFF_MAX_BYTES} — skipping pre-filter (Phase 1 Claude agents handle large diffs)" >&2
	# Log skip so scaler sees 0 findings but knows Phase 0.5 didn't run.
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$SHA" \
		--argjson bytes "$diff_bytes" --argjson max "$DIFF_MAX_BYTES" \
		'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:0, status:"skipped-diff-too-large", diff_bytes:$bytes, max_bytes:$max}' \
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
		'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:0, status:"errored-list-agents-broken"}' \
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
		'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:0, status:"errored-list-agents-crashed", list_rc:$rc}' \
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
		'{ts:$ts, sha:$sha, phase:"0.5", agent:"<all>", findings:0, status:"skipped-no-agents-matched-diff", base:$base}' \
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
# for end-of-run auth-failure heuristic.
ERRORED=0
ATTEMPTED=0
ERR_EXCERPTS=""

for agent in $AGENTS; do
	# Skip security-review (invokes a Claude skill, not prompt-able via Copilot)
	# + semgrep (CLI, not agent — runs separately).
	case "$agent" in
	security-review | semgrep) continue ;;
	esac

	# v4.28-W4 #716: ATTEMPTED counts only copilot-callable agents (post-skip)
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
			'{ts:$ts, sha:$sha, phase:"0.5", agent:$agent, findings:0, status:"skipped-empty-canonical-brief"}' \
			>>"$LOG"
		continue
	fi

	# Placeholder substitution — matches phase1-launcher.sh semantics.
	brief=${brief//\{BASE_REF\}/$BASE}
	brief=${brief//\{HEAD_SHA\}/${SHA:0:12}}
	brief=${brief//\{ROUND\}/0.5}
	brief=${brief//\{DIFF_FILES\}/$DIFF_FILES_JOINED}

	# Tack on explicit output format contract so Copilot emits parseable JSON.
	full_prompt="$brief

DIFF TO REVIEW:
\`\`\`diff
$DIFF_CONTENT
\`\`\`

OUTPUT: Return ONLY a JSON array of findings (or []). Shape:
[{\"agent\": \"$agent\", \"file\": \"path\", \"line\": <int>, \"category\": \"<str>\", \"severity\": \"high|medium|low\", \"description\": \"<1 sentence>\", \"confidence\": <1-10>}]
No prose. No markdown fence. Just the array."

	# v4.28-W3 r2 SFH F3+F5: capture helper stderr so failures surface (auth,
	# rate-limit, network). Prior `2>/dev/null` masked all helper diagnostics
	# behind status=errored.
	# #223 r1: try-free.sh owns the per-model timeout (COPILOT_TIMEOUT_SEC,
	# default 150s). The prefilter no longer double-wraps in `timeout 60` — that
	# outer cap pre-empted try-free's own timeout AND capped the entire multi-
	# model fallback chain at 60s, timing out the agentic default model
	# (claude-sonnet-4.6) on real diffs (dogfood logged rc=124 for all 5 agents).
	_helper_err=$(mktemp)
	_helper_rc=0
	raw=$("$COPILOT_HELPER" "$full_prompt" </dev/null 2>"$_helper_err") || _helper_rc=$?
	if [ "$_helper_rc" -ne 0 ]; then
		_err_excerpt=$(head -c 500 "$_helper_err" | tr '\n' ' ' | tr -d '"')
		# v4.28-W3 r3 SFH: distinguish failure modes in audit log + always
		# surface to operator stderr (even on empty stderr — SIGKILL/timeout
		# produce no helper output but operator must still see the failure).
		_failure_mode=other
		case "$_helper_rc" in
		124) _failure_mode=timeout ;;  # GNU coreutils timeout fired
		137) _failure_mode=sigkill ;;  # 128+9 (kernel OOM, manual kill)
		139) _failure_mode=segfault ;; # 128+11
		143) _failure_mode=sigterm ;;  # 128+15
		esac
		echo "phase0.5: copilot helper failed for agent=$agent (rc=$_helper_rc, mode=$_failure_mode): ${_err_excerpt:-<empty stderr>}" >&2
		jq -nc --arg ts "$TS" --arg sha "$SHA" --arg agent "$agent" --arg err "$_err_excerpt" \
			--argjson rc "$_helper_rc" --arg mode "$_failure_mode" \
			'{ts:$ts, sha:$sha, phase:"0.5", agent:$agent, findings:0, status:"errored", helper_rc:$rc, failure_mode:$mode, stderr_excerpt:$err}' \
			>>"$LOG"
		# v4.28-W4 #716: collect for end-of-run auth heuristic
		ERRORED=$((ERRORED + 1))
		ERR_EXCERPTS="$ERR_EXCERPTS"$'\n'"$_err_excerpt"
		rm -f "$_helper_err"
		continue
	fi
	rm -f "$_helper_err"

	# Extract JSON array from output (Copilot sometimes wraps in markdown).
	# Strip fenced code block markers + leading/trailing whitespace.
	cleaned=$(printf '%s' "$raw" | sed -E 's/^```(json)?//' | sed -E 's/```$//' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
	# Validate it's a JSON array.
	if ! echo "$cleaned" | jq -e 'type == "array"' >/dev/null 2>&1; then
		# Copilot emitted non-array (refusal, explanation). Count as 0.
		jq -nc --arg ts "$TS" --arg sha "$SHA" --arg agent "$agent" \
			'{ts:$ts, sha:$sha, phase:"0.5", agent:$agent, findings:0, status:"non-array-output"}' \
			>>"$LOG"
		continue
	fi

	count=$(echo "$cleaned" | jq 'length')
	jq -nc --arg ts "$TS" --arg sha "$SHA" --arg agent "$agent" --argjson n "$count" \
		'{ts:$ts, sha:$sha, phase:"0.5", agent:$agent, findings:$n, status:"ok"}' \
		>>"$LOG"

	# Merge into ALL_FINDINGS.
	ALL_FINDINGS=$(jq -nc --argjson a "$ALL_FINDINGS" --argjson b "$cleaned" '$a + $b')
	TOTAL=$((TOTAL + count))
done

# v4.28-W5 #759: aggregated end-of-run summary via shared helper.
# shellcheck source=../_lib/phase05-auth-summary.sh
. "$(dirname "$0")/../_lib/phase05-auth-summary.sh"
phase05_emit_auth_summary "copilot" "copilot login" "$ERRORED" "$ATTEMPTED" "$ERR_EXCERPTS"

# Two-stage dedup (#817 + #823 + #827): phase1-dedup → audit-dedup.
# Wiring extracted to .claude/_lib/phase05-dedupe.sh (sourced above).
phase05_emit_findings "$TOTAL" "$ALL_FINDINGS" "$DEDUP_HOOK"
