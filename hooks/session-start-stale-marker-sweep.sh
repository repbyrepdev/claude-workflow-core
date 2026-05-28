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
		# Drop the marker only if the SHA is not reachable from any ref.
		# This is the conservative criterion — if the sha lives anywhere
		# (open branch, tag, stash, reflog tip), we keep the marker.
		if ! git -C "$repo" for-each-ref --contains "$sha" --format='%(refname)' 2>/dev/null | grep -q .; then
			if rm -f "$f" 2>/dev/null; then
				cleaned=$((cleaned + 1))
			fi
		fi
	done
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
