#!/bin/bash
set -u
# v4.24-O (#601) — commit-time lint-gate.
# Refuses commit if any staged .sh / .bats / .yml / .yaml file has an
# unresolved lint issue at its current content hash (per
# .claude/logs/lint-run.jsonl).
# Mirrors bats-gate.sh's walk-log-by-content-hash pattern.
#
# Bypass: LINT_GATE_SKIP=1 LINT_GATE_SKIP_REASON="…" git commit ...

# shellcheck disable=SC2034  # REPO_ROOT kept for ABI; consumer-repo paths set via plugin-relative _lib lookup

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=../_lib/lint-gate-core.sh
source "$(dirname "$0")/../_lib/lint-gate-core.sh"

STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.(sh|bats|ya?ml)$' || true)
[ -z "$STAGED" ] && exit 0

# Pipe staged files list into the shared gate.
if ! printf '%s\n' "$STAGED" | lint_gate_run "lint-gate (commit)"; then
	exit 1
fi

exit 0
