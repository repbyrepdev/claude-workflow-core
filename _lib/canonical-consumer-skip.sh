#!/bin/bash
# set-u: opt-out — sourced library; inherits the caller gate's set -euo pipefail
# v0.34.31 (#2235) — consumer-aware canonical-skip for plugin pre-commit gates.
#
# WHY: The plugin's own gates (event-frontmatter-check, bash-safety,
# bash4-features-check, bats-gate, ...) re-validate plugin-CANONICAL files
# when they run inside a CONSUMER repo (via the pinned `repo:` block). Those
# files are already validated UPSTREAM (in the plugin) and byte-identity is
# enforced by hash-drift / stale-shadow-guard. Re-validating them in a
# consumer is redundant AND wrong: the consumer's `.claude/<dir>/` layout +
# missing dev fixtures trip plugin conventions that hold only at the plugin's
# top-level layout. This blocked media-server's v0.34.30 convergence with a
# cascade of gate failures on byte-identical canonical files (#2235 / #223).
#
# This lib lets each gate skip a staged file IFF:
#   (a) we're in a CONSUMER (no `.claude-plugin/plugin.json` at repo root), AND
#   (b) the file is byte-identical to the same logical file in the pinned
#       plugin cache (this lib resolves the cache via its own BASH_SOURCE —
#       pre-commit executes the hook from the pinned cache clone, so
#       `<this-lib>/..` IS the pinned canonical root).
#
# In the PLUGIN itself (has plugin.json) the skip NEVER fires → full
# enforcement preserved. A consumer-MODIFIED or non-canonical file is not
# byte-identical → still checked. Cache-missing / unresolvable → NOT skipped
# (fail-safe: check it).
#
# Sourcing contract (from a pre-commit-hooks/*.sh gate):
#   LIB="$(dirname "$0")/../_lib/canonical-consumer-skip.sh"
#   [ -f "$LIB" ] && . "$LIB"
#   ... in the per-file loop:
#   command -v canonical_consumer_skip >/dev/null 2>&1 \
#     && canonical_consumer_skip "$f" && continue
#
# auto-register: false   # sourced library, not a registered event hook

# shellcheck disable=SC2034  # function consumed by callers

# canonical_consumer_skip <repo-relative-path>
#   exit 0 → SKIP (consumer + byte-identical-to-pinned-canonical)
#   exit 1 → DO NOT skip (plugin repo, modified, non-canonical, or unresolvable)
canonical_consumer_skip() {
	local repo_rel="${1:-}"
	[ -n "$repo_rel" ] || return 1

	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || return 1

	# Plugin repo → never skip (full self-enforcement).
	[ -f "$repo_root/.claude-plugin/plugin.json" ] && return 1

	local consumer_file="$repo_root/$repo_rel"
	[ -f "$consumer_file" ] || return 1

	# Pinned canonical root = this lib's parent dir. pre-commit runs the gate
	# from the pinned-cache clone, so BASH_SOURCE resolves to that clone's
	# _lib/, and `..` is the pinned plugin root (the canonical SSOT @ the pin).
	local plugin_root
	plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || return 1
	[ -n "$plugin_root" ] || return 1

	# Don't false-skip when this lib is resolved from the consumer's own tree
	# (e.g. a local override copy): if plugin_root has no plugin.json it isn't
	# the canonical cache → fail-safe, check the file.
	[ -f "$plugin_root/.claude-plugin/plugin.json" ] || return 1

	# Map consumer path → canonical. Plugin keeps hooks/_lib/pre-commit-hooks/
	# scripts/skills at top-level (consumer mirrors them under .claude/), but
	# .claude/tests/ + .github/ + .gemini/ + .semgrep/ share the same path in
	# both. Try the stripped mapping first, then as-is; skip on the first
	# byte-identical match.
	local stripped="${repo_rel#.claude/}"
	local cand
	for cand in "$plugin_root/$stripped" "$plugin_root/$repo_rel"; do
		[ -f "$cand" ] && cmp -s "$consumer_file" "$cand" && return 0
	done
	return 1
}
