#!/bin/bash
set -euo pipefail
# event: SessionStart
# auto-register: true
# Introduced in #89 (released as v0.11.0) — SessionStart hook that
# detects when ~/.claude/settings.json plugin-cache path refs are
# stale relative to the latest installed plugin cache version.
#
# Why: hooks/{...}.sh paths in settings.json embed a hard-coded plugin
# version (e.g. claude-workflow-core/0.8.5/hooks/...). When the plugin
# is updated via /plugin reload or scripts/release.sh, new cache dirs
# (0.9.x, 0.10.x, etc.) get created but settings.json still points at
# the old version — every hook keeps running its STALE 0.8.5 copy.
# Multi-month drift is the norm without operator awareness.
#
# This session: operator's settings.json was pinned at 0.8.5 while the
# plugin shipped 0.9.5 → 0.9.7 → 0.10.0 over ~11 weeks. Discovered
# during #89 spec review.
#
# Behavior: pure ADVISORY (no deny / no block). Emits a single warning
# line to stderr if drift detected. Reads ~/.claude/settings.json,
# extracts the latest plugin-version path-segment among
# .claude/plugins/cache/claude-workflow-core/claude-workflow-core/<X.Y.Z>/
# refs, compares to the latest cache dir on disk. If newer → warn.
#
# Skip env: SESSION_START_STALE_PIN_SKIP=1.
#
# Exit codes:
#   0 — always (advisory hook; never block session start)

if [ "${SESSION_START_STALE_PIN_SKIP:-0}" = "1" ]; then
	exit 0
fi

SETTINGS="${SESSION_START_STALE_PIN_SETTINGS:-$HOME/.claude/settings.json}"
CACHE_DIR="${SESSION_START_STALE_PIN_CACHE_DIR:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"

# No settings.json → not a Claude Code install we know how to inspect.
[ -f "$SETTINGS" ] || exit 0
# No cache dir → plugin not installed via cache (e.g., dev-from-source).
[ -d "$CACHE_DIR" ] || exit 0

if ! command -v jq >/dev/null 2>&1; then
	# jq missing — silently pass; operator gets jq install nudge from
	# other hooks. Not our drift to surface.
	exit 0
fi

# Extract the highest semver path-segment from settings.json refs.
# All paths follow:
#   .../claude-workflow-core/claude-workflow-core/<X.Y.Z>/hooks/...
# Some entries may have different version strings; we want the max.
SETTINGS_VER=$(jq -r '
  [.. | strings | select(test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/"))]
  | map(capture("claude-workflow-core/claude-workflow-core/(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)/").v)
  | unique
  | .[]
' "$SETTINGS" 2>/dev/null | sort -V | tail -1 || printf '')

if [ -z "$SETTINGS_VER" ]; then
	# No plugin-cache refs in settings.json → not pinned, nothing to
	# drift-check.
	exit 0
fi

# Find the highest version on-disk via glob (avoids ls-piped-grep
# per SC2010). Iterate the cache dir's direct children.
CACHE_VER=""
for entry in "$CACHE_DIR"/*; do
	name=$(basename "$entry")
	[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
	if [ -z "$CACHE_VER" ]; then
		CACHE_VER=$name
	else
		higher_cv=$(printf '%s\n%s\n' "$CACHE_VER" "$name" | sort -V | tail -1)
		CACHE_VER=$higher_cv
	fi
done

if [ -z "$CACHE_VER" ]; then
	# Cache dir exists but no semver subdirs — nothing to compare.
	exit 0
fi

if [ "$SETTINGS_VER" = "$CACHE_VER" ]; then
	# Up to date — silent pass.
	exit 0
fi

# Use sort -V to determine if cache > settings.
higher=$(printf '%s\n%s\n' "$SETTINGS_VER" "$CACHE_VER" | sort -V | tail -1)
if [ "$higher" = "$CACHE_VER" ] && [ "$CACHE_VER" != "$SETTINGS_VER" ]; then
	# Drift detected — newer cache exists than settings refs.
	cat >&2 <<EOF
session-start-stale-pin: ⚠ plugin-cache drift detected
  settings.json refs: v$SETTINGS_VER
  latest cache dir:   v$CACHE_VER
  Remediation: run \`scripts/migrate-settings.sh\` to update
  ~/.claude/settings.json plugin paths to v$CACHE_VER.
EOF
fi
exit 0
