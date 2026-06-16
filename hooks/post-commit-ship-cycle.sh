#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W4 (#728): post-commit helper that fires `ship-pr-cycle.sh resume`
# after every successful `git commit`. Runs detached so it doesn't block
# the commit return.
#
# Wiring (one-time, per-clone — `.git/hooks/post-commit` is local-only):
#   cat >> .git/hooks/post-commit <<'EOF'
#   if [ -x "$(dirname "$0")/post-commit-ship-cycle.sh" ]; then
#       "$(dirname "$0")/post-commit-ship-cycle.sh" || true
#   fi
#   EOF
#
# Behavior:
#   1. Resolve current HEAD SHA.
#   2. Spawn `ship-pr-cycle.sh resume` detached (setsid + nohup).
#   3. Log invocation to .claude/logs/ship-cycle-resume.jsonl with sha + ts.
#   4. Exit 0 immediately — failures in the detached process don't block.
#
# Skip path: SHIP_CYCLE_POST_COMMIT_SKIP=1 in env disables the auto-fire
# (operator-controlled toggle, e.g. during commit-amend storms).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -z "$REPO_ROOT" ] && exit 0

if [ "${SHIP_CYCLE_POST_COMMIT_SKIP:-0}" = "1" ]; then
	exit 0
fi

# v0.34.81 (#2427): resolve the orchestrator via the shared SSOT lib instead of
# hardcoding "$REPO_ROOT/scripts/ship-pr-cycle.sh". In a CONSUMER that repo-root
# path is the STALE FROZEN driver — this hook auto-firing it on every commit
# emitted a stamp-less phase1 directive that ship-cycle-guard rejected: the
# unrecoverable 3-way deadlock of the 2026-06-16 re-pin saga. The resolver
# returns the plugin-local driver (plugin repo) OR the pinned-CACHE driver
# (consumer), so a consumer NEVER auto-fires a frozen copy. _lib is a sibling of
# hooks/ in both layouts (hooks/ → ../_lib; .claude/hooks/ → ../_lib). Best-
# effort: any resolution failure (no pin lib / no cached driver / non-exec) →
# exit 0 silently — this detached post-commit convenience must never block a
# commit, preserving the prior `[ -x ] || exit 0` no-op-on-missing behavior.
_LIB_RESOLVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" 2>/dev/null && pwd)/resolve-orchestrator.sh"
[ -r "$_LIB_RESOLVE" ] || exit 0
# shellcheck source=../_lib/resolve-orchestrator.sh
. "$_LIB_RESOLVE"
SCRIPT=$(resolve_ship_orchestrator "$REPO_ROOT" 2>/dev/null) || exit 0
[ -n "$SCRIPT" ] || exit 0

LOG_DIR="$REPO_ROOT/.claude/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/ship-cycle-resume.jsonl"

# Resolve SHA first — if rev-parse fails, exit 0 silently rather than
# log a half-empty record. Forensic readers expect every record to have
# a usable sha fingerprint.
SHA=$(git rev-parse HEAD 2>/dev/null) || exit 0
[ -z "$SHA" ] && exit 0
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH="<unresolved>"
[ -z "$BRANCH" ] && BRANCH="<unresolved>"

# Log the invocation (atomic single-line append, well under PIPE_BUF).
# Use jq to safely escape branch name — git allows characters that
# break naive JSON interpolation (e.g. `git checkout -b 'foo"bar'`).
jq -nc --arg ts "$TS" --arg sha "$SHA" --arg branch "$BRANCH" \
	'{ts:$ts, sha:$sha, branch:$branch, action:"fire-resume"}' >>"$LOG"

# v0.28.0 #174: post-commit sweep of phase1-directive markers whose SHA is
# NOT the current HEAD and is not reachable from any local ref. Each
# commit creates a new HEAD sha; markers for the prior sha are stranded
# (the prior sha may still exist as a danglable commit but no longer
# matches an active phase1 round). Sweep proactively to prevent
# accumulation. 2026-05-28: 34 markers accumulated across prior sessions
# in a peer repo (#174 Axis 2), blocking every tool call in a later session.
DIRECTIVE_DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
if [ -d "$DIRECTIVE_DIR" ]; then
	for f in "$DIRECTIVE_DIR"/*.phase1-directive.txt; do
		[ -f "$f" ] || continue
		_sha=$(basename "$f" .phase1-directive.txt)
		# Keep current HEAD's marker — it's the active phase1 round.
		[ "$_sha" = "$SHA" ] && continue
		# CR-SFH fix #5: validate basename is hex sha BEFORE for-each-ref
		# (skip editor swap files / .DS_Store that would error out the cmd).
		[[ $_sha =~ ^[0-9a-f]{7,40}$ ]] || continue
		# CR-SFH fix #5: separate RC from empty-output. for-each-ref FAILURE
		# (corrupt repo, perm denied, older git) was being treated as "sha
		# not reachable" → mass-rm of legitimate markers. Now: rc!=0 = WARN
		# + keep marker (fail-closed).
		_ref_err=$(mktemp)
		_ref_out=""
		_ref_rc=0
		_ref_out=$(git for-each-ref --contains "$_sha" --format='%(refname)' 2>"$_ref_err") || _ref_rc=$?
		if [ "$_ref_rc" -ne 0 ]; then
			echo "post-commit-ship-cycle: WARN for-each-ref rc=$_ref_rc for $_sha: $(head -c 200 "$_ref_err") — keeping marker" >&2
			rm -f "$_ref_err"
			continue
		fi
		rm -f "$_ref_err"
		if [ -z "$_ref_out" ]; then
			rm -f "$f" 2>/dev/null || echo "post-commit-ship-cycle: WARN rm failed for stale marker $f" >&2
		fi
	done
fi

# v0.34.81 (#2427): export SKILL_WRAPPER=1 so the detached orchestrator's
# internal gh / git-push / coderabbit calls aren't refused by skill-bypass-guard
# / ship-cycle-guard — matching the skill wrapper's contract (run.sh), now that
# post-commit resolves the SAME orchestrator via _lib/resolve-orchestrator.sh.
export SKILL_WRAPPER=1

# Detach: setsid + nohup so the resume call survives the commit's parent
# shell exit. stdout/stderr → log file for post-mortem inspection.
DETACH_LOG="$LOG_DIR/ship-cycle-resume-$(printf '%s' "$SHA" | head -c 8).log"
if command -v setsid >/dev/null 2>&1; then
	setsid nohup "$SCRIPT" resume >"$DETACH_LOG" 2>&1 </dev/null &
else
	# macOS lacks setsid by default; nohup + & is the best we can do.
	nohup "$SCRIPT" resume >"$DETACH_LOG" 2>&1 </dev/null &
fi
disown 2>/dev/null || true

exit 0
