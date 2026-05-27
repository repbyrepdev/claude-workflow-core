#!/bin/bash
set -euo pipefail
# meta-bootstrap.sh — single entry point for every setup target.
#
# Replaces the fragmented "I forgot step X" failure mode by routing
# every target through one verified pipeline.
#
# Targets:
#   machine         — new dev machine setup
#   repo            — new consumer repo setup
#   plugin          — plugin release / cache prep
#   feature-branch  — pre-work SSOT prereq check
#
# Per-target logic lands in follow-up sub-issues; this skeleton handles
# flag parsing + dispatch. Unimplemented targets return rc=69 (per
# sysexits EX_UNAVAILABLE) with a tracking-issue pointer.
#
# Exit codes (stable contract):
#   0   success
#   2   argparse error (missing/invalid --target, unknown flag)
#   69  unimplemented target (matches sysexits EX_UNAVAILABLE; distinct
#       from the repo's rc=3 "refused due to malformed precondition"
#       used by register-hook.sh / ship-pr-cycle.sh / etc.)
#   70  internal dispatch-table bug (should be unreachable; defense in
#       depth in case a future TARGET addition skips the case statement)
#
# Usage:
#   scripts/meta-bootstrap.sh --target <machine|repo|plugin|feature-branch> [args...]
#   scripts/meta-bootstrap.sh --target X --verify-only
#   scripts/meta-bootstrap.sh --help

TARGET=""
VERIFY_ONLY=0
EXTRA_ARGS=()

_log() { echo "[meta-bootstrap] $*" >&2; }

_usage() {
	cat <<USAGE
usage: scripts/meta-bootstrap.sh --target <TARGET> [--verify-only] [-- <args>]

Targets:
  machine         New dev machine setup
  repo            New consumer repo bootstrap
  plugin          Plugin release / cache packaging
  feature-branch  Pre-work SSOT prereq check

Flags:
  --target T     Required. One of {machine, repo, plugin, feature-branch}.
  --verify-only  Run verification rules only; no mutation.
  --help, -h     Show this help.

Anything after \`--\` is forwarded to the target's underlying script.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		if [ $# -lt 2 ]; then
			echo "error: --target requires a value (machine|repo|plugin|feature-branch)" >&2
			exit 2
		fi
		TARGET="$2"
		shift 2
		;;
	--verify-only)
		VERIFY_ONLY=1
		shift
		;;
	-h | --help)
		_usage
		exit 0
		;;
	--)
		shift
		EXTRA_ARGS+=("$@")
		break
		;;
	-*)
		echo "error: unknown flag: $1" >&2
		_usage >&2
		exit 2
		;;
	*)
		EXTRA_ARGS+=("$1")
		shift
		;;
	esac
done

if [ -z "$TARGET" ]; then
	echo "error: --target is required" >&2
	_usage >&2
	exit 2
fi

case "$TARGET" in
machine | repo | plugin | feature-branch) ;;
*)
	echo "error: invalid --target: $TARGET (expected machine|repo|plugin|feature-branch)" >&2
	exit 2
	;;
esac

# Dispatch — per-target functions land in follow-up sub-issues. While
# unimplemented, each target returns rc=69 (EX_UNAVAILABLE) with a
# tracking-issue pointer in the log line so a caller can grep the
# tracker if they hit it. Tracking refs are intentional in the
# user-facing message (operators need to know where the work is).
_dispatch_machine() {
	_log "ERROR: --target machine not yet implemented (tracking: meta-bootstrap machine flow, sub-issue of #78)"
	return 69
}
_dispatch_repo() {
	_log "ERROR: --target repo not yet implemented (tracking: meta-bootstrap repo flow, sub-issue of #78)"
	return 69
}
_dispatch_plugin() {
	_log "ERROR: --target plugin not yet implemented (tracking: meta-bootstrap plugin flow, sub-issue of #78)"
	return 69
}
_dispatch_feature_branch() {
	# Pre-work SSOT prereq check. Each rule prints a remediation line on
	# failure so the operator can copy-paste a fix. rc reflects whether
	# every rule passed; --fix is a follow-up enhancement (today this
	# always behaves as --verify-only-equivalent: read-only inspection).
	local rc=0
	# Resolve repo + current branch.
	local repo_root
	if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
		_log "✗ not inside a git working tree — cd into a repo first"
		return 1
	fi
	local branch
	branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || echo "")
	if [ -z "$branch" ]; then
		_log "✗ no current branch (detached HEAD?) — checkout a feature branch"
		return 1
	fi
	# Rule 1: branch named per convention feat/vX.Y.Z/N-slug (or fix/, chore/, docs/ at the top level).
	if [[ ! $branch =~ ^(feat|fix|chore|docs|refactor|perf|test|build|ci|revert)/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?/[0-9]+-.+ ]]; then
		_log "✗ branch name not per convention: $branch"
		_log "    expected: <type>/vX.Y.Z/<issue-num>-<slug>  (type: feat|fix|chore|docs|...)"
		_log "    fix: git branch -m <type>/vX.Y.Z/<issue-num>-<slug>"
		rc=1
	fi
	# Rule 2: linked issue exists.
	local issue_num
	issue_num=$(printf '%s' "$branch" | sed -E 's#^[^/]+/v[^/]+/([0-9]+)-.*#\1#')
	if [ -n "$issue_num" ] && [ "$issue_num" != "$branch" ]; then
		if ! command -v gh >/dev/null 2>&1; then
			_log "ℹ gh not on PATH — skipping issue-existence + label checks"
		elif ! gh issue view "$issue_num" --json state >/dev/null 2>&1; then
			_log "✗ branch references issue #$issue_num but issue not found on GitHub"
			_log "    fix: file the issue first via .claude/skills/github-issue-creation/run.sh"
			rc=1
		else
			# Rule 3: required labels (priority:* + area:*) on the issue.
			local labels
			labels=$(gh issue view "$issue_num" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
			if ! echo "$labels" | grep -qE "^priority:"; then
				_log "✗ issue #$issue_num missing a priority:* label"
				_log "    fix: gh issue edit $issue_num --add-label priority:p2"
				rc=1
			fi
			if ! echo "$labels" | grep -qE "^area:"; then
				_log "✗ issue #$issue_num missing an area:* label"
				_log "    fix: gh issue edit $issue_num --add-label area:infrastructure"
				rc=1
			fi
		fi
	fi
	# Rule 4: pre-commit hook installed in this working tree.
	if [ ! -f "$repo_root/.git/hooks/pre-commit" ]; then
		_log "✗ pre-commit hook not installed (.git/hooks/pre-commit missing)"
		_log "    fix: pre-commit install"
		rc=1
	fi
	# Rule 5: tracking remote configured.
	if ! git -C "$repo_root" config "branch.${branch}.remote" >/dev/null 2>&1; then
		# Not yet pushed/tracked — informational, not a hard failure.
		_log "ℹ branch has no tracking remote yet — will be set on first push"
	fi
	if [ "$rc" -eq 0 ]; then
		_log "✓ feature-branch prereqs satisfied: $branch"
	else
		_log "✗ feature-branch verify FAILED — address each ✗ above before starting work"
	fi
	return "$rc"
}

# --verify-only honored per-target:
#   feature-branch — all checks are read-only by design; --verify-only is the
#     default behavior (no mutation surface). Allow it through.
#   machine/repo/plugin — verify hooks land in follow-up subs; refuse for now
#     so silent mutation can't slip in when those subs ship.
if [ "$VERIFY_ONLY" = "1" ]; then
	case "$TARGET" in
	feature-branch) ;;
	*)
		_log "ERROR: --verify-only not yet wired for --target $TARGET (sub-issue of #78 adds per-target verify hooks)"
		exit 69
		;;
	esac
fi

_log "running target: $TARGET"

# set -u-safe expansion: when EXTRA_ARGS is empty pass zero args, not
# one empty-string. Future dispatchers will rely on arg-count accuracy.
case "$TARGET" in
machine) _dispatch_machine ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
repo) _dispatch_repo ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
plugin) _dispatch_plugin ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
feature-branch) _dispatch_feature_branch ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
*)
	# Defense in depth — unreachable given the validator above, but
	# catches a future case-label drift that skipped the validator
	# update.
	_log "ERROR: dispatch table missing case for $TARGET (internal bug)"
	exit 70
	;;
esac
