#!/bin/bash
set -u
# event: PreToolUse
# matcher: Bash
# v4.24-O (#601) — PreToolUse Bash gate that refuses git commit / git push /
# scripts/test.sh / bats invocations while any branch-tracked .sh/.yml/.yaml
# still has unresolved lint issues at its current content hash.
#
# Mirrors pre-push-pipeline-gate's pattern of walking jsonl logs before
# gating a destructive/progression action. Same log
# (.claude/logs/lint-run.jsonl) as the commit-time gate — one source.
#
# Registered via ~/.claude/settings.json hooks.PreToolUse matcher=Bash.
# Exit 2 denies the tool use with stderr shown.

# v4.24-Q (#604): denial via shared hook_deny (JSON permissionDecision=
# deny + exit 0). Inline-sentinel bypass via shared hook_inline_sentinel_
# check — same pattern applied across all PreToolUse hooks. Resolve libs
# via the hook's own install dir so tmpdir/arbitrary-cwd invocation works.
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"
LIB_SENTINEL="${HOOK_DIR}/../_lib/hook-inline-sentinel.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi
if [ -f "$LIB_SENTINEL" ]; then
	# shellcheck source=../_lib/hook-inline-sentinel.sh
	source "$LIB_SENTINEL"
else
	hook_inline_sentinel_check() { return 1; }
fi

# Fail-closed on stdin/jq failures — prior `|| echo "{}"` silently coerced
# broken payloads to empty and bypassed the gate.
if ! PAYLOAD=$(cat 2>/dev/null); then
	hook_deny "lint-gate-bash" "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null); then
	hook_deny "lint-gate-bash" "hook payload not valid JSON — failing closed"
fi
# Empty command = no Bash call (some hook shapes pass empty payload); let
# the tool proceed normally.
[ -z "$CMD" ] && exit 0

# Inline-sentinel bypass via shared helper — PreToolUse hooks can't see
# inline env vars (see hook-inline-sentinel.sh for rationale).
if hook_inline_sentinel_check "LINT_GATE_SKIP" "$CMD" "lint-gate (bash)"; then
	exit 0
fi

# Scope: only guard known progression commands. Anchor `bats` to word-start
# so file paths like `foo.bats ` don't false-match.
case "$CMD" in
*"git commit"* | *"git push"* | *"scripts/test.sh"*) ;;
"bats "* | *" bats "*) ;;
*)
	exit 0
	;;
esac

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
[ -d "$REPO_ROOT" ] || exit 0
# shellcheck source=../_lib/lint-gate-core.sh
source "$(dirname "$0")/../_lib/lint-gate-core.sh"

# Hard pre-gate: repo must be in a sane state before we trust any git diff
# output. Mirrors the BASE-verify pattern applied in scripts/test-touched.sh
# (Round 1 fix) so a corrupt repo can't bypass the gate by yielding empty
# git diff output on every query.
if ! git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
	hook_deny "lint-gate-bash" "repo HEAD unresolvable — failing closed"
fi

# Track: files changed on branch (main..HEAD) + currently modified/staged.
# Fallback to staged-only when main ref isn't resolvable.
TRACKED=""
if git -C "$REPO_ROOT" rev-parse --verify main >/dev/null 2>&1; then
	# 2-dot (branch commits only) not 3-dot (symmetric diff including main-
	# only commits since fork point). We want files touched by this branch.
	TRACKED=$(git -C "$REPO_ROOT" diff --name-only main..HEAD 2>/dev/null || true)
fi
TRACKED=$(printf '%s\n%s\n%s' "$TRACKED" \
	"$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null || true)" \
	"$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || true)" |
	sort -u |
	grep -E '\.(sh|bats|ya?ml)$' |
	grep -v '^$' || true)

[ -z "$TRACKED" ] && exit 0

if ! printf '%s\n' "$TRACKED" | lint_gate_run "lint-gate (bash)" >&2; then
	hook_deny "lint-gate (bash)" "Tracked .sh/.bats/.yml have unresolved lint issues at current content hash. See stderr for per-file detail. Bypass: LINT_GATE_SKIP=1 LINT_GATE_SKIP_REASON=\"...\" <cmd>."
fi
exit 0
