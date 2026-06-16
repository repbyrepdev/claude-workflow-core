#!/bin/bash
# set-u: opt-out — sourced library; inherits the caller's set -u/-e options.
# _lib/resolve-orchestrator.sh — SSOT for resolving the ship-pr-cycle
# orchestrator path layout-agnostically (#2427).
#
# WHY: both the skill wrapper (skills/ship-pr-cycle/run.sh) and the post-commit
# auto-fire (hooks/post-commit-ship-cycle.sh) need the orchestrator. Before
# #2427 the wrapper resolved it correctly (#2237) but post-commit-ship-cycle.sh
# HARDCODED "$REPO_ROOT/scripts/ship-pr-cycle.sh" — which in a CONSUMER is the
# STALE FROZEN copy, NOT the pinned-cache driver. That frozen driver emits a
# phase1 directive with no `phase1_directive_protocol` stamp, which ship-cycle-
# guard rejects → the unrecoverable 3-way deadlock of the 2026-06-16 re-pin
# saga. Centralizing the resolution here means NEITHER caller can drift, and a
# consumer can never auto-fire a frozen copy.
#
#   resolve_ship_orchestrator [repo_root]
#     stdout: absolute path to the executable orchestrator
#     rc 0 = resolved + executable
#     rc 2 = error (diagnostic on stderr): not a git repo / missing pin lib /
#            unresolvable pin / no cached driver / non-executable.
#
# In the PLUGIN repo (a `.claude-plugin/plugin.json` at the root) the local
# `scripts/ship-pr-cycle.sh` IS the source of truth. In a CONSUMER (no
# plugin.json) resolve the pinned version from `.pre-commit-config.yaml` and
# return the PINNED-CACHE driver — no frozen consumer copy is ever consulted
# (#247 design intent). Mirrors the layout-agnostic logic the skill wrapper
# introduced in #2237; this lib is the single SSOT both callers now source.
#
# Env: SHIP_CYCLE_CACHE_ROOT overrides the plugin cache root (default
#      $HOME/.claude/plugins/cache); used by tests.

resolve_ship_orchestrator() {
	local repo_root="${1:-}"
	if [ -z "$repo_root" ]; then
		if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
			echo "resolve-orchestrator: ERROR: must run inside a git repository (cwd=$PWD)" >&2
			return 2
		fi
	fi

	local orchestrator=""
	if [ -f "$repo_root/.claude-plugin/plugin.json" ]; then
		# PLUGIN repo: the local checkout IS the source of truth.
		orchestrator="$repo_root/scripts/ship-pr-cycle.sh"
	else
		# CONSUMER repo: resolve the pinned version → exec the cache driver so
		# the orchestrator ALWAYS matches the pinned (SSOT-tracked, refreshed)
		# reader. No local driver copy is consulted (it can't drift).
		local pin_lib="$repo_root/.claude/_lib/resolve-plugin-pin.sh"
		if [ ! -r "$pin_lib" ]; then
			echo "resolve-orchestrator: ERROR: $pin_lib missing — run scripts/refresh-from-source.sh to install the plugin _lib helpers" >&2
			return 2
		fi
		# shellcheck source=/dev/null
		. "$pin_lib"
		local pin
		if ! pin=$(resolve_plugin_pin "$repo_root/.pre-commit-config.yaml"); then
			echo "resolve-orchestrator: ERROR: could not resolve claude-workflow-core pin from $repo_root/.pre-commit-config.yaml" >&2
			return 2
		fi
		local cache_root="${SHIP_CYCLE_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
		# Canonical cache layout:
		#   <root>/<marketplace>/claude-workflow-core/<pin>/scripts/ship-pr-cycle.sh
		# Glob the marketplace segment so a non-default marketplace dir name still
		# resolves. No match → the glob stays literal, the -f test fails, and the
		# loud error below fires (no silent fall-back to a stale local driver).
		local cand
		for cand in "$cache_root"/*/claude-workflow-core/"$pin"/scripts/ship-pr-cycle.sh; do
			if [ -f "$cand" ]; then
				orchestrator="$cand"
				break
			fi
		done
		if [ -z "$orchestrator" ]; then
			echo "resolve-orchestrator: ERROR: no cached claude-workflow-core driver for pin '$pin' under $cache_root — run scripts/bootstrap-machine.sh (or bump + refresh the pin)" >&2
			return 2
		fi
	fi

	if [ ! -x "$orchestrator" ]; then
		echo "resolve-orchestrator: ERROR: $orchestrator missing or not executable" >&2
		return 2
	fi
	printf '%s' "$orchestrator"
	return 0
}
