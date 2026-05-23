#!/bin/bash
# v0.6.5 (#39) — plugin-cache fallback resolver for phase hooks.
#
# WHY: Phase hooks (phase0.5-*, phase1-launcher.sh, etc.) reference shared
# helper scripts via "$REPO_ROOT/.claude/scripts/..." paths. When a consumer
# repo doesn't ship its own copies of those helpers (e.g. FCP toolkit, which
# pulls everything from the plugin), the hooks fail-loud with "helper missing"
# even though the plugin cache DOES have the helper.
#
# This lib resolves a relative path under .claude/ by checking:
#   1. $REPO_ROOT/.claude/<rel>   — consumer-shipped copy (legacy / overrides)
#   2. $PLUGIN_ROOT/<rel>         — plugin cache (canonical SSOT)
#
# Same pattern v0.6.4 introduced for memory-drift-check.sh alt_path block.
#
# Usage (in any plugin hook):
#   PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
#   . "$PLUGIN_LIB/resolve-plugin-helper.sh"
#   COPILOT_HELPER="$(resolve_plugin_helper "scripts/copilot/try-free.sh")"
#   [ -n "$COPILOT_HELPER" ] || { echo "no copilot helper found" >&2; exit 1; }

# shellcheck disable=SC2034  # exported via function return — consumed by caller

# resolve_plugin_helper <rel-path>
#   echoes the resolved absolute path on stdout
#   exit 0 if found in either consumer or plugin cache
#   exit 1 if found in neither
resolve_plugin_helper() {
	local rel="$1"
	[ -n "$rel" ] || {
		echo "resolve_plugin_helper: missing rel-path argument" >&2
		return 2
	}

	# Strip leading .claude/ if present (callers pass with-or-without)
	rel="${rel#.claude/}"

	# Consumer-shipped copy wins (allows overrides + matches legacy behavior)
	if [ -n "${REPO_ROOT:-}" ] && [ -e "$REPO_ROOT/.claude/$rel" ]; then
		echo "$REPO_ROOT/.claude/$rel"
		return 0
	fi

	# Plugin-cache fallback. This lib lives at <plugin>/_lib/, so plugin root
	# is parent dir. BASH_SOURCE[0] for this function returns the path of the
	# .sh that DEFINED it (this file), not the caller's path.
	local plugin_root
	plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	if [ -e "$plugin_root/$rel" ]; then
		echo "$plugin_root/$rel"
		return 0
	fi

	return 1
}
