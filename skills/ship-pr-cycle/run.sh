#!/bin/bash
set -euo pipefail
# ship-pr-cycle skill wrapper.
#
# v0.34.32 (#2237): LAYOUT-AGNOSTIC + pinned-cache driver resolution.
#   - Resolves the repo root via `git rev-parse` (works whether this file
#     sits at skills/... in the plugin OR .claude/skills/... in a consumer —
#     no `../..` level-counting, which previously made the plugin + consumer
#     copies non-identical and therefore un-propagatable).
#   - In the PLUGIN repo (a .claude-plugin/plugin.json at the repo root):
#     exec the local scripts/ship-pr-cycle.sh — the dev-checkout IS the SSOT.
#   - In a CONSUMER (no plugin.json): resolve the pinned plugin version from
#     .pre-commit-config.yaml and exec the PINNED-CACHE driver. This realizes
#     the #247 design intent ("consumers exec the orchestrator from the plugin
#     cache by PIN, so no consumer copy can drift") that the OLD wrapper never
#     implemented — it execd $REPO_ROOT/scripts/ship-pr-cycle.sh, a frozen
#     local copy that rotted out of protocol with the SSOT-tracked reader
#     (hooks/ship-cycle-guard.sh) and deadlocked Phase 1 (#2237 root cause).
#
# Wraps the orchestrator with SKILL_WRAPPER=1 so its gh / git push calls
# aren't refused by skill-bypass-guard. Args forwarded verbatim.
#
# Usage:
#   .claude/skills/ship-pr-cycle/run.sh {start|status|next|resume}
#
# Exit codes: forwarded from scripts/ship-pr-cycle.sh:
#   0 — operation succeeded   1 — gate refused   2 — invocation error
#
# Env:
#   SHIP_CYCLE_CACHE_ROOT — override the plugin cache root (default
#                           $HOME/.claude/plugins/cache); used by tests.

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	echo "ship-pr-cycle skill: ERROR: must run inside a git repository (cwd=$PWD)" >&2
	exit 2
fi

if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ]; then
	# PLUGIN repo: the local checkout is the source of truth.
	ORCHESTRATOR="$REPO_ROOT/scripts/ship-pr-cycle.sh"
else
	# CONSUMER repo: resolve the pinned version → exec the cache driver so the
	# orchestrator is ALWAYS the version matching the pinned (SSOT-tracked,
	# refreshed) reader. No local driver copy is consulted (it can't drift).
	pin_lib="$REPO_ROOT/.claude/_lib/resolve-plugin-pin.sh"
	if [ ! -r "$pin_lib" ]; then
		echo "ship-pr-cycle skill: ERROR: $pin_lib missing — run scripts/refresh-from-source.sh to install the plugin _lib helpers" >&2
		exit 2
	fi
	# shellcheck source=/dev/null
	. "$pin_lib"
	if ! pin=$(resolve_plugin_pin "$REPO_ROOT/.pre-commit-config.yaml"); then
		echo "ship-pr-cycle skill: ERROR: could not resolve claude-workflow-core pin from $REPO_ROOT/.pre-commit-config.yaml" >&2
		exit 2
	fi
	cache_root="${SHIP_CYCLE_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
	# Canonical cache layout:
	#   <root>/<marketplace>/claude-workflow-core/<pin>/scripts/ship-pr-cycle.sh
	# Glob the marketplace segment so a non-default marketplace dir name still
	# resolves. No match → the glob stays literal, the -f test fails, and the
	# loud error below fires (no silent fall-back to a stale local driver).
	ORCHESTRATOR=""
	for cand in "$cache_root"/*/claude-workflow-core/"$pin"/scripts/ship-pr-cycle.sh; do
		if [ -f "$cand" ]; then
			ORCHESTRATOR="$cand"
			break
		fi
	done
	if [ -z "$ORCHESTRATOR" ]; then
		echo "ship-pr-cycle skill: ERROR: no cached claude-workflow-core driver for pin '$pin' under $cache_root — run scripts/bootstrap-machine.sh (or bump + refresh the pin)" >&2
		exit 2
	fi
fi

if [ ! -x "$ORCHESTRATOR" ]; then
	echo "ship-pr-cycle skill: ERROR: $ORCHESTRATOR missing or not executable" >&2
	exit 2
fi

export SKILL_WRAPPER=1

exec "$ORCHESTRATOR" "$@"
