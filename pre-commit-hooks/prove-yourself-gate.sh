#!/bin/bash
set -euo pipefail
# v4.28-W2 (#645): pre-commit gate that blocks commit when prove-yourself
# rejection records are malformed or missing evidence. Delegates to the
# skill's `check-commit` subcommand so the validation rules live in one
# place (the skill).
#
# WHY: PR #639 r1-r5 (NUL stripping) + r17-r23 (gpt-5-codex) shipped 5
# false-rejection commits past CR review because rejection-with-evidence
# was discipline-only. This gate makes evidence not-optional at commit.
#
# Bypass (audit-logged): PROVE_YOURSELF_GATE_SKIP=1 git commit ...

# Fall back to pwd when not in a git repo — matches the skill's own
# REPO_ROOT resolution so test invocation in a non-git tmpdir behaves
# the same as a real pre-commit invocation.
#
# Phase 2 cr-cli r3 (#645): distinguish "not a git repo" (legit fallback
# to pwd for tests) from "git rev-parse errored despite .git present"
# (real broken-repo state — fail-loud rather than silently mask).
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>&1); then
	if [ -d ".git" ]; then
		echo "prove-yourself-gate: git rev-parse failed in apparent git repo: $REPO_ROOT" >&2
		exit 1
	fi
	REPO_ROOT=$(pwd)
fi
[ -d "$REPO_ROOT" ] || {
	echo "prove-yourself-gate: REPO_ROOT not a directory: $REPO_ROOT" >&2
	exit 1
}

# Bypass support — symmetric with LINT_GATE_SKIP, DOGFOOD_GATE_SKIP etc.
if [ "${PROVE_YOURSELF_GATE_SKIP:-0}" = "1" ]; then
	# Audit-log the bypass. -c (compact) is REQUIRED for JSONL — pretty-
	# print would break tail -n1 semantics for downstream `jq -e .` tests.
	mkdir -p "$REPO_ROOT/.claude/logs"
	jq -nc \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg reason "${PROVE_YOURSELF_GATE_SKIP_REASON:-no-reason}" \
		'{ts: $ts, reason: $reason}' \
		>>"$REPO_ROOT/.claude/logs/prove-yourself-gate-skip.jsonl"
	echo "prove-yourself-gate: bypass via PROVE_YOURSELF_GATE_SKIP=1 — audit-logged" >&2
	exit 0
fi

# Resolve skill via the gate's own location, not REPO_ROOT — so a non-
# git invocation (e.g. bats test in a tmpdir) still finds the skill at
# its install path. Without this, the gate would silently no-op when
# called from outside the repo's worktree.
#
# PROVE_YOURSELF_SKILL env override lets bats tests point at a non-
# existent path to exercise the fail-closed branch (without that, the
# real-repo skill is always present + the test couldn't reach this path).
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
SKILL="${PROVE_YOURSELF_SKILL:-$HOOK_DIR/../skills/prove-yourself-audit/run.sh}"
if [ ! -x "$SKILL" ]; then
	echo "prove-yourself-gate: skill not found or not executable: $SKILL" >&2
	exit 1
fi

# Delegate to skill for record-shape validation. Exit 0 = no malformed.
# r2 code-reviewer #1: AGENTS.md rc-capture rule — `cmd; rc=$?` aborts
# under set -e (the script's `set -euo pipefail` was off here, but the
# pattern bypassed correctness anyway). Use `|| rc=$?` so the explicit
# branch always runs.
SKILL_RC=0
"$SKILL" check-commit || SKILL_RC=$?
[ "$SKILL_RC" -ne 0 ] && exit "$SKILL_RC"

# v4.28-W3-C: per-finding coverage enforcement. Legacy `check-commit`
# only validates record SHAPE, not COUNT. Operator could ignore agent
# findings entirely and commit. Now: for the latest Phase 1 round in
# .claude/review-log/<HEAD>.jsonl, sum findings across all phase=1
# entries for that round → N. Sum covers_count from prove-yourself
# state files filed AFTER round-start AND with source==phase1 (or
# missing source for legacy back-compat) → R. R<N blocks. Time-window
# scoping prevents prior-PR records from giving every commit a free
# pass. Source-filter prevents cr/phase0.5 records from satisfying
# the phase1 gate.
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) || exit 0
RLOG="$REPO_ROOT/.claude/review-log/${HEAD_SHA}.jsonl"
[ -f "$RLOG" ] || exit 0

LATEST_ROUND=$(jq -r 'select(.phase==1 and .round!=null) | .round' "$RLOG" 2>/dev/null |
	sort -un | tail -1)
[ -n "$LATEST_ROUND" ] || exit 0

ROUND_FINDINGS=$(jq -r --arg r "$LATEST_ROUND" \
	'select(.phase==1 and (.round|tostring)==$r) | (.findings // 0)' "$RLOG" 2>/dev/null |
	awk '{s+=$1} END {print s+0}')
[ "$ROUND_FINDINGS" -gt 0 ] || exit 0

# Time-window scoping: only records filed since the latest round started
# count toward coverage. Prior PRs' records (76+ accumulated over time)
# would otherwise give every commit a free pass.
ROUND_START_TS=$(jq -r --arg r "$LATEST_ROUND" \
	'select(.phase==1 and (.round|tostring)==$r) | .ts' "$RLOG" 2>/dev/null |
	sort | head -1)
[ -n "$ROUND_START_TS" ] || exit 0

PSTATE_DIR="$REPO_ROOT/.claude/.session-state/prove-yourself"
COVERS_TOTAL=0
if [ -d "$PSTATE_DIR" ]; then
	# v4.28-W3-C r5 (CR #3): filter records by source==phase1. Without
	# the source filter, --source cr or --source phase0.5 records would
	# falsely satisfy the Phase 1 coverage gate. Records without a source
	# field (legacy, pre-W3-C) count as phase1 since that was the only
	# source before the field was introduced.
	COVERS_TOTAL=$(find "$PSTATE_DIR" -name '*.json' -exec cat {} \; 2>/dev/null |
		jq -s --arg cutoff "$ROUND_START_TS" \
			'map(select(.ts >= $cutoff and ((.source // "phase1") == "phase1")) | .covers_count // 1) | add // 0' \
			2>/dev/null || echo 0)
fi

if [ "$COVERS_TOTAL" -lt "$ROUND_FINDINGS" ]; then
	echo "" >&2
	echo "prove-yourself-gate: per-finding coverage enforcement (v4.28-W3-C)" >&2
	echo "  Latest Phase 1 round $LATEST_ROUND at $HEAD_SHA: $ROUND_FINDINGS findings" >&2
	echo "  Prove-yourself records cover: $COVERS_TOTAL" >&2
	echo "  Need $((ROUND_FINDINGS - COVERS_TOTAL)) more covered before commit." >&2
	echo "" >&2
	echo "  Per-finding:    skills/prove-yourself-audit/run.sh record-{fix,rejection}" >&2
	echo "                    --finding-text ... [--covers-count N for bulk]" >&2
	echo "                  A record-fix citing a CYCLE-CRITICAL file (hooks/, _lib/," >&2
	echo "                  pre-commit-hooks/, scripts/cr/local-review.sh) also needs the" >&2
	echo "                  #2643 symptom differential, or it exits 2:" >&2
	echo '                    --symptom-cmd "..." --symptom-baseline-rc N --symptom-fixed-rc M' >&2
	echo "                  (N != M; both are re-executed. Already committed? add" >&2
	echo "                  --baseline-ref <sha-before-the-fix>. See run.sh --help.)" >&2
	echo "  Bypass:         PROVE_YOURSELF_GATE_SKIP=1 git commit ... (audit-logged)" >&2
	# r5 #676 expansion: append to universal sentinel for single-pane visibility.
	LIB_HOOK_ACK="$(dirname "$0")/../_lib/hook-ack.sh"
	# shellcheck source=../_lib/hook-ack.sh
	[ -f "$LIB_HOOK_ACK" ] && source "$LIB_HOOK_ACK"
	command -v hook_ack_append >/dev/null 2>&1 &&
		hook_ack_append "prove-yourself-gate" \
			"r${LATEST_ROUND}-coverage-gap-${ROUND_FINDINGS}-vs-${COVERS_TOTAL}" \
			"$RLOG"
	exit 1
fi

# v4.29 #792: graduation — a round with findings counts as CLEAN when every
# finding has a coverage record (fix-commit OR rejection-with-evidence).
# That's exactly the contract this gate just validated. Write the marker so
# Phase 0.5/1 won't re-run on future commits to this branch.
# User directive 2026-05-11: "deferring is fine but should count the round
# clean ... run phase, triage findings, dogfood rejections, commit actual
# changes, consider graduated to next phase."
GRAD_LIB="$(dirname "$0")/../_lib/phase-graduation.sh"
# CR PR #793 r2 MINOR: warn-and-continue (not exit 2) on graduation
# branch resolution failure. The main coverage gate already passed —
# graduation is an optimization, and review-log.sh uses the same warn-
# and-continue pattern. exit 2 is reserved for usage errors anyway.
GRAD_BRANCH=""
if ! GRAD_BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>&1); then
	echo "prove-yourself-gate: WARN: graduation branch resolution failed ($GRAD_BRANCH) — marker NOT written (commit still allowed; future commits may re-run Phase 0.5/1)" >&2
	GRAD_BRANCH=""
fi
if [ -r "$GRAD_LIB" ] && [ -n "$GRAD_BRANCH" ]; then
	# shellcheck source=../_lib/phase-graduation.sh
	. "$GRAD_LIB"
	if graduation_mark "$GRAD_BRANCH" "$HEAD_SHA" "$LATEST_ROUND"; then
		echo "prove-yourself-gate: round $LATEST_ROUND addressed ($ROUND_FINDINGS findings covered) — branch $GRAD_BRANCH graduated past Phase 0.5/1" >&2
	else
		echo "prove-yourself-gate: WARN: graduation_mark failed (rc=$?) — marker NOT written; future commits will re-run Phase 0.5/1" >&2
	fi
fi

exit 0
