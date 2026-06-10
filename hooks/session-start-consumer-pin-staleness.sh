#!/bin/bash
set -euo pipefail
# event: SessionStart
# auto-register: true
# Introduced in #2280 — SessionStart hook warning when THIS consumer repo's
# pinned plugin rev is behind the latest installed plugin release.
#
# Why: a consumer pins claude-workflow-core in .pre-commit-config.yaml
# (`rev: vX.Y.Z`). When the plugin ships a new release, the release cascade
# files a "refresh from vY" issue — but if that issue is ignored, nothing
# reminds the operator the next time they work in the stale consumer. This
# hook surfaces the drift at session start (advisory, never blocks).
#
# Distinct from session-start-stale-pin.sh (#89), which checks the operator's
# ~/.claude/settings.json cache-PATH refs vs the on-disk cache. This one
# checks the CONSUMER REPO's own .pre-commit-config plugin pin vs the cache.
#
# Behavior: pure ADVISORY (exit 0 always). Reads the repo-root .pre-commit-config.yaml,
# extracts the rev pinned for repbyrepdev/claude-workflow-core, compares to the
# highest plugin-cache version dir, warns on drift (both directions).
#
# Env vars:
#   SESSION_START_CONSUMER_PIN_SKIP=1     — bypass entirely
#   SESSION_START_CONSUMER_PIN_CONFIG     — override .pre-commit-config path (test)
#   SESSION_START_CONSUMER_PIN_CACHE_DIR  — override plugin cache dir (test)
#
# Limitations (DOCUMENTED, not bugs):
#   - Matches semver X.Y.Z only; pre-release suffixes (X.Y.Z-rc1) are not
#     extracted, matching the #89 sibling and the plugin's release flow.
#   - Reads the FIRST claude-workflow-core rev in the config (a config pins
#     the plugin once).
#
# Exit codes: 0 — always (advisory hook; never block session start).

if [ "${SESSION_START_CONSUMER_PIN_SKIP:-0}" = "1" ]; then
	exit 0
fi

if [ -n "${SESSION_START_CONSUMER_PIN_CONFIG:-}" ]; then
	CONFIG="$SESSION_START_CONSUMER_PIN_CONFIG"
else
	# Anchor to the repo root so a SessionStart firing from a subdirectory
	# still finds the config — a $PWD-relative path would miss it. Fall back
	# to $PWD outside a git work tree (advisory hook: must never fail).
	_repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || _repo_root="$PWD"
	CONFIG="$_repo_root/.pre-commit-config.yaml"
fi
CACHE_DIR="${SESSION_START_CONSUMER_PIN_CACHE_DIR:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"

# Not a repo with a pre-commit config → nothing to check.
[ -f "$CONFIG" ] || exit 0
# No plugin cache → can't determine the latest installed release.
[ -d "$CACHE_DIR" ] || exit 0

# Extract the rev pinned for the claude-workflow-core repo block: find its
# repo: line, then print the rev: line WITHIN that block. A non-matching
# repo: line resets the search (found=0) so an UNPINNED claude-workflow-core
# block cannot leak a later block's rev. The repo regex anchors the END of
# the value (optional .git + trailing space) so a substring like
# `repbyrepdev/claude-workflow-core-fork` does NOT false-match. Any host.
PIN=$(awk '
	/^[[:space:]]*-?[[:space:]]*repo:[[:space:]]*.*repbyrepdev\/claude-workflow-core(\.git)?[[:space:]]*$/ { found = 1; next }
	/^[[:space:]]*-?[[:space:]]*repo:/ { found = 0 }
	found && /^[[:space:]]*rev:/ { print; exit }
' "$CONFIG" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || printf '')

# No claude-workflow-core pin → not a consumer of this plugin (or unpinned).
[ -n "$PIN" ] || exit 0

# Highest version on disk (cache). nullglob so an empty cache does not yield a
# literal glob token. ${entry##*/} is a bash builtin (immune to PATH shims).
shopt -s nullglob
entries=("$CACHE_DIR"/*)
shopt -u nullglob
CACHE_MAX=""
# "${entries[@]:-}" guards set -u against an empty array on bash 3.2 (the
# leading empty token harmlessly fails the regex below and continues).
for entry in "${entries[@]:-}"; do
	name=${entry##*/}
	[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
	if [ -z "$CACHE_MAX" ]; then
		CACHE_MAX=$name
	else
		CACHE_MAX=$(printf '%s\n%s\n' "$CACHE_MAX" "$name" | sort -V | tail -1)
	fi
done

# No semver dirs in the cache → can't compare.
[ -n "$CACHE_MAX" ] || exit 0

# Up to date → silent pass.
[ "$PIN" = "$CACHE_MAX" ] && exit 0

# sort -V handles 0.10.0 > 0.9.5 correctly (lexical sort would invert).
higher=$(printf '%s\n%s\n' "$PIN" "$CACHE_MAX" | sort -V | tail -1)
if [ "$higher" = "$CACHE_MAX" ]; then
	# Consumer pin is BEHIND the latest installed release — the staleness case.
	printf 'session-start-consumer-pin-staleness: ⚠ this repo pins claude-workflow-core v%s but v%s is installed.\n  Refresh: address the auto:plugin-release-cascade issue, or run refresh-from-source then bump the .pre-commit-config rev to v%s.\n' "$PIN" "$CACHE_MAX" "$CACHE_MAX" >&2
else
	# Consumer pin is NEWER than any cached release (cache behind / unreleased pin).
	printf 'session-start-consumer-pin-staleness: ⚠ this repo pins claude-workflow-core v%s but the newest installed release is v%s.\n  The plugin cache may be behind — reinstall via the plugin manager (/plugin reload claude-workflow-core).\n' "$PIN" "$CACHE_MAX" >&2
fi
exit 0
