#!/bin/bash
set -u
# _lib/branch-convention.sh — SSOT for the canonical work-branch naming
# convention (#2416). Sourced by every enforcer that validates a branch NAME so
# the rule lives in exactly ONE place and cannot drift: the creation-time gate
# (issue-before-code) and the PR-time verify (meta-bootstrap feature-branch).
# NO per-repo or per-enforcer variants — that divergence (feat-only `vX.Y-Z` in
# one enforcer vs all-types `vX.Y.Z` in another) is the bug this lib exists to
# kill. (pre-push gates on tags/abandoned commits, not branch names, so it does
# not consume this lib.)
#
# Canonical form: <type>/vX.Y.Z[-suffix]/<issue-num>-<slug>
#   type   — Conventional Commits type: feat fix chore docs refactor perf test build ci revert
#   vX.Y.Z — dotted SemVer (optional -suffix, e.g. v4.28.0-W4)
#   issue  — the GitHub issue number this branch closes/advances
#   slug   — lowercase kebab-case
#
# Functions (pure string ops, no side effects):
#   branch_convention_re                   — echo the canonical regex (the SSOT)
#   branch_convention_expected             — echo the human-readable expected form
#   branch_convention_validate <name>      — rc 0 valid · rc 1 scratch (no type
#                                            prefix, or empty → allowed) · rc 2
#                                            malformed work branch (claims
#                                            <type>/ but does not match → block)
#   branch_convention_extract_issue <name> — echo the embedded issue number
#                                            (canonical path-segment, or #NNN);
#                                            empty when none
#
# Usage:
#   source "$(dirname "$0")/../_lib/branch-convention.sh"

# The ONE canonical definition. Static parts single-quoted (so `\.` and the `$`
# anchor stay literal); the type alternation is the only interpolation. The slug
# is lowercase-kebab with NO leading/trailing dash (the `([a-z0-9-]*[a-z0-9])?`
# tail forbids a trailing `-` while still allowing a single-char slug). Capture
# groups: 1=type, 2=optional version suffix, 3=issue number, 4=slug tail (unused).
# The version suffix keeps `.` (SemVer 2.0 pre-release identifiers are
# dot-separated, e.g. v1.2.3-rc.1) — matching the canonical meta-bootstrap form.
_BRANCH_CONVENTION_TYPES='feat|fix|chore|docs|refactor|perf|test|build|ci|revert'
_BRANCH_CONVENTION_RE='^('"$_BRANCH_CONVENTION_TYPES"')/v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?/([0-9]+)-[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
# A name that merely starts with a known type prefix is CLAIMING to be a work
# branch; it must then fully match the convention or it is malformed (NOT a
# harmless scratch branch).
_BRANCH_CONVENTION_TYPE_PREFIX_RE='^('"$_BRANCH_CONVENTION_TYPES"')/'

branch_convention_re() { printf '%s' "$_BRANCH_CONVENTION_RE"; }

branch_convention_expected() {
	printf '%s' '<type>/vX.Y.Z/<issue-num>-<slug>  (type: feat|fix|chore|docs|refactor|perf|test|build|ci|revert; version dotted SemVer; slug lowercase-kebab)'
}

# rc 0 = valid canonical convention (caller should verify issue existence next)
# rc 1 = scratch branch (no <type>/ prefix) OR empty name — allowed, no issue check
# rc 2 = malformed work branch (claims a <type>/ prefix but does not match) — block
branch_convention_validate() {
	local name="${1:-}"
	[ -z "$name" ] && return 1
	[[ $name =~ $_BRANCH_CONVENTION_RE ]] && return 0
	[[ $name =~ $_BRANCH_CONVENTION_TYPE_PREFIX_RE ]] && return 2
	return 1
}

# Echo the issue number embedded in a branch name: the canonical path-segment
# (group 3 of the convention RE) first, then an explicit `#NNN` fallback. Empty
# output when no issue is embedded.
#
# The `#NNN` fallback is for callers that pass a NON-canonical name (the
# issue-before-code hook only reaches this after a rc-0 canonical validate, so
# it always hits the first branch — but this lib is a shared SSOT and the
# fallback is exercised directly by the unit tests). Keep both branches.
branch_convention_extract_issue() {
	local name="${1:-}"
	# `:-` defaults so `set -u` can never hard-error if a future regex edit
	# changes the group count; valid branches still extract correctly.
	if [[ $name =~ $_BRANCH_CONVENTION_RE ]]; then
		printf '%s' "${BASH_REMATCH[3]:-}"
		return 0
	fi
	if [[ $name =~ \#([0-9]+) ]]; then
		printf '%s' "${BASH_REMATCH[1]:-}"
	fi
}
