#!/bin/bash
set -euo pipefail
# event: SessionStart
# auto-register: true
# v0.28.0 (#174) — SessionStart sweep of stale phase1-directive markers
# across known repo roots. Prevents the lockout pattern observed
# 2026-05-28 where 34 markers accumulated across sessions, locking out
# every tool call until the user authorized PHASE1_DIRECTIVE_GUARD_SKIP.
#
# A marker is "stale" when its SHA is no longer reachable from ANY local
# ref in its host repo — i.e. the branch was deleted, the commit was
# squash-merged into another branch, or otherwise abandoned.
#
# Scope: scans the current repo's .claude/.session-state/ship-cycle/ AND
# any peer repos under $HOME matching `~/<name>` that contain the same
# dir layout. Conservative: never deletes a marker for a sha that's still
# reachable; never crosses into directories that aren't git repos.
#
# Bypass: SESSION_START_MARKER_SWEEP_SKIP=1 in env disables this sweep.

if [ "${SESSION_START_MARKER_SWEEP_SKIP:-0}" = "1" ]; then
	exit 0
fi

_sweep_repo() {
	local repo=$1
	local marker_dir="$repo/.claude/.session-state/ship-cycle"
	[ -d "$marker_dir" ] || return 0
	# Verify repo is a git repo + has any refs (fresh clones may have none).
	git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0

	local cleaned=0
	for f in "$marker_dir"/*.phase1-directive.txt; do
		[ -f "$f" ] || continue
		local sha
		sha=$(basename "$f" .phase1-directive.txt)
		# CR-SFH fix #1: validate basename is a hex sha BEFORE for-each-ref
		# to skip editor backup files / .DS_Store / swap files that would
		# error out for-each-ref and flip the `!` to mass-rm.
		[[ $sha =~ ^[0-9a-f]{7,40}$ ]] || continue
		# CR-SFH fix #2: separate RC from empty-output. Prior version
		# treated for-each-ref FAILURE (corrupt repo, perm denied, older
		# git rejecting --contains) the SAME as "sha not reachable" → mass-
		# rm. Now: on rc!=0, WARN + keep the marker (fail-closed for safety).
		local ref_err
		ref_err=$(mktemp)
		local ref_out ref_rc=0
		ref_out=$(git -C "$repo" for-each-ref --contains "$sha" --format='%(refname)' 2>"$ref_err") || ref_rc=$?
		if [ "$ref_rc" -ne 0 ]; then
			echo "session-start-marker-sweep: WARN for-each-ref rc=$ref_rc for $sha in $repo: $(head -c 200 "$ref_err") — keeping marker" >&2
			rm -f "$ref_err"
			continue
		fi
		rm -f "$ref_err"
		if [ -z "$ref_out" ]; then
			if rm -f "$f" 2>/dev/null; then
				cleaned=$((cleaned + 1))
			else
				echo "session-start-marker-sweep: WARN failed to rm $f" >&2
			fi
		fi
	done
	# (#2651) Approach-directive markers are BRANCH-keyed (nested under
	# branch/, suffix .approach-directive-emitted): one is stale when its
	# branch no longer resolves to a local head — deleted after merge, or
	# abandoned. Same fail-closed posture as the sha sweep above: a
	# show-ref ERROR (rc >= 2) keeps the marker; only a clean "no such
	# ref" (rc 1) clears it. Without this, markers accumulate per branch
	# forever and a stale one silently suppresses the checkpoint if a
	# branch name is ever recreated (phase1 r1).
	local bdir="$marker_dir/branch"
	if [ -d "$bdir" ]; then
		local bf branch sr_rc
		while IFS= read -r -d '' bf; do
			branch=${bf#"$bdir"/}
			branch=${branch%.approach-directive-emitted}
			[ -n "$branch" ] || continue
			sr_rc=0
			git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" || sr_rc=$?
			if [ "$sr_rc" -eq 0 ]; then
				continue
			fi
			if [ "$sr_rc" -ne 1 ]; then
				echo "session-start-marker-sweep: WARN show-ref rc=$sr_rc for branch '$branch' in $repo — keeping approach marker" >&2
				continue
			fi
			if rm -f "$bf" 2>/dev/null; then
				cleaned=$((cleaned + 1))
			else
				echo "session-start-marker-sweep: WARN failed to rm $bf" >&2
			fi
		done < <(find "$bdir" -type f -name '*.approach-directive-emitted' -print0 2>/dev/null)
	fi
	[ "$cleaned" -gt 0 ] && echo "session-start-marker-sweep: cleared $cleaned stale marker(s) in $repo" >&2
	return 0
}

# Sweep current repo first (always).
CURRENT_REPO=$(git rev-parse --show-toplevel 2>/dev/null) || CURRENT_REPO=""
if [ -n "$CURRENT_REPO" ]; then
	_sweep_repo "$CURRENT_REPO"
fi

# Sweep peer repos under $HOME — matches the MEMORY_DRIFT_EXTERNAL_ROOTS
# convention. Defaults to ~/media-server + ~/pricing-team-toolkit (same
# defaults as memory-drift-check.sh) when env unset.
PEER_ROOTS="${MARKER_SWEEP_PEER_ROOTS:-$HOME/media-server:$HOME/pricing-team-toolkit}"
IFS=':' read -ra _peers <<<"$PEER_ROOTS"
for _peer in "${_peers[@]}"; do
	[ -n "$_peer" ] || continue
	[ "$_peer" = "$CURRENT_REPO" ] && continue
	[ -d "$_peer" ] || continue
	_sweep_repo "$_peer"
done

exit 0
