#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# v4.27 (#632) — PreToolUse Bash gate that refuses Phase 1 launcher
# invocation until Phase 0.5 has logged a run for current HEAD.
#
# Mirrors phase0.5-before-cr.sh design (deny-JSON at exit 0 per v4.17.R).
#
# WHY: Phase 0.5 (Copilot free-tier prefilter) is declared mandatory in
# CLAUDE.md §5 and feeds the phase1-scaler tier decision — but was honor-
# system enforced for Phase 1 entry. Observed 2026-04-25 during PR #629:
# tools jumped straight to phase1-launcher.sh round 1 without running the
# Copilot prefilter first, causing the scaler to default-tier (no signals)
# and downstream gates to over-block. This gate closes the loop: no
# Phase 0.5 log for HEAD → no Phase 1 launcher.
#
# HOW: inspect `.tool_input.command` for `phase1-launcher.sh` invocations.
# Gate fires only on launcher calls, not on other phase1-* hooks. Looks up
# the full HEAD SHA in `.claude/logs/phase0.5-run.jsonl` (matches the same
# log + format the scaler reads, so a tier=clean scenario won't trip).
#
# ESCAPE HATCH: PHASE05_GATE_SKIP=1 (shared with phase0.5-before-cr.sh).
# Use when Phase 0.5 itself is broken or for the meta-PR that touches the
# prefilter script.

command -v jq >/dev/null 2>&1 || {
	echo "phase0.5-before-phase1: jq not found — cannot emit deny JSON, exiting" >&2
	exit 2
}

deny() {
	local reason="$1" json
	echo "phase0.5-before-phase1: $reason" >&2
	json=$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "phase0.5-before-phase1: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""'); then
	deny "payload unparseable — failing closed"
fi

# Match phase1-launcher.sh invocation. Uses the SSOT cmd-prefix regex
# helper (CR #634 round 3 fix — empty-value assignments + assignments-
# after-env were bypassing prior pattern; centralized in shared lib).
# Resolve lib via the hook's own dir so tests with mock TMPREPOs work.
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_lib/cmd-prefix-regex.sh
source "$HOOK_DIR/../_lib/cmd-prefix-regex.sh"
if ! printf '%s' "$CMD" | grep -qE "$(cmd_prefix_target 'phase1-launcher\.sh')"; then
	exit 0
fi

# Env override.
if [ "${PHASE05_GATE_SKIP:-0}" = "1" ]; then
	echo "phase0.5-before-phase1: PHASE05_GATE_SKIP=1 — bypassing gate" >&2
	exit 0
fi

# v4.29 #792: branch-graduation short-circuit. If branch graduated past
# Phase 0.5/1, allow phase1 invocation without re-running prefilter.
# CR PR #793 MAJOR: fail-closed on git rev-parse errors.
if ! _GRAD_REPO=$(git rev-parse --show-toplevel 2>&1); then
	deny "graduation repo resolution failed ($_GRAD_REPO) — failing closed"
fi
if ! _GRAD_BRANCH=$(git -C "$_GRAD_REPO" rev-parse --abbrev-ref HEAD 2>&1); then
	deny "graduation branch resolution failed ($_GRAD_BRANCH) — failing closed"
fi
_GRAD_LIB="$_GRAD_REPO/.claude/_lib/phase-graduation.sh"
if [ -r "$_GRAD_LIB" ] && [ -n "$_GRAD_BRANCH" ]; then
	# shellcheck source=/dev/null
	. "$_GRAD_LIB"
	if graduation_check "$_GRAD_BRANCH"; then
		echo "phase0.5-before-phase1: branch $_GRAD_BRANCH graduated past Phase 0.5/1 — allowing phase1 invocation" >&2
		exit 0
	fi
fi

# Resolve repo + current HEAD (full SHA — same encoding as Phase 0.5 log).
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	deny "not in a git repo — failing closed"
fi
# Distinguish fresh repo (zero commits, legitimate) from git errors (fail closed).
if SHA=$(git rev-parse HEAD 2>&1); then
	: # got a SHA
elif printf '%s' "$SHA" | grep -q "does not have any commits yet\|unknown revision\|bad revision"; then
	exit 0 # fresh repo with no commits — nothing to gate
else
	deny "git rev-parse HEAD failed ($SHA) — failing closed"
fi
[ -z "$SHA" ] && exit 0

LOG="$REPO_ROOT/.claude/logs/phase0.5-run.jsonl"
if [ ! -f "$LOG" ]; then
	deny "Phase 0.5 log not found — run .claude/hooks/phase0.5-copilot-prefilter.sh --base main before phase1-launcher.sh. Override: PHASE05_GATE_SKIP=1."
fi

# (#2563 p1r1 + p2r1) Require a TERMINAL row: this log doubles as the
# run-proof token, and per-agent ok rows are written BEFORE emission —
# a crashed emit leaves them behind, so counting them let a FAILED
# phase 0.5 unlock the phase-1 launcher for a sha whose findings were
# never emitted. Only status:"emitted" (written by
# phase05_emit_findings_logged after a successful emit) or a run-level
# skipped-* row proves the run.
if ! entries=$(jq -rs --arg s "$SHA" '[.[] | select(.sha==$s) | select((.status // "") as $st | $st == "emitted" or ($st | startswith("skipped")))] | length' "$LOG" 2>/dev/null); then
	echo "phase0.5-before-phase1: warning — failed to parse $LOG (malformed JSONL?); treating as no match" >&2
	entries=0
fi
if [ "$entries" = "0" ]; then
	deny "Phase 0.5 has no run logged for HEAD (${SHA:0:8}). Run .claude/hooks/phase0.5-copilot-prefilter.sh --base main first. Override: PHASE05_GATE_SKIP=1."
fi

exit 0
