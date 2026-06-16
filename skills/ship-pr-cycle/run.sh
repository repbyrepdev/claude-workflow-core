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
# Usage (this same file lives at skills/ in the plugin and .claude/skills/
# in a consumer — git rev-parse makes it layout-agnostic):
#   <skills-dir>/ship-pr-cycle/run.sh {start|status|next|resume}
#
# Exit codes: 0 succeeded · 1 gate refused · 2 invocation error.
#   On success the wrapper exec()s the orchestrator and forwards ITS exit
#   code. Resolution failures in THIS wrapper (no git repo, missing pin
#   lib, unresolvable pin, no cached driver, non-executable driver) also
#   exit 2 BEFORE the orchestrator runs — those originate here, they are
#   not forwarded.
#
# Env:
#   SHIP_CYCLE_CACHE_ROOT — override the plugin cache root (default
#                           $HOME/.claude/plugins/cache); used by tests.

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	echo "ship-pr-cycle skill: ERROR: must run inside a git repository (cwd=$PWD)" >&2
	exit 2
fi

# v0.34.81 (#2427): the plugin-local-vs-pinned-cache resolution is now the SSOT
# in _lib/resolve-orchestrator.sh, shared with hooks/post-commit-ship-cycle.sh
# so the post-commit auto-fire can NEVER drift to a frozen repo-root driver
# (the deadlock root cause). _lib is a sibling of skills/ in BOTH layouts:
# skills/ship-pr-cycle/run.sh → ../../_lib (plugin _lib); .claude/skills/ship-
# pr-cycle/run.sh → ../../_lib (.claude/_lib in a consumer).
_LIB_RESOLVE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_lib" 2>/dev/null && pwd)/resolve-orchestrator.sh"
if [ ! -r "$_LIB_RESOLVE" ]; then
	echo "ship-pr-cycle skill: ERROR: $_LIB_RESOLVE missing — run scripts/refresh-from-source.sh to install the plugin _lib helpers" >&2
	exit 2
fi
# shellcheck source=../../_lib/resolve-orchestrator.sh
. "$_LIB_RESOLVE"
if ! ORCHESTRATOR=$(resolve_ship_orchestrator "$REPO_ROOT"); then
	# resolve_ship_orchestrator already emitted a specific diagnostic to stderr
	# (not-a-repo / missing pin lib / unresolvable pin / no cached driver /
	# non-executable). Exit 2 — a resolution failure originates here, it is not
	# a forwarded orchestrator exit code.
	exit 2
fi

export SKILL_WRAPPER=1

exec "$ORCHESTRATOR" "$@"
