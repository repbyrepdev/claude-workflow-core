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

	# Compute the canonical plugin-cache path UP FRONT (#223). This lib lives
	# at <plugin>/_lib/, so plugin root is the parent dir. BASH_SOURCE[0] for
	# this function returns the path of the .sh that DEFINED it (this file),
	# not the caller's path. We resolve it here (not just in the fallback
	# branch) so the consumer-copy branch can compare against it and warn on a
	# stale shadow.
	local plugin_root canonical
	plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
	canonical="$plugin_root/$rel"

	# Consumer-shipped copy wins (allows overrides + matches legacy behavior).
	if [ -n "${REPO_ROOT:-}" ] && [ -e "$REPO_ROOT/.claude/$rel" ]; then
		local local_copy="$REPO_ROOT/.claude/$rel"
		# #223 stale-shadow detection: these helper paths are NOT tracked in
		# .claude/.source-hashes.json, so a drifting local copy silently
		# shadows the canonical SSOT and goes uncaught (a stale
		# .claude/scripts/copilot/try-free.sh once shadowed the fixed canonical
		# undetected, breaking the copilot prefilter). If a canonical ALSO
		# exists and DIFFERS, warn loudly — but STILL return the local copy to
		# preserve the intentional-override capability + legacy behavior.
		# When no canonical exists (e.g. a producer's legitimately-local-only
		# file), this whole block is skipped and behavior is byte-identical to
		# the pre-#223 resolver.
		if [ -e "$canonical" ] && ! cmp -s "$local_copy" "$canonical"; then
			echo "resolve-plugin-helper: WARNING — local copy SHADOWS a DIFFERING plugin canonical (#223 possible stale override shadow)" >&2
			echo "  local (used):  $local_copy" >&2
			echo "  canonical:     $canonical" >&2
			echo "  These differ. If this is NOT an intentional override, the local copy is a stale shadow — delete it so the canonical SSOT resolves." >&2
		fi
		echo "$local_copy"
		return 0
	fi

	# Plugin-cache fallback.
	if [ -e "$canonical" ]; then
		echo "$canonical"
		return 0
	fi

	return 1
}
