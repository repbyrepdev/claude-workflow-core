#!/bin/bash
# set-u: opt-out — sourced library; inherits the caller's set -u/-e options.
# v0.34.59 (#2310 / #2316) — SSOT for plugin identity + cache-path resolution.
#
# WHY: plugin self-references (repo URL, name, owner) are hardcoded across
# cascade-to-consumers.sh / install-plugin-git-hooks.sh / bootstrap-repo.sh.
# This lib centralizes identity derivation from .claude-plugin/plugin.json
# (already the version SSOT) so a fork/rename auto-adapts, and centralizes
# plugin-cache path resolution. cascade-to-consumers.sh is the FIRST consumer
# (#2310); install-plugin-git-hooks.sh + bootstrap-repo.sh still hardcode their
# self-refs and are slated to migrate (#2309 follow-on). Identity is DERIVED,
# not hardcoded (per #2309 Task 1); the exported constant names match #2316.
#
# `set -euo pipefail` is intentionally OMITTED — repo convention for sourced
# libs (see resolve-plugin-helper.sh, canonical-review-exclude.sh): a sourced
# `set -e` would mutate the caller's options. Functions instead use explicit
# return codes: 0 = ok, 1 = not-found, 2 = hard-error.
#
# Usage:
#   PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
#   . "$PLUGIN_LIB/resolve-plugin-identity.sh"
#   echo "$PLUGIN_REPO_URL"                       # derived, exported constant
#   require_plugin_identity || exit 2             # fail-closed gate for callers
#   latest="$(resolve_plugin_cache_latest)" || echo "no cache installed" >&2

# shellcheck disable=SC2034  # constants are exported for sourcing callers

# Resolve plugin.json relative to THIS lib so the caller's cwd is irrelevant;
# the PLUGIN_JSON env override supports testing against a fixture manifest.
_RPI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _RPI_LIB_DIR=""
PLUGIN_JSON="${PLUGIN_JSON:-${_RPI_LIB_DIR}/../.claude-plugin/plugin.json}"

# Derive identity constants from plugin.json. Each is env-overridable (the
# `${VAR:-...}` form) so a caller/test can preset it. `jq -er` fails closed on a
# missing/empty field; under a caller's `set -e` that surfaces loudly rather
# than silently producing an empty identity.
if [ -f "$PLUGIN_JSON" ]; then
	PLUGIN_NAME="${PLUGIN_NAME:-$(jq -er '.name' "$PLUGIN_JSON")}"
	PLUGIN_REPO_URL="${PLUGIN_REPO_URL:-$(jq -er '.repository' "$PLUGIN_JSON")}"
else
	echo "resolve-plugin-identity: plugin.json not found at $PLUGIN_JSON" >&2
	PLUGIN_NAME="${PLUGIN_NAME:-}"
	PLUGIN_REPO_URL="${PLUGIN_REPO_URL:-}"
fi

# Derive short slug (owner/repo) + owner from the URL: strip the github.com
# scheme/host prefix and any trailing .git, then take the first path segment.
PLUGIN_REPO_SHORT="${PLUGIN_REPO_SHORT:-${PLUGIN_REPO_URL#https://github.com/}}"
PLUGIN_REPO_SHORT="${PLUGIN_REPO_SHORT%.git}"
PLUGIN_OWNER="${PLUGIN_OWNER:-${PLUGIN_REPO_SHORT%%/*}}"

# Well-formedness gate (#2310 phase1: code-reviewer + pr-test-analyzer +
# silent-failure-hunter converged). The github prefix-strip is a no-op for a
# non-github / ssh (git@github.com:owner/repo) / otherwise-malformed URL, which
# would leave PLUGIN_REPO_SHORT carrying scheme/host/':'/'@' artifacts or extra
# path segments — a wrong-but-nonempty identity that would slip past the
# non-empty require_plugin_identity gate. A clean slug is exactly `owner/repo`
# (one '/', no scheme/host chars). Blank SHORT/OWNER on a malformed slug so the
# gate fails closed REGARDLESS of the caller's set -e (the blanking is
# unconditional, not dependent on a jq abort).
if [ -n "$PLUGIN_REPO_URL" ] && ! [[ $PLUGIN_REPO_SHORT =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
	echo "resolve-plugin-identity: PLUGIN_REPO_URL ('$PLUGIN_REPO_URL') is not a parseable https://github.com/owner/repo URL — set PLUGIN_REPO_SHORT/PLUGIN_OWNER explicitly to override" >&2
	PLUGIN_REPO_SHORT=""
	PLUGIN_OWNER=""
fi
export PLUGIN_NAME PLUGIN_REPO_URL PLUGIN_REPO_SHORT PLUGIN_OWNER

# require_plugin_identity — fail-closed gate. Callers source the lib then call
# this before relying on the constants; returns 2 (hard-error) if any identity
# field came out empty (missing/invalid plugin.json), with a loud diagnostic.
require_plugin_identity() {
	if [ -n "${PLUGIN_NAME:-}" ] && [ -n "${PLUGIN_REPO_URL:-}" ] &&
		[ -n "${PLUGIN_REPO_SHORT:-}" ] && [ -n "${PLUGIN_OWNER:-}" ]; then
		return 0
	fi
	echo "resolve-plugin-identity: incomplete identity (NAME='${PLUGIN_NAME:-}' REPO_URL='${PLUGIN_REPO_URL:-}') — check $PLUGIN_JSON" >&2
	return 2
}

# resolve_plugin_cache_base — single override point for the plugin-cache root.
# Default: $HOME/.claude/plugins/cache/<name>/<name> (the doubled-name layout
# Claude Code uses). PLUGIN_CACHE_BASE overrides for tests / non-default installs.
resolve_plugin_cache_base() {
	printf '%s' "${PLUGIN_CACHE_BASE:-$HOME/.claude/plugins/cache/$PLUGIN_NAME/$PLUGIN_NAME}"
}

# resolve_plugin_installed_versions — print installed semver dir NAMES under the
# cache base, ascending (sort -V). Returns 1 if the base is absent or holds no
# semver dirs. Versions are collected into an array first so the `sort -V` pipe
# does not run the loop in a subshell (which would lose the "found any?" state).
resolve_plugin_installed_versions() {
	local base
	base="$(resolve_plugin_cache_base)"
	[ -d "$base" ] || return 1
	local versions=() d v
	for d in "$base"/*/; do
		[ -d "$d" ] || continue
		v="$(basename "$d")"
		case "$v" in
		[0-9]*.[0-9]*.[0-9]*) versions+=("$v") ;;
		esac
	done
	[ "${#versions[@]}" -gt 0 ] || return 1
	printf '%s\n' "${versions[@]}" | sort -V
}

# resolve_plugin_cache_latest — print the absolute path to the highest installed
# semver version dir. Returns 1 if no versions are installed.
resolve_plugin_cache_latest() {
	local versions latest
	versions="$(resolve_plugin_installed_versions)" || return 1
	latest="$(printf '%s\n' "$versions" | tail -1)"
	[ -n "$latest" ] || return 1
	printf '%s' "$(resolve_plugin_cache_base)/$latest"
}
