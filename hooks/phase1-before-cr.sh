#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# v4.15.A #489 — PreToolUse gate that blocks `coderabbit review` /
# `/coderabbit:review` invocations until Phase 1 is converged for HEAD.
#
# WHY: the pre-push-pipeline-gate (v4.3.F) fires at `git push` time —
# AFTER the prepaid CodeRabbit rate-limit bucket has been spent. The
# intended workflow (CLAUDE.md §5) is Phase 1 (N agents (per list-phase1-agents.sh) × ≥MIN_ROUNDS rounds
# until 2 consecutive all-agents-clean) THEN Phase 2 (CR CLI) THEN
# Phase 3 (CR-in-CI). Without a gate on Phase 2 invocation, the loop
# is honor-system + has been failing — observed 2026-04-20 across
# multiple PRs where I jumped to `coderabbit review` with 0-1 Phase 1
# agents run.
#
# HOW: on every Bash tool call, inspect the command. If it matches
# a CR-invocation pattern, read the review-log for current HEAD and
# require:
#   - at least MIN_ROUNDS (default 5) Phase 1 rounds logged
#   - each round includes ALL agents from list-phase1-agents.sh
#   - the last MIN_CLEAN_STREAK (default 2) rounds all return
#     findings=0 status=ok for every agent
# Exit 2 on fail with a concrete remediation message so Claude can
# catch up instead of fighting the gate.
#
# ESCAPE HATCH: set PHASE1_GATE_SKIP=1 in the environment for
# emergency bypass. Logged to stderr for visibility.
#
# NOT ENFORCED: accept-with-reason trailers — the gate doesn't look
# at them. If round MIN_ROUNDS+ disagrees with itself (2 agents
# contradict), that's a separate mechanism documented in CLAUDE.md.

# v4.27 (#632): MIN_ROUNDS sourced from phase1-scaler.sh tier output, not
# hardcoded 5. Prior hardcoded floor caused token waste — scaler tier could
# say 1 round on a clean diff but gate required 5 anyway, forcing 4 wasted
# rounds before CR CLI was allowed. Scaler integer is now the floor; env
# var override (PHASE1_MIN_ROUNDS) still wins for explicit pinning, and
# legacy default 5 is preserved as a safety net for missing/broken scaler.
# CR #634 finding 43: defer scaler execution until after the CR-command
# match. Calling phase1-scaler.sh on every Bash call (including the
# common non-CR fast-exit path) was needless hot-path latency.
SCALER_SCRIPT="$(dirname "$0")/phase1-scaler.sh"
_resolve_min_rounds() {
	local scaler_rounds=""
	if [ -x "$SCALER_SCRIPT" ]; then
		scaler_rounds=$("$SCALER_SCRIPT" 2>/dev/null) || scaler_rounds=""
	fi
	if [ -n "${PHASE1_MIN_ROUNDS:-}" ] && [[ "$PHASE1_MIN_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s\n' "$PHASE1_MIN_ROUNDS"
	elif [[ "$scaler_rounds" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s\n' "$scaler_rounds"
	else
		printf '5\n'
	fi
}
MIN_CLEAN_STREAK="${PHASE1_MIN_CLEAN_STREAK:-2}"

# v4.17.S: jq is load-bearing. Check at startup so a missing binary
# surfaces immediately. exit 2 is acceptable here — this is a pre-
# decision setup error (the deny() path can't function without jq), so
# the v4.17.R "exit 2 unreliable for blocking" concern doesn't apply.
command -v jq >/dev/null 2>&1 || {
	echo "phase1-before-cr: jq not found — cannot emit deny JSON, exiting" >&2
	exit 2
}

# v4.17.R (PR #511 CR): exit 2 is unreliable for blocking Bash tool
# in Claude Code (anthropics/claude-code issues #24327, #26923, #13756, #40580). Use
# exit 0 + JSON permissionDecision=deny + stderr audit log instead.
# v4.17.S: capture jq output to a variable first. errexit is suspended
# when deny() is called via `|| deny "..."`, so a runtime jq failure
# would otherwise let `exit 0` run with no JSON = silent pass-through.
# Fallback to exit 2 on jq failure (unreliable but strictly better).
deny() {
	local reason="$1" json
	echo "phase1-before-cr: $reason" >&2
	json=$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "phase1-before-cr: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

# Read the Claude Code hook payload from stdin — JSON containing the
# tool invocation details. On PreToolUse/Bash the relevant field is
# `.tool_input.command`.
# Fail-closed on stdin/parse errors: a malformed payload could otherwise
# produce empty CMD and silently bypass the gate. v4.15.I feedback fix.
# v4.17.AA: `if !` form instead of `|| deny` for clarity (CR #511 Phase 2).
if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""'); then
	deny "payload unparseable — failing closed"
fi

# v4.17.E: tightened regex — match `coderabbit review` ONLY as a command
# invocation (start-of-line / after `;`/`&&`/`||`/`|`), not as substring
# inside release notes, commit messages, grep patterns, etc. Prior regex
# false-positived on `gh release create --notes '...coderabbit review...'`
# and any \`gh issue create\` whose body mentioned the tool name.
#
# Match positions (anchored to command-start or shell-separator; POSIX
# `[[:space:]]` matches space/tab/newline/CR):
#   ^coderabbit[[:space:]]+review\b         — starts the command
#   [;&|][[:space:]]*coderabbit[[:space:]]+review\b — follows a separator
#   /coderabbit:review             — skill-style invocation. NOTE: this
#     alternative has NO anchor; it still matches inside strings
#     (e.g. --notes '.../coderabbit:review'). Acceptable tradeoff:
#     `/coderabbit:review` in a doc body is vanishingly rare whereas
#     tightening further would miss the actual skill invocation.
# Most quoted-string false-positives (release notes, commit messages)
# hit the `coderabbit review` alternative, which IS anchored.
if ! printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)coderabbit[[:space:]]+review([[:space:]]|$)|/coderabbit:review'; then
	exit 0
fi

# Env-override escape hatch
if [ "${PHASE1_GATE_SKIP:-0}" = "1" ]; then
	echo "phase1-before-cr: PHASE1_GATE_SKIP=1 — bypassing Phase 1 gate" >&2
	exit 0
fi

if ! REPO_ROOT=$(git rev-parse --show-toplevel); then
	deny "not in a git repo — failing closed"
fi
if ! cd "$REPO_ROOT"; then
	deny "cd $REPO_ROOT failed — failing closed"
fi

# v4.29 #792: branch-graduation short-circuit. If this branch already
# passed Phase 0.5/1 (marker exists), allow Phase 2 CR CLI invocation
# without re-running Phase 1 rounds. The graduation marker is the
# authoritative Phase 0.5/1 convergence signal; the round-count walk
# below was the per-SHA treadmill engine pre-#792.
GRAD_LIB="$(dirname "$0")/../_lib/phase-graduation.sh"
if [ -r "$GRAD_LIB" ]; then
	if ! GRAD_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>&1); then
		deny "graduation branch resolution failed ($GRAD_BRANCH) — failing closed"
	fi
	if [ -n "$GRAD_BRANCH" ]; then
		# shellcheck source=/dev/null
		. "$GRAD_LIB"
		if graduation_check "$GRAD_BRANCH"; then
			echo "phase1-before-cr: branch $GRAD_BRANCH graduated past Phase 0.5/1 — allowing Phase 2 CR CLI invocation" >&2
			exit 0
		fi
	fi
fi

# Distinguish "no HEAD yet" (fresh repo, legit) from "git failed" (fail closed).
if SHA=$(git rev-parse HEAD 2>&1); then
	: # got a SHA
elif printf '%s' "$SHA" | grep -q "does not have any commits yet\|unknown revision\|bad revision"; then
	exit 0 # fresh repo, nothing to gate
else
	deny "git rev-parse HEAD failed ($SHA) — failing closed"
fi
[ -z "$SHA" ] && exit 0

LOG=".claude/review-log/${SHA}.jsonl"
LIST_SCRIPT=".claude/hooks/list-phase1-agents.sh"

# v4.15.GG: per-HEAD log check removed. With v4.15.Y branch-aggregation,
# convergence is proven across ALL branch commits' logs via the collector —
# a fresh commit without a per-HEAD log is fine if branch history has
# converged rounds (the tuple walk accounts for every (sha, round)). Keep
# the malformed-JSONL check below for the HEAD log IF it exists.
if [ -f "$LOG" ] && ! jq empty "$LOG" >/dev/null 2>&1; then
	deny "$LOG malformed JSONL — repair or rm; failing closed"
fi

# 2. Gather expected agents from SSOT
if [ ! -x "$LIST_SCRIPT" ]; then
	deny "$LIST_SCRIPT missing or not executable — cannot determine expected agents"
fi
if ! EXPECTED=$("$LIST_SCRIPT" main | sort -u); then
	deny "list-phase1-agents.sh failed — failing closed"
fi
if [ -z "$EXPECTED" ]; then
	deny "list-phase1-agents.sh returned no agents — config broken?"
fi
EXPECTED_COUNT=$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')

# 3. v4.15.Y: aggregate logs across ALL commits on this branch since
# main, not just HEAD's log. Each commit resets HEAD's log but rounds
# persist as (sha, round) tuples — this lets MIN_ROUNDS=5 be
# satisfied across the branch's commit history.
COLLECT="$(dirname "$0")/_phase1-collect-logs.sh"
if [ ! -x "$COLLECT" ]; then
	deny "$COLLECT missing — failing closed"
fi
# v4.15.Z: capture collector exit + stderr surfacing (fail-closed).
if ! COMBINED=$("$COLLECT" main); then
	deny "collector exited non-zero — failing closed"
fi
if [ -n "$COMBINED" ] && ! printf '%s\n' "$COMBINED" | jq empty >/dev/null 2>&1; then
	deny "aggregated JSONL malformed — failing closed"
fi

# List invocations as "sha|round" tuples, oldest→newest (helper emits
# oldest-first); dedup while preserving order.
TUPLES=$(printf '%s\n' "$COMBINED" | jq -r 'select(.phase==1 and .round!=null) | "\(.sha)|\(.round)"' | awk '!seen[$0]++')
if [ -z "$TUPLES" ]; then
	ROUND_COUNT=0
else
	ROUND_COUNT=$(printf '%s\n' "$TUPLES" | wc -l | tr -d ' ')
fi

# Resolve MIN_ROUNDS lazily — only when actually needed (post CR-cmd match).
MIN_ROUNDS=$(_resolve_min_rounds)
if [ "$ROUND_COUNT" -lt "$MIN_ROUNDS" ]; then
	EXP_CSV=$(printf '%s\n' "$EXPECTED" | tr '\n' ',' | sed 's/,$//')
	deny "BLOCKED: only $ROUND_COUNT Phase 1 invocation(s) across branch since main. Minimum: ${MIN_ROUNDS}. Expected agents per round (${EXPECTED_COUNT}): ${EXP_CSV}. Run more rounds. Each round re-reviews the WHOLE diff (not just touched files). Override (emergency only): PHASE1_GATE_SKIP=1 <your-command>"
fi

# 4. Walk tuples newest-to-oldest; accumulate clean streak across commits.
CLEAN_STREAK=0
BROKEN_AT=""
for tuple in $(printf '%s\n' "$TUPLES" | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'); do
	tsha="${tuple%%|*}"
	tround="${tuple##*|}"
	RE=$(printf '%s\n' "$COMBINED" | jq -c --arg s "$tsha" --arg r "$tround" 'select(.phase==1 and .sha==$s and (.round|tostring)==$r)')
	LOGGED=$(printf '%s\n' "$RE" | jq -r '.agent' | sort -u)
	MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$LOGGED"))
	if [ -n "$MISSING" ]; then
		BROKEN_AT="invocation ${tsha:0:8}@round${tround}: missing agents: $(echo "$MISSING" | tr '\n' ',' | sed 's/,$//')"
		break
	fi
	# v4.28-W4 PR #755 r4: phase1-launcher.sh emits "log security-review
	# as 'security-review 0 not-installed'" when the skill isn't present;
	# treat that status the same as "ok" with 0 findings here so the gate
	# doesn't refuse convergence on an agent that physically can't run.
	# Other non-ok statuses (e.g. "err") still flag dirty.
	# v4.30 #772: also accept "not-applicable" as clean — launcher
	# auto-logs file-type-filtered agents (e.g. semgrep on .bats-only
	# diff) with this status so the gate accepts the round even when
	# not all 7 agents fired.
	DIRTY=$(printf '%s\n' "$RE" | jq -c 'select((.findings // 0) != 0 or (.status != "ok" and .status != "not-installed" and .status != "not-applicable"))')
	if [ -n "$DIRTY" ]; then
		BROKEN_AT="invocation ${tsha:0:8}@round${tround}: not all-clean"
		break
	fi
	CLEAN_STREAK=$((CLEAN_STREAK + 1))
	if [ "$CLEAN_STREAK" -ge "$MIN_CLEAN_STREAK" ]; then
		break
	fi
done

if [ "$CLEAN_STREAK" -lt "$MIN_CLEAN_STREAK" ]; then
	EXP_CSV=$(printf '%s\n' "$EXPECTED" | tr '\n' ',' | sed 's/,$//')
	deny "BLOCKED: Phase 1 not convergent — need ${MIN_CLEAN_STREAK} consecutive clean rounds, have ${CLEAN_STREAK}. Last break: ${BROKEN_AT:-unknown}. Expected agents per round (${EXPECTED_COUNT}): ${EXP_CSV}. Run another round: all expected agents on whole git diff main..HEAD. If a fix was just made, the fix file MUST be included in the next round's scope (entire diff, not just the fix). Override (emergency only): PHASE1_GATE_SKIP=1 <your-command>"
fi

# All checks passed — let the CR command proceed.
echo "phase1-before-cr: ✓ Phase 1 convergent (${ROUND_COUNT} rounds, streak=${CLEAN_STREAK}) — CR allowed" >&2
exit 0
