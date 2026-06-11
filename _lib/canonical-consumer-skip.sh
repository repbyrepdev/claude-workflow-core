#!/bin/bash
# set-u: opt-out — sourced library; inherits the caller gate's set -euo pipefail
# v0.34.31 (#2235) — consumer-aware canonical-skip for plugin pre-commit gates.
#
# WHY: The plugin's own gates (event-frontmatter-check, bash-safety,
# bash4-features-check, bats-gate) re-validate plugin-CANONICAL files when they
# run inside a CONSUMER repo (via the pinned `repo:` block). Those files are
# already validated UPSTREAM (in the plugin) and byte-identity is enforced by
# hash-drift / stale-shadow-guard. Re-validating them in a consumer is
# redundant AND wrong: the consumer's `.claude/<dir>/` layout + missing dev
# fixtures trip plugin conventions that hold only at the plugin's top-level
# layout. This blocked media-server's v0.34.30 convergence with a cascade of
# gate failures on byte-identical canonical files (#2235 / #223).
#
# This lib lets each gate skip a staged file when ALL of these hold:
#   (a) we're in a CONSUMER (no `.claude-plugin/plugin.json` at repo root),
#   (b) the pinned canonical root is RESOLVABLE — this lib resolves the cache
#       via its own BASH_SOURCE: pre-commit normally executes the hook from the
#       pinned cache clone, so `<this-lib>/..` is usually the pinned canonical
#       root. If it is NOT (e.g. the lib was resolved from a consumer's own
#       override tree), the plugin.json guard below fails safe (returns 1), AND
#   (c) the file is byte-identical to the same logical file in that cache.
#
# In the PLUGIN itself (has plugin.json) the skip NEVER fires → full
# enforcement preserved. A consumer-MODIFIED or non-canonical file is not
# byte-identical → still checked. Repo-root/cache unresolvable, cmp error,
# missing cmp → NOT skipped (fail-safe: check it).
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

	# Fail-safe: an unresolvable repo root must NOT participate in a skip
	# decision (#2235 r1 silent-failure-hunter). pre-commit always runs inside
	# a git repo so rev-parse succeeds; outside one we return 1 (check the file)
	# rather than guessing via pwd.
	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	[ -n "$repo_root" ] || return 1

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

	# Map consumer path → canonical. The plugin keeps hooks/_lib/pre-commit-
	# hooks/scripts/skills at top-level (consumer mirrors them under .claude/),
	# but .claude/tests/ + .github/ + .gemini/ + .semgrep/ share the same path
	# in both. Try the stripped mapping first, then as-is; skip on the first
	# byte-identical match. Byte-identity (cmp -s) is the backstop: even if the
	# two candidates collided, a skip only ever fires on identical content.
	local stripped="${repo_rel#.claude/}"
	local cand
	for cand in "$plugin_root/$stripped" "$plugin_root/$repo_rel"; do
		[ -f "$cand" ] && cmp -s "$consumer_file" "$cand" && return 0
	done
	return 1
}

# canonical_consumer_skip_committed <repo-relative-path>
#   Same decision as canonical_consumer_skip, but compares the COMMITTED blob's
#   git object id (#2327) to the pinned canonical instead of the WORKING-TREE file.
#   The REVIEW layers review the COMMITTED state — phase1 agents scope on
#   `git diff <base>..HEAD`, phase2 CR-CLI reviews `-t committed` — so the
#   exclusion they use MUST match what was reviewed. With the working-tree
#   predicate, a consumer that COMMITTED a mirror change (→ a real finding on the
#   committed blob CR reviewed) then REVERTED it to canonical in the working tree
#   would have that finding wrongly DROPPED (#2250 TOCTOU → a false-clean lets
#   unreviewed committed code reach push). The pre-commit GATES keep
#   canonical_consumer_skip (working-tree / staged) — they validate staged
#   content, not the committed blob.
#   exit 0 → SKIP (consumer + committed blob byte-identical to pinned canonical)
#   exit 1 → DO NOT skip (plugin / not committed / committed-differs / unresolvable)
canonical_consumer_skip_committed() {
	local repo_rel="${1:-}"
	[ -n "$repo_rel" ] || return 1

	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	[ -n "$repo_root" ] || return 1

	# Plugin repo → never skip (full self-enforcement), same as the working-tree
	# predicate.
	[ -f "$repo_root/.claude-plugin/plugin.json" ] && return 1

	local plugin_root
	plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || return 1
	[ -n "$plugin_root" ] || return 1
	[ -f "$plugin_root/.claude-plugin/plugin.json" ] || return 1

	# Resolve the COMMITTED blob's object id ONCE — atomic (no second read of a
	# possibly-changing HEAD; #2327 r1 silent-failure-hunter). `git rev-parse
	# --verify` also gates traversal: an out-of-tree refspec like `HEAD:../x` or
	# an absolute `HEAD:/etc/...` is rejected by git, so a CR-finding-supplied
	# path cannot escape the tree (#2327 r1 security-review). Fail-safe paths:
	#   - not in HEAD (new/uncommitted file)         → return 1 (review it)
	#   - a non-blob path (a committed dir/gitlink)  → its tree/commit oid can
	#     never equal a blob oid → falls through to review
	# oids are newline-free, so the $() captures are byte-exact.
	local committed_oid
	committed_oid="$(git rev-parse --verify --quiet "HEAD:$repo_rel" 2>/dev/null)" || return 1
	[ -n "$committed_oid" ] || return 1

	# A skip fires only on an exact oid match = byte-identical committed content.
	# `git hash-object` computes the blob oid of a file's content with the same
	# hash algorithm as rev-parse. hash-object failure → empty → no match →
	# review (fail-safe). `[ … ] && return 0` is a tested condition (set -e safe).
	local stripped="${repo_rel#.claude/}" cand
	for cand in "$plugin_root/$stripped" "$plugin_root/$repo_rel"; do
		[ -f "$cand" ] || continue
		[ "$committed_oid" = "$(git hash-object "$cand" 2>/dev/null)" ] && return 0
	done
	return 1
}
