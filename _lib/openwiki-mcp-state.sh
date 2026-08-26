#!/bin/bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`: sourcing scripts define their own option discipline, and
# inheriting `set -e` + pipefail aborts callers that use fail-soft idioms.
#
# auto-register: false
# (#2629) SSOT for the openwiki state probes. The filename says mcp-state
# because that was the first one; it now also owns the installed-version
# probe, for the same reason — two callers, one question, and duplicating the
# MCP parse is precisely what grew the same fail-open bug in both copies.
#
# Question 1: what state is the openwiki MCP entry in?
#
# Two callers ask it — scripts/bootstrap-machine.sh (which REPAIRS) and
# skills/openwiki-lane/run.sh (which REPORTS) — and their policies genuinely
# differ: a missing `jq` means "run the installer" to one and "I cannot tell
# you" to the other. That divergence belongs in the callers. The PARSING does
# not, and duplicating it produced the identical fail-open bug in both copies:
# `jq -e .mcpServers.openwiki` is truthy for a string, `"str" | (.args // [])`
# then errors to EMPTY stdout, and empty read as "wired". Fixing one copy is
# how the other was found. Parse here; map the token to policy there.
#
# openwiki_mcp_state <config-path>
#   Echoes exactly ONE token and always returns 0 — the state IS the answer,
#   so a caller never has to distinguish "the probe failed" from "the probe
#   says no":
#
#     no-config      path missing or unreadable
#     no-jq          jq is not on PATH, so nothing could be parsed
#                    (deliberately NOT "not wired" — re-running an installer
#                    cannot fix a missing jq)
#     bad-json       the file is not valid JSON
#     unreadable     .mcpServers is not an object, so the lookup could not run
#     not-wired      no .mcpServers.openwiki entry
#     bad-entry:<t>  an entry exists but is a <t>, not an object
#     bad-args:<t>   the entry is an object but .args is a <t>, not an array
#     source-hack    wired to the obsolete ~/.openwiki-main source build
#     wired          a valid published-CLI entry
openwiki_mcp_state() {
	local cfg="${1:-}" t args rc

	if [ -z "$cfg" ] || [ ! -r "$cfg" ]; then
		echo "no-config"
		return 0
	fi
	command -v jq >/dev/null 2>&1 || {
		echo "no-jq"
		return 0
	}
	if ! jq -e . "$cfg" >/dev/null 2>&1; then
		echo "bad-json"
		return 0
	fi

	# Branch on TYPE, never on truthiness. A jq failure here means .mcpServers
	# itself is not an object, which is a different problem from an absent
	# entry, so it gets its own token rather than collapsing into not-wired.
	rc=0
	t=$(jq -r '.mcpServers.openwiki | type' "$cfg" 2>/dev/null) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "unreadable"
		return 0
	fi
	case "$t" in
	null)
		echo "not-wired"
		return 0
		;;
	object) ;;
	*)
		echo "bad-entry:$t"
		return 0
		;;
	esac

	# `.args // []` keeps a legitimately absent .args valid. Assert the type
	# rather than trusting jq to error: `join` REJECTS a string but happily
	# joins an OBJECT's values, so an rc check alone lets {"a":1} pass.
	rc=0
	t=$(jq -r '.mcpServers.openwiki | (.args // []) | type' "$cfg" 2>/dev/null) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "bad-args:unreadable"
		return 0
	fi
	if [ "$t" != "array" ]; then
		echo "bad-args:$t"
		return 0
	fi

	args=$(jq -r '.mcpServers.openwiki | (.args // []) | join(" ")' "$cfg" 2>/dev/null) || args=""
	case "$args" in
	*openwiki-main*) echo "source-hack" ;;
	*) echo "wired" ;;
	esac
	return 0
}

# Resolve a PATH entry through its symlinks WITHOUT depending on `readlink -f`
# (a GNU-ism macOS only grew recently; this repo runs on bash 3.2).
# Echoes the real path; rc 1 if it cannot be resolved.
_openwiki_realpath() {
	local p="${1:-}" target hops=0
	[ -n "$p" ] || return 1
	while [ -L "$p" ] && [ "$hops" -lt 40 ]; do
		target=$(readlink "$p") || return 1
		case "$target" in
		/*) p=$target ;;
		*) p=$(dirname "$p")/$target ;;
		esac
		hops=$((hops + 1))
	done
	[ -e "$p" ] || return 1
	printf '%s\n' "$p"
}

# Question 2: which openwiki version is actually installed — meaning the one
# `command -v openwiki` resolves to, which is the binary that will actually
# run and the one both callers already gate on.
#
# Echoes exactly ONE token, always rc 0, same contract as its sibling:
#
#   no-cli        nothing named openwiki on PATH
#   no-jq         jq absent, so no package.json can be parsed
#   unresolvable  the PATH entry could not be followed to a real file
#   not-found     resolved, but no openwiki package.json above it
#   bad-version   found the package, but .version is missing or not a semver
#   <semver>      the version that binary belongs to
#
# Do NOT ask the CLI: `openwiki --version` is not a supported flag (the real
# binary answers "Unknown option: --version"), which is how the every-run
# reinstall bug shipped.
#
# Do NOT use `npm root -g` either — that answers "what did npm-global
# install", while the callers gate on PATH. A CLI from volta/pnpm/asdf, or the
# ~/.openwiki-main source build this repo tracks, resolves on PATH and is
# invisible to npm's root: the pin check would either reinstall on every run
# (the same bug relocated) or, worse, report "at the pin" about a package that
# is NOT the binary being run. Walk up from the resolved binary instead.
openwiki_installed_version() {
	local bin real dir name v
	bin=$(command -v openwiki 2>/dev/null) || bin=""
	if [ -z "$bin" ]; then
		echo "no-cli"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		echo "no-jq"
		return 0
	fi
	real=$(_openwiki_realpath "$bin") || real=""
	if [ -z "$real" ]; then
		echo "unresolvable"
		return 0
	fi
	# Nearest ancestor package.json that IS openwiki's — matched on .name
	# rather than "first package.json found", so a stray dist/package.json
	# cannot answer for the package.
	dir=$(dirname "$real")
	while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
		if [ -r "$dir/package.json" ]; then
			name=$(jq -r '.name // empty' "$dir/package.json" 2>/dev/null) || name=""
			if [ "$name" = "openwiki" ]; then
				v=$(jq -r '.version // empty' "$dir/package.json" 2>/dev/null) || v=""
				# NORMALISE. `.version` is a string the package writes about
				# itself, in a user-writable directory, and it is echoed into
				# operator logs and into an agent's status context. jq passes
				# embedded ANSI escapes and newlines through untouched, so
				# anything that is not a bare semver is refused, not rendered.
				case "$v" in
				[0-9]*.[0-9]*.[0-9]*)
					case "$v" in
					*[!0-9.]*) echo "bad-version" ;;
					*) echo "$v" ;;
					esac
					;;
				*) echo "bad-version" ;;
				esac
				return 0
			fi
		fi
		dir=$(dirname "$dir")
	done
	echo "not-found"
	return 0
}

# EXECUTED directly (not sourced): a one-shot CLI over BOTH probes, so each
# can be exercised as itself — by an operator debugging a machine, and by
# prove-yourself retest evidence, which requires a cycle-critical file in
# COMMAND position rather than only inside a bats fixture. The version probe
# is the one whose bug got past the whole suite and was caught only by running
# the real thing, so it needs this surface most.
#
# A bare first argument still means mcp-state, so the existing lockstep test
# and the stored retest command keep working. Sourcing callers never get here.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	case "${1:-}" in
	installed-version) openwiki_installed_version ;;
	mcp-state) openwiki_mcp_state "${2:-}" ;;
	*) openwiki_mcp_state "${1:-}" ;;
	esac
fi
