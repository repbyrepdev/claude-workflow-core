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
# Implemented: repo, feature-branch.
# Unimplemented (return rc=69 with tracking-issue pointer): machine, plugin.
#
# Exit codes (stable contract):
#   0   success
#   1   dispatcher-level failure (orchestrated step refused or its
#       post-condition verify disagreed — see log for which step)
#   2   argparse error (missing/invalid --target, unknown flag) OR
#       per-target required-positional missing / extra args
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

# Per-target dispatch table. Implemented: repo, feature-branch. Machine
# and plugin remain stubs returning rc=69 (EX_UNAVAILABLE) with the
# tracking-issue pointer in the log line so a caller can grep the
# tracker if they hit it. Tracking refs are intentional in the
# user-facing message (operators need to know where the work is).
_dispatch_machine() {
	_log "ERROR: --target machine not yet implemented (tracking: meta-bootstrap machine flow, sub-issue of #78)"
	return 69
}
_dispatch_repo() {
	# Repo bootstrap orchestrator. Delegates to bootstrap-repo.sh (writes
	# files + applies labels) then runs --verify --scope both to confirm
	# completeness across plugin-scope + consumer-scope manifest entries.
	# Optional --verify-only short-circuits the bootstrap step and just
	# runs the verify pass. Verify is a separate pass (not bundled into
	# bootstrap-repo.sh) so --verify-only can reuse the same code path
	# without mutation.
	if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
		_log "ERROR: --target repo requires a target directory"
		_log "    usage: meta-bootstrap.sh --target repo <target-dir>"
		return 2
	fi
	if [ "$#" -gt 1 ]; then
		# Reject extra positional args explicitly. Silent-drop would mask
		# typos like `repo /tmp/x --force` where the operator expects a
		# flag to forward but it gets dropped.
		_log "ERROR: --target repo accepts exactly one positional argument (got $#)"
		return 2
	fi
	local target_dir=$1
	local script_dir
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	if [ "$VERIFY_ONLY" = "1" ]; then
		_log "running --verify --scope both against $target_dir (no mutation)"
		if ! "$script_dir/bootstrap-repo.sh" "$target_dir" --verify --scope both; then
			_log "ERROR: --verify-only failed for $target_dir — manifest files missing or labels unapplied"
			return 1
		fi
		_log "✓ --target repo --verify-only complete: $target_dir verified"
		return 0
	fi
	_log "running bootstrap-repo.sh against $target_dir..."
	if ! "$script_dir/bootstrap-repo.sh" "$target_dir"; then
		_log "ERROR: bootstrap-repo.sh failed; aborting before verify"
		return 1
	fi
	_log "running --verify --scope both to confirm completeness..."
	if ! "$script_dir/bootstrap-repo.sh" "$target_dir" --verify --scope both; then
		_log "ERROR: post-bootstrap verify failed — files missing or labels not applied"
		return 1
	fi
	_log "✓ --target repo complete: $target_dir bootstrapped + verified"
	return 0
}
_dispatch_plugin() {
	_log "ERROR: --target plugin not yet implemented (tracking: meta-bootstrap plugin flow, sub-issue of #78)"
	return 69
}
_dispatch_feature_branch() {
	# Pre-work SSOT prereq check. Each rule prints a remediation line on
	# failure so the operator can copy-paste a fix. All rules are read-
	# only; no mutation surface exists.
	#
	# Rules 2+3 (issue + labels) require gh on PATH; when gh is absent
	# they're skipped together AND the final verdict downgrades to
	# PARTIAL so a green light can't slip past silently.
	local rc=0 skipped=0
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
	# Rule 1: branch named per Conventional Commits type prefix + SemVer + issue-slug.
	# Anchored both ends; slug restricted to lowercase kebab-case to match the
	# repo's existing branch hygiene rules (orphan-branch sweep, etc).
	local branch_re='^(feat|fix|chore|docs|refactor|perf|test|build|ci|revert)/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?/[0-9]+-[a-z0-9][a-z0-9-]*$'
	local rule1_ok=1
	if [[ ! $branch =~ $branch_re ]]; then
		_log "✗ branch name not per convention: $branch"
		_log "    expected: <type>/vX.Y.Z/<issue-num>-<slug>"
		_log "    fix: git branch -m <type>/vX.Y.Z/<issue-num>-<slug>"
		rc=1
		rule1_ok=0
	fi
	# Rule 2 + Rule 3: only run when Rule 1 passed (so the issue-num
	# extraction is guaranteed to be a real issue reference, not garbage
	# from a malformed branch name).
	if [ "$rule1_ok" = "1" ]; then
		local issue_num
		issue_num=$(printf '%s' "$branch" | sed -E 's#^[^/]+/v[^/]+/([0-9]+)-.*#\1#')
		if ! command -v gh >/dev/null 2>&1; then
			_log "ℹ gh not on PATH — skipping Rules 2+3 (issue + labels)"
			skipped=$((skipped + 2))
		else
			local gh_err
			gh_err=$(mktemp -t feature-branch-gh.XXXXXX 2>/dev/null || echo "")
			if ! gh issue view "$issue_num" --json state >"${gh_err:-/dev/null}" 2>&1; then
				# Distinguish "issue not found" from "gh auth/network".
				if grep -q "not found\|Could not resolve" "${gh_err:-/dev/null}" 2>/dev/null; then
					_log "✗ branch references issue #$issue_num but issue not found on GitHub"
					_log "    fix: file the issue first via the github-issue-creation skill"
				else
					_log "✗ gh issue view failed for #$issue_num: $([ -n "$gh_err" ] && head -1 "$gh_err")"
					_log "    likely auth/network/rate-limit; retry after gh auth status"
				fi
				rc=1
			else
				local labels
				if ! labels=$(gh issue view "$issue_num" --json labels --jq '.labels[].name' 2>"${gh_err:-/dev/null}"); then
					_log "✗ gh issue view labels failed: $([ -n "$gh_err" ] && head -1 "$gh_err")"
					rc=1
				else
					# Require value after the prefix, not bare 'priority:' / 'area:'.
					if ! echo "$labels" | grep -qE "^priority:[a-z0-9]"; then
						_log "✗ issue #$issue_num missing a priority:* label"
						_log "    fix: gh issue edit $issue_num --add-label priority:p2"
						rc=1
					fi
					if ! echo "$labels" | grep -qE "^area:[a-z0-9]"; then
						_log "✗ issue #$issue_num missing an area:* label"
						_log "    fix: gh issue edit $issue_num --add-label area:infrastructure"
						rc=1
					fi
				fi
			fi
			[ -n "$gh_err" ] && rm -f "$gh_err"
		fi
	else
		# Rule 1 failed — skip Rules 2+3 (they'd query garbage).
		skipped=$((skipped + 2))
	fi
	# Rule 4: pre-commit hook installed in this working tree.
	if [ ! -f "$repo_root/.git/hooks/pre-commit" ]; then
		_log "✗ pre-commit hook not installed (.git/hooks/pre-commit missing)"
		_log "    fix: pre-commit install"
		rc=1
	fi
	# Rule 5 (advisory): tracking remote configured. Not gating.
	if ! git -C "$repo_root" config "branch.${branch}.remote" >/dev/null 2>&1; then
		_log "ℹ branch has no tracking remote yet — will be set on first push"
	fi
	if [ "$rc" -eq 0 ] && [ "$skipped" -eq 0 ]; then
		_log "✓ feature-branch prereqs satisfied: $branch"
	elif [ "$rc" -eq 0 ]; then
		_log "⚠ feature-branch PARTIAL: $skipped rule(s) skipped (install gh + re-run for full check)"
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
	feature-branch | repo) ;;
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
