#!/bin/bash
# event: PreToolUse
# matcher: Bash
# v4.24-O2 (#612) — PreToolUse gate: block `coderabbit review` invocations
# until Phase 0.5 (Copilot prefilter) has logged a run for current HEAD.
# Mirrors the phase1-before-cr.sh design (deny-JSON at exit 0 per v4.17.R).
#
# WHY: Phase 0.5 is declared mandatory in CLAUDE.md §5 but was honor-
# system enforced. Observed 2026-04-24: 3 PRs in a row (#608, #611, v4.24-G)
# jumped straight to CR CLI without running the free Copilot prefilter,
# burning CR budget on issues Copilot would have caught in 0 tokens.
#
# HOW: inspect `.claude/logs/phase0.5-run.jsonl` for an entry matching
# current HEAD (short SHA). No entry → refuse CR invocation. Entry
# present → pass. Phase 0.5 findings that were NOT applied are a
# separate concern; this gate only enforces "Phase 0.5 ran at all."
#
# ESCAPE HATCH: set PHASE05_GATE_SKIP=1 in env for emergency bypass.

set -euo pipefail

command -v jq >/dev/null 2>&1 || {
	echo "phase0.5-before-cr: jq not found — cannot emit deny JSON, exiting" >&2
	exit 2
}

deny() {
	local reason="$1" json
	echo "phase0.5-before-cr: $reason" >&2
	json=$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "phase0.5-before-cr: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

# Stdin payload.
if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""'); then
	deny "payload unparseable — failing closed"
fi

# Same command-detection regex as phase1-before-cr (drift guard caught
# by its existing bats tests — keep these in sync).
if ! printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)coderabbit[[:space:]]+review([[:space:]]|$)|/coderabbit:review'; then
	exit 0
fi

# Env override.
if [ "${PHASE05_GATE_SKIP:-0}" = "1" ]; then
	echo "phase0.5-before-cr: PHASE05_GATE_SKIP=1 — bypassing Phase 0.5 gate" >&2
	exit 0
fi

# Resolve repo + current HEAD.
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	deny "not in a git repo — failing closed"
fi

# v4.29 #792: branch-graduation short-circuit. If this branch already
# passed Phase 0.5/1 (marker exists), allow Phase 2 CR CLI invocation
# without re-running Phase 0.5 on every new HEAD.
GRAD_LIB="$(dirname "$0")/../_lib/phase-graduation.sh"
if [ -r "$GRAD_LIB" ]; then
	if ! GRAD_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>&1); then
		deny "graduation branch resolution failed ($GRAD_BRANCH) — failing closed"
	fi
	if [ -n "$GRAD_BRANCH" ]; then
		# shellcheck source=/dev/null
		. "$GRAD_LIB"
		if graduation_check "$GRAD_BRANCH"; then
			echo "phase0.5-before-cr: branch $GRAD_BRANCH graduated past Phase 0.5/1 — allowing Phase 2 CR CLI invocation" >&2
			exit 0
		fi
	fi
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
	deny "Phase 0.5 log not found — run .claude/hooks/phase0.5-copilot-prefilter.sh before CR CLI. Override: PHASE05_GATE_SKIP=1."
fi

# Look for an entry matching current full SHA. v4.27 (#632) fix: prior
# implementation used `git rev-parse --short HEAD` (7 chars) but the
# prefilter logs full 40-char SHAs — exact-match `==` always failed,
# blocking CR CLI even when Phase 0.5 had run cleanly. Switched to full
# SHA comparison so the gate now correctly recognizes valid Phase 0.5 runs.
# (#2563 p1r1) Exclude errored-* rows: this log doubles as the run-proof
# token, and the errored-emit row means "this round's findings were NOT
# emitted" — counting it would let a FAILED phase 0.5 unlock CR-CLI for
# a sha whose review produced nothing (same for errored-list-agents-*).
# Skipped-* rows still count: a documented skip IS a completed run.
if ! entries=$(jq -rs --arg s "$SHA" '[.[] | select(.sha==$s) | select((.status // "ok") | startswith("errored") | not)] | length' "$LOG" 2>/dev/null); then
	echo "phase0.5-before-cr: warning — failed to parse $LOG (malformed JSONL?); treating as no match" >&2
	entries=0
fi
if [ "$entries" = "0" ]; then
	deny "Phase 0.5 has no run logged for HEAD (${SHA:0:8}). Run .claude/hooks/phase0.5-copilot-prefilter.sh. Override: PHASE05_GATE_SKIP=1."
fi

exit 0
