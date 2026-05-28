#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Edit|Write|MultiEdit|NotebookEdit
# auto-register: true
# v0.7.1 (#23): stricter Phase 1 directive enforcement (partial #732 fix).
#
# WHY this exists: ship-pr-cycle.sh emits a Phase 1 directive ("fire 5
# parallel Agent calls") via stdout when `next` is invoked at the phase1
# stage. Today Claude can ignore that directive — summarize, stall, or
# fire Bash/Edit calls before the 5 Agents. The existing phase1-log-
# pending-gate fires AFTER agents return (forcing review-log.sh per
# agent), but there's no symmetric gate BEFORE agents fire.
#
# This hook closes the gap: when a Phase 1 round directive marker exists
# AND no Agent/Skill call has been observed yet for that round, the next
# non-Agent/Skill tool call is REFUSED with a directive-replay message.
#
# Marker location (re-uses existing ship-pr-cycle marker infrastructure):
#   .claude/.session-state/ship-cycle/<sha>.phase1-directive.txt
#   — written by ship-pr-cycle.sh `_write_phase1_directive_marker()` when
#   cmd_next emits the phase1 directive (#732 r2). Contains directive text.
#
# Cleared by ship-pr-cycle.sh `_clear_phase1_directive_marker()` when
# state advances past phase1.
#
# Bypass: PHASE1_DIRECTIVE_GUARD_SKIP=1 inline sentinel (audit-logged).

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DENY="$HOOK_DIR/../_lib/hook-deny.sh"
LIB_SENTINEL="$HOOK_DIR/../_lib/hook-inline-sentinel.sh"
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

# Outside-git-repo: allow (hook can fire anywhere). Capture stderr to
# distinguish "not a repo" from corruption.
git_err=$(mktemp)
git_rc=0
REPO_ROOT=$(git rev-parse --show-toplevel 2>"$git_err") || git_rc=$?
if [ "$git_rc" -ne 0 ]; then
	[ -s "$git_err" ] && echo "phase1-directive-pending-guard: git rev-parse failed (rc=$git_rc) — allowing call: $(head -c 200 "$git_err")" >&2
	rm -f "$git_err"
	exit 0
fi
rm -f "$git_err"

DIRECTIVE_DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
[ -d "$DIRECTIVE_DIR" ] || exit 0

# Find phase1-directive markers (existing ship-pr-cycle infrastructure).
# Use find with explicit rc capture (v0.6.5+ pattern). Pattern matches the
# `_phase1_directive_marker_file()` filename convention: `<sha>.phase1-directive.txt`.
find_err=$(mktemp)
find_out=$(mktemp)
find_rc=0
find "$DIRECTIVE_DIR" -maxdepth 1 -name '*.phase1-directive.txt' -print0 >"$find_out" 2>"$find_err" || find_rc=$?
if [ "$find_rc" -ne 0 ]; then
	hook_deny "phase1-directive-pending-guard" "find failed enumerating directive dir (rc=$find_rc) — fail-closed: $(head -c 200 "$find_err")"
fi
rm -f "$find_err"

pending_count=0
pending_list=""
while IFS= read -r -d '' f; do
	sha=$(basename "$f" .phase1-directive.txt)
	# v0.27.0 #173 Layer 1: self-heal stale markers whose SHA is now
	# reachable from origin/main. Catches merge-commit / fast-forward /
	# rebase-and-push-retaining-SHA flows. Squash-merge writes a NEW
	# commit on main, so the ORIGINAL topic-branch HEAD sha is NOT a
	# direct ancestor of main — Layer 1 will NOT clean those; Layer 2
	# (skill-side rm in github-pr-merge) catches squash-merges by
	# capturing the pre-merge HEAD sha + removing the marker before the
	# branch is deleted. Layer 3 (post-merge hook) provides cross-clone
	# coverage for non-squash paths the operator pulled from main.
	if git merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
		rm -f "$f"
		continue
	fi
	# v0.28.0 #174: also drop markers whose sha is no longer reachable
	# from ANY local ref (abandoned commits — branch deleted, commit
	# rebased away). 2026-05-28 observed 34 accumulating across prior
	# sessions in a peer repo (#174 Axis 2).
	# CR fix: validate hex-sha basename BEFORE for-each-ref (skip
	# editor swap files); separate rc from empty-output (rc!=0 keeps
	# marker rather than flipping `!` into mass-rm on git error).
	if [[ $sha =~ ^[0-9a-f]{7,40}$ ]]; then
		_ref_out=$(git for-each-ref --contains "$sha" --format='%(refname)' 2>/dev/null) && _ref_rc=0 || _ref_rc=$?
		if [ "$_ref_rc" -eq 0 ] && [ -z "$_ref_out" ]; then
			rm -f "$f"
			continue
		fi
	fi
	pending_count=$((pending_count + 1))
	pending_list="${pending_list}  - sha=$sha (directive emitted; agents not yet fired)
"
done <"$find_out"
rm -f "$find_out"

[ "$pending_count" -eq 0 ] && exit 0

# Read stdin to extract command for inline-sentinel bypass + tool detection.
if ! PAYLOAD=$(cat 2>/dev/null); then
	echo "phase1-directive-pending-guard: stdin read failed — allowing call" >&2
	exit 0
fi

# Extract tool name + command. If it's Agent or Skill, allow (those are what
# we want to fire). Other tool types refused until directive cleared.
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

case "$TOOL" in
Agent | Skill)
	# Allow Agent + Skill calls — those ARE the Phase 1 firing path.
	exit 0
	;;
esac

# Allow review-log.sh explicitly (the way to clear the directive after
# agents return). Mirrors phase1-log-pending-gate's escape hatch.
if printf '%s' "$CMD" | grep -qE '((^|[;&|][[:space:]]*)([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*)\.?/?\.claude/hooks/review-log\.sh'; then
	exit 0
fi

# Inline-sentinel bypass.
if hook_inline_sentinel_check "PHASE1_DIRECTIVE_GUARD_SKIP" "$CMD" "phase1-directive-pending"; then
	exit 0
fi

hook_deny "phase1-directive-pending-guard" \
	"$pending_count Phase 1 round directive(s) pending — fire Phase 1 agents BEFORE next non-Agent/Skill tool call:
$pending_list
Required action: fire the 5 parallel Agent calls (code-reviewer, code-simplifier,
comment-analyzer, pr-test-analyzer, silent-failure-hunter) + run semgrep + fire
Skill(security-review). See ship-pr-cycle.sh directive output for round number.

Bypass (audit-logged): PHASE1_DIRECTIVE_GUARD_SKIP=1 <cmd>"
