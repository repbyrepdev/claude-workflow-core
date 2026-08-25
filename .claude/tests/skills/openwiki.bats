#!/usr/bin/env bats
# covers: skills/openwiki/run.sh
#
# (#2629) The wrapper exists to make two expensive lessons MECHANICAL rather
# than advisory: `openwiki --init` rewrites AGENTS.md/CLAUDE.md in the git
# root (so a dirty tree bundles unrelated files AND trips this repo's
# byte-SSOT gates), and a just-installed MCP server is not usable until the
# next session. These tests drive the REAL wrapper in a throwaway repo with a
# PATH-stubbed `openwiki` and a fixture HOME, asserting the refusals and the
# state reporting — never mere source presence.
#
# FIXTURE LAYOUT (deliberate): $TEST_TMP holds `repo/` (the git repo under
# test) alongside `bin/` and `home/`. Those two MUST live outside the repo —
# nested, they show as untracked files and every "clean tree" assertion
# silently inverts. $TEST_TMP itself is not a git repo, which is also what
# the outside-a-repo test needs.
# shellcheck disable=SC2030,SC2031

setup() {
	PLUGIN=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	SKILL="$PLUGIN/skills/openwiki/run.sh"
	[ -x "$SKILL" ]
	TEST_TMP=$(mktemp -d -t openwiki-skill.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	REPO="$TEST_TMP/repo"
	(
		set -e
		mkdir -p "$REPO" "$TEST_TMP/bin" "$TEST_TMP/home"
		cd "$REPO"
		git init -q
		git config user.email t@t
		git config user.name t
		git commit -q --allow-empty -m init
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */openwiki-skill.* ]] && rm -rf "$TEST_TMP"
}

_stub_cli() { # $1 = version string to report
	printf '#!/usr/bin/env bash\n[ "$1" = "--version" ] && { echo "%s"; exit 0; }\nexit 0\n' "$1" >"$TEST_TMP/bin/openwiki"
	chmod +x "$TEST_TMP/bin/openwiki"
}

# $1 = json for .mcpServers.openwiki, or "" to omit the key entirely
_write_claude_json() {
	if [ -z "$1" ]; then
		echo '{"mcpServers":{}}' >"$TEST_TMP/home/.claude.json"
	else
		jq -n --argjson e "$1" '{mcpServers: {openwiki: $e}}' >"$TEST_TMP/home/.claude.json"
	fi
}

_commit_all() { (cd "$REPO" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m fixture); }

_run_skill() { # $1 = subcommand; PATH includes the stub bin, HOME is the fixture
	run env PATH="$TEST_TMP/bin:$PATH" HOME="$TEST_TMP/home" bash -c "cd '$REPO' && '$SKILL' $1"
}

@test "usage: no subcommand exits 2; --help exits 0" {
	run env HOME="$TEST_TMP/home" bash -c "cd '$REPO' && '$SKILL'"
	[ "$status" -eq 2 ]
	[[ $output == *"subcommand required"* ]]
	run env HOME="$TEST_TMP/home" bash -c "cd '$REPO' && '$SKILL' --help"
	[ "$status" -eq 0 ]
	[[ $output == *"Usage:"* ]]
}

@test "unknown subcommand exits 2 naming the bad arg" {
	run env HOME="$TEST_TMP/home" bash -c "cd '$REPO' && '$SKILL' generate-everything"
	[ "$status" -eq 2 ]
	[[ $output == *"generate-everything"* ]]
}

@test "outside a git repo: exits 2 (openwiki operates on a repo tree)" {
	# $TEST_TMP is deliberately NOT a git repo — the repo is its child.
	run env HOME="$TEST_TMP/home" bash -c "cd '$TEST_TMP' && '$SKILL' status"
	[ "$status" -eq 2 ]
	[[ $output == *"not inside a git repo"* ]]
}

@test "status reports every axis: CLI absent, MCP unwired, no openwiki/, clean tree" {
	_write_claude_json ""
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"CLI:       absent"* ]]
	[[ $output == *"not wired"* ]]
	[[ $output == *"never generated"* ]]
	[[ $output == *"Tree:      clean"* ]]
}

@test "status reports the installed CLI version and wired MCP" {
	_stub_cli "openwiki/0.4.0"
	_write_claude_json '{"command":"openwiki","args":["mcp","--host","claude"]}'
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"0.4.0"* ]]
	[[ $output == *"MCP:       wired"* ]]
	[[ $output != *"SOURCE-BUILD HACK"* ]]
}

@test "status FLAGS the obsolete source-build MCP wiring (the office-mini hack)" {
	# operations.md Install: a ~/.openwiki-main entry means the machine predates
	# 0.4.0's native integration and should be superseded, not copied.
	_stub_cli "openwiki/0.4.0"
	_write_claude_json '{"command":"node","args":["/Users/x/.openwiki-main/dist/cli/cli.js","mcp","--host","claude"]}'
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"SOURCE-BUILD HACK"* ]]
}

@test "status distinguishes a generated repo WITHOUT the steering channel" {
	_write_claude_json ""
	mkdir -p "$REPO/openwiki"
	echo "# generated" >"$REPO/openwiki/quickstart.md"
	_commit_all
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"NO INSTRUCTIONS.md"* ]]
	# ...and reports it present once the channel exists.
	echo "rules" >"$REPO/openwiki/INSTRUCTIONS.md"
	_commit_all
	_run_skill status
	[[ $output == *"the steering channel"* ]]
}

@test "preflight REFUSES a dirty tree, naming gotcha 5 (rc 1)" {
	_stub_cli "openwiki/0.4.0"
	_write_claude_json '{"command":"openwiki","args":["mcp"]}'
	echo "uncommitted" >"$REPO/scratch.txt"
	_run_skill preflight
	[ "$status" -eq 1 ]
	[[ $output == *"working tree is dirty"* ]]
	[[ $output == *"AGENTS.md"* ]]
	[[ $output == *"gotcha 5"* ]]
}

@test "preflight REFUSES when the CLI is absent, pointing at bootstrap-machine" {
	_write_claude_json ""
	_run_skill preflight
	[ "$status" -eq 1 ]
	[[ $output == *"CLI not installed"* ]]
	[[ $output == *"bootstrap-machine.sh"* ]]
}

@test "preflight PASSES on a clean tree with the CLI present (not over-broad)" {
	_stub_cli "openwiki/0.4.0"
	_write_claude_json '{"command":"openwiki","args":["mcp"]}'
	_run_skill preflight
	[ "$status" -eq 0 ]
	[[ $output == *"preflight OK"* ]]
}

@test "doctor reports state, runs the refusals, and states the session-restart rule" {
	_write_claude_json ""
	echo "dirty" >"$REPO/scratch.txt"
	_run_skill doctor
	# doctor never fails on state — it is diagnostic.
	[ "$status" -eq 0 ]
	[[ $output == *"openwiki status"* ]]
	[[ $output == *"REFUSING"* ]]
	[[ $output == *"SESSION START"* ]]
	[[ $output == *"INSTRUCTIONS.md"* ]]
}
