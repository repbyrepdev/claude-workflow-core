#!/bin/bash
# auto-register: false
# shellcheck disable=SC2119,SC2120  # repo_guard_current_repo's optional $1 (dir) is intentional public/test API; callers/tests pass it, internal calls omit it
set -u
# v0.33 (#223) — conditional-SSOT-hook guard.
#
# WHY: Repo-specific hooks (homelab Fusion-e2e / Docker-deploy gates that only
# make sense in media-server; the coalesce-gracie-only-gate that only makes
# sense in pricing-team-toolkit) used to be NON-SSOT files living locally in
# each consumer repo. That defeats the plugin's drift-gated SSOT story: a
# local-only hook can rot, can't be hash-tracked, and can't be propagated by
# bootstrap. This lib lets such a hook ship from the plugin as ONE SSOT file
# that SELF-SKIPS (cleanly no-ops) in every repo EXCEPT its declared target(s).
#
# Public API:
#
#   repo_guard_require <repo-slug> [<repo-slug>...]
#     Returns 0 (the caller should CONTINUE) IFF the current repo matches one
#     of the given slugs. Returns 1 otherwise (the caller should `|| exit 0`
#     to cleanly no-op). Matching is case-insensitive and tolerant of a `.git`
#     suffix and `owner/` prefixes on either side.
#
#     Current-repo detection is robust + defensive (never hard-errors a hook):
#       1. git remote `origin` basename (e.g. git@github.com:acme/media-server.git
#          → media-server). Preferred — survives a renamed/clone-relocated
#          working dir.
#       2. fall back to the git toplevel dir basename when there is no origin
#          (or `remote get-url` fails: detached, bare, partial clone, etc.).
#       3. fall back to $PWD basename when not in a git repo at all.
#     A slug arg that is itself owner-qualified (acme/media-server) or carries
#     a trailing .git is normalized the same way before comparison.
#
#   repo_guard_current_repo [<dir>]
#     Echoes the detected current-repo slug (lowercased) for <dir> (default the
#     caller's $PWD). Useful for logging / multi-branch hooks. Never fails.
#
# This is a SOURCED library — uses `set -u` only (NOT -e / -o pipefail, which
# would propagate to the sourcing hook's flow control and turn a benign
# non-match into a hard abort). Every internal command is failure-tolerant.
#
# Usage (in any plugin hook, near the top, AFTER the shebang + set line):
#
#   # Resolve the lib dir the same way sibling hooks do (BASH_SOURCE-relative).
#   _RG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
#   # shellcheck source=../_lib/repo-guard.sh
#   . "$_RG_LIB/repo-guard.sh"
#   repo_guard_require media-server || exit 0      # self-skip outside media-server
#
# A hook may target multiple repos:  repo_guard_require media-server homelab || exit 0
#
# NOTE for hooks resolved via resolve-plugin-helper.sh: source THIS file with
# the same BASH_SOURCE-relative `_lib` idiom shown above (repo-guard.sh is a
# co-located _lib sibling, NOT a `.claude/scripts/...` helper, so it does not
# go through resolve_plugin_helper).

# _repo_guard_normalize_slug <raw>
#   Echoes a normalized comparison key: lowercased, trailing `.git` stripped,
#   any `owner/` prefix dropped (keep only the final path segment). Used for
#   BOTH the detected repo name and each user-supplied slug so the two sides
#   are compared apples-to-apples.
_repo_guard_normalize_slug() {
	local raw="${1:-}"
	# Drop everything up to and including the last `/` (owner prefix, or a
	# full URL path). Leaves the bare repo name.
	raw="${raw##*/}"
	# Strip a `:` segment too — covers scp-style `git@host:owner/repo` after
	# the `/`-strip leaves nothing, and bare `host:repo` shorthand.
	raw="${raw##*:}"
	# Strip a trailing `.git`.
	raw="${raw%.git}"
	# Lowercase (bash 4 ${,,} is available — repo standard targets bash 4+,
	# but guard against bash 3 by falling back to tr).
	if [ -n "$raw" ]; then
		printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
	fi
}

# repo_guard_current_repo [<dir>]
#   Detect the current repo slug for <dir> (default $PWD). Lowercased,
#   normalized. Echoes empty string only if NOTHING is resolvable (which
#   should be near-impossible — $PWD basename is the last resort). Never
#   returns non-zero (always `|| true`-safe).
repo_guard_current_repo() {
	local dir="${1:-$PWD}"
	local url="" top="" name=""

	# 1) Prefer the origin remote basename. `git -C <dir>` avoids a cd.
	#    2>/dev/null + `|| true`-style capture: a missing origin / not-a-repo
	#    leaves $url empty and we fall through.
	url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=""
	if [ -n "$url" ]; then
		name=$(_repo_guard_normalize_slug "$url")
		if [ -n "$name" ]; then
			printf '%s' "$name"
			return 0
		fi
	fi

	# 2) Fall back to the git toplevel dir basename (no origin / detached /
	#    partial clone). Still a git repo, just no usable remote.
	top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || top=""
	if [ -n "$top" ]; then
		name=$(_repo_guard_normalize_slug "$top")
		if [ -n "$name" ]; then
			printf '%s' "$name"
			return 0
		fi
	fi

	# 3) Last resort: $PWD (or the passed dir) basename — handles "not in a
	#    git repo at all" so the function still yields SOMETHING to compare.
	name=$(_repo_guard_normalize_slug "$dir")
	printf '%s' "$name"
	return 0
}

# repo_guard_require <slug> [<slug>...]
#   0 → current repo matches one of <slug…>  (caller CONTINUES)
#   1 → no match                              (caller should `|| exit 0`)
#   2 → called with zero slugs (programming error; fail-OPEN-ish but signalled)
repo_guard_require() {
	if [ "$#" -eq 0 ]; then
		echo "repo-guard: repo_guard_require needs at least one repo-slug (programming error)" >&2
		# A `|| exit 0` caller would silently mask this misconfig as a harmless
		# skip. Hard-exit when the lib is run directly; return 2 when sourced
		# (normal path — caught by the hook's bats, not masked at runtime).
		[ "${BASH_SOURCE[0]}" = "${0:-}" ] && exit 2
		return 2
	fi

	local current
	current=$(repo_guard_current_repo) || current=""
	# Defensive: an empty detection (truly nothing resolvable) can't match
	# any concrete slug, so self-skip. A hook that wants the opposite can
	# inspect repo_guard_current_repo itself.
	[ -n "$current" ] || return 1

	local want
	for want in "$@"; do
		want=$(_repo_guard_normalize_slug "$want")
		[ -n "$want" ] || continue
		if [ "$current" = "$want" ]; then
			return 0
		fi
	done
	return 1
}
