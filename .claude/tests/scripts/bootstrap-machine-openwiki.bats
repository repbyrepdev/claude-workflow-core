#!/usr/bin/env bats
# covers: scripts/bootstrap-machine.sh
#
# (#2629) bootstrap-machine had NO suite before this. These tests pin the
# OpenWiki step specifically — the machine lane that makes the free in-chat
# MCP path exist — plus the one honesty property that is easy to regress:
# `--dry-run` must ANNOUNCE the MCP wiring it would perform. A bare
# `command -v openwiki` guard hides that step under dry-run (nothing was
# installed), turning a preview into a silent skip.
#
# The script is macOS/Homebrew and mutates a real machine, so these drive it
# ONLY in --dry-run with a fixture HOME. Nothing here installs anything.
# shellcheck disable=SC2030,SC2031

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SCRIPT="$REPO_ROOT/scripts/bootstrap-machine.sh"
	[ -x "$SCRIPT" ]
	TEST_TMP=$(mktemp -d -t bm-openwiki.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/home"
}

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */bm-openwiki.* ]] && rm -rf "$TEST_TMP"
}

_write_claude_json() { # $1 = json for .mcpServers.openwiki, "" = key absent
	if [ -z "$1" ]; then
		echo '{"mcpServers":{}}' >"$TEST_TMP/home/.claude.json"
	else
		jq -n --argjson e "$1" '{mcpServers: {openwiki: $e}}' >"$TEST_TMP/home/.claude.json"
	fi
}

# Dry-run the real script with a fixture HOME. Output is stderr (_log/_run
# both write there), so merge it via `run`'s combined capture.
_dry_run() {
	run env HOME="$TEST_TMP/home" bash "$SCRIPT" --dry-run
}

@test "dry-run announces the pinned openwiki install" {
	_write_claude_json ""
	_dry_run
	[[ $output == *"openwiki@"* ]]
	[[ $output == *"npm install -g openwiki@"* ]]
}

@test "dry-run ANNOUNCES the MCP wiring it would perform (no silent skip)" {
	# The regression this guards: gating the wiring block on `command -v
	# openwiki` alone means dry-run (which installed nothing) hides the step.
	_write_claude_json ""
	_dry_run
	[[ $output == *"integrations install claude"* ]]
}

@test "dry-run states the session-restart requirement" {
	# The MCP server is read at session start; without this line an operator
	# reasonably expects the tool to appear immediately.
	_write_claude_json ""
	_dry_run
	[[ $output == *"restart the Claude Code session"* ]]
}

@test "already-wired MCP is reported as satisfied, not re-wired" {
	_write_claude_json '{"command":"openwiki","args":["mcp","--host","claude"]}'
	_dry_run
	[[ $output == *"MCP server already wired"* ]]
	[[ $output != *"wiring the openwiki MCP server"* ]]
}

@test "the obsolete source-build wiring is REPLACED, not accepted as wired" {
	# ~/.openwiki-main is the pre-0.4.0 hack. Treating it as "already wired"
	# would strand a machine on a build that only exists locally.
	_write_claude_json '{"command":"node","args":["/Users/x/.openwiki-main/dist/cli/cli.js","mcp"]}'
	_dry_run
	[[ $output == *"wiring the openwiki MCP server"* ]]
	[[ $output != *"MCP server already wired"* ]]
}

@test "OPENWIKI_PIN overrides the default pin (toolchain stays controllable)" {
	_write_claude_json ""
	run env HOME="$TEST_TMP/home" OPENWIKI_PIN=9.9.9 bash "$SCRIPT" --dry-run
	[[ $output == *"openwiki@9.9.9"* ]]
}
