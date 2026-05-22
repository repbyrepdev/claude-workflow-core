#!/bin/bash
set -u
# v4.29 #792 — phase-graduation marker library.
#
# Once a branch passes Phase 0.5 + Phase 1 (one clean round), those phases
# are DONE for that branch. New commits on the branch advance ONLY through
# Phase 2 + Phase 3. Replaces the per-SHA streak walker, which was the
# treadmill engine in PR #790 (6+ Phase 2 rounds + 11 Phase 1 rounds before
# operator forced PIPELINE_GATE_SKIP merge).
#
# Marker file: .claude/.session-state/phase-graduation/<safe-branch>.json
#   {
#     "branch": "<branch>",
#     "graduated_at": "<ISO8601>",
#     "graduated_sha": "<sha>",
#     "phase1_round": <round-number-that-converged>
#   }
#
# Functions (all source-and-call from caller hooks):
#   graduation_marker_path <branch>      → echoes the marker path
#   graduation_mark <branch> <sha> <r>   → writes the marker (rc=0 on success)
#   graduation_check <branch>            → rc=0 if graduated, 1 otherwise
#   graduation_invalidate <branch>       → removes the marker (rebase/force-push)

# Sanitize branch name for use as filename — `/` and other separators
# would create unexpected subdirectories. CR PR #793 MAJOR: append a
# short hash of the original branch name to disambiguate cases where
# distinct branches (`feat/a-b` vs `feat/a/b`) would otherwise collide
# to the same marker file after lossy `tr` replacement.
_grad_safe_branch() {
	local raw=${1:-}
	[ -n "$raw" ] || return 0
	local stripped
	stripped=$(printf '%s' "$raw" | tr -c '[:alnum:]_.-' '-')
	# Stable 8-char hash of the original branch — preserves readability
	# of `stripped` while preventing collision. shasum is POSIX; both
	# macOS BSD + Linux coreutils ship it. CR PR #793 r2 MAJOR: fail-closed
	# on shasum failure — fallback to unhashed name re-introduces the
	# collision the hash exists to prevent.
	local hash
	if ! hash=$(printf '%s' "$raw" | shasum | cut -c1-8); then
		echo "_grad_safe_branch: shasum not available or failed — collision prevention requires it (branch: $raw)" >&2
		return 1
	fi
	printf '%s-%s' "$stripped" "$hash"
}

graduation_marker_path() {
	local branch=${1:-}
	[ -n "$branch" ] || {
		echo "graduation_marker_path: branch required" >&2
		return 1
	}
	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
		echo "graduation_marker_path: not in a git repo" >&2
		return 1
	}
	local safe_branch
	safe_branch=$(_grad_safe_branch "$branch")
	[ -n "$safe_branch" ] || {
		echo "graduation_marker_path: branch sanitized to empty" >&2
		return 1
	}
	printf '%s/.claude/.session-state/phase-graduation/%s.json\n' "$repo_root" "$safe_branch"
}

graduation_check() {
	local branch=${1:-}
	local path
	path=$(graduation_marker_path "$branch") || return 1
	[ -f "$path" ]
}

graduation_mark() {
	local branch=${1:-}
	local sha=${2:-}
	local round=${3:-1}
	if [ -z "$branch" ] || [ -z "$sha" ]; then
		echo "graduation_mark: branch + sha required" >&2
		return 1
	fi
	local path
	path=$(graduation_marker_path "$branch") || return 1
	mkdir -p "$(dirname "$path")" 2>/dev/null || {
		echo "graduation_mark: cannot create marker dir" >&2
		return 1
	}
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	command -v jq >/dev/null || {
		echo "graduation_mark: jq not installed" >&2
		return 1
	}
	# code-reviewer Phase 1 r1 (conf 82): atomic write via tmp+mv so a
	# concurrent reader (pre-push gate / post-commit hooks) can't see a
	# partial JSON marker mid-write. Even though current readers only do
	# `[ -f "$path" ]`, JSON-consumer additions (telemetry) would race.
	local tmp="${path}.tmp.$$"
	if ! jq -nc --arg branch "$branch" --arg ts "$ts" --arg sha "$sha" --argjson r "$round" \
		'{branch: $branch, graduated_at: $ts, graduated_sha: $sha, phase1_round: $r}' \
		>"$tmp"; then
		rm -f "$tmp"
		echo "graduation_mark: jq write failed" >&2
		return 1
	fi
	if ! mv -f "$tmp" "$path"; then
		rm -f "$tmp"
		echo "graduation_mark: mv failed for $path" >&2
		return 1
	fi
}

graduation_invalidate() {
	local branch=${1:-}
	local path
	path=$(graduation_marker_path "$branch") || return 1
	# silent-failure-hunter conf 7: surface rm errors. Missing file is OK
	# (idempotent), but permission denied / read-only fs should NOT be silent.
	if [ -e "$path" ] && ! rm -f "$path"; then
		echo "graduation_invalidate: rm failed for $path" >&2
		return 1
	fi
}
