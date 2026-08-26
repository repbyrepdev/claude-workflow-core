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

# Question 2: which openwiki version is actually installed?
#
# Echoes a bare semver, or NOTHING when it cannot be determined — callers
# decide what absence means (bootstrap-machine treats it as pin drift and
# reinstalls; the skill reports it as unreadable).
#
# Do NOT ask the CLI. `openwiki --version` is not a supported flag — the real
# binary answers "Unknown option: --version" — and the first version of this
# check believed otherwise, so a correctly pinned machine reinstalled on every
# run. `openwiki --help` does print the version, but boots the whole agent
# banner to do it. The installed package is offline, authoritative, and
# independent of whichever flags the CLI exposes this release.
openwiki_installed_version() {
	local root
	root=$(npm root -g 2>/dev/null) || return 0
	[ -n "$root" ] && [ -r "$root/openwiki/package.json" ] || return 0
	jq -r '.version // empty' "$root/openwiki/package.json" 2>/dev/null
}

# EXECUTED directly (not sourced): behave as a one-shot CLI over the same
# function. `openwiki-mcp-state.sh <config-path>` prints the token.
#
# This exists so the probe can be exercised as itself — by an operator
# debugging a machine, and by prove-yourself retest evidence, which requires a
# cycle-critical file to appear in COMMAND position rather than only inside a
# bats fixture. Sourcing callers never reach this block.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	openwiki_mcp_state "${1:-}"
fi
