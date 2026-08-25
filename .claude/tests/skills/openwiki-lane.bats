#!/usr/bin/env bats
# covers: skills/openwiki-lane/run.sh
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
	SKILL="$PLUGIN/skills/openwiki-lane/run.sh"
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

@test "version probe: multi-line --version does NOT double-emit (p1r1)" {
	# `cmd | head -1 || echo fallback` fires the fallback on the PIPELINE
	# status: head closes the pipe, SIGPIPE + pipefail mark it failed, and the
	# status table gets TWO lines in a one-line field.
	cd "$REPO" || return 1
	printf '#!/usr/bin/env bash\necho "openwiki/0.4.0"\necho "extra banner line"\necho "third"\nexit 0\n' >"$TEST_TMP/bin/openwiki"
	chmod +x "$TEST_TMP/bin/openwiki"
	_write_claude_json ""
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"0.4.0"* ]]
	[[ $output != *"version unreadable"* ]]
	# exactly one CLI line
	[ "$(printf '%s\n' "$output" | grep -c 'CLI:')" -eq 1 ]
}

@test "version probe: empty --version output reports unreadable, not blank (p1r1)" {
	cd "$REPO" || return 1
	printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bin/openwiki"
	chmod +x "$TEST_TMP/bin/openwiki"
	_write_claude_json ""
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"version unreadable"* ]]
}

@test "MCP probe: corrupt ~/.claude.json is an ERROR state, not 'not wired' (p1r1)" {
	# Reporting a corrupt config as "not wired" routes the operator to re-run
	# bootstrap-machine, which cannot fix invalid JSON.
	cd "$REPO" || return 1
	printf 'NOT JSON{{{' >"$TEST_TMP/home/.claude.json"
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"not valid JSON"* ]]
	[[ $output != *"MCP:       not wired"* ]]
}

@test "MCP probe: absent ~/.claude.json is reported as its own state (p1r1)" {
	cd "$REPO" || return 1
	rm -f "$TEST_TMP/home/.claude.json"
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"no ~/.claude.json"* ]]
}

@test "tree probe FAILS CLOSED: a git error is UNKNOWN and refuses (p1r1)" {
	# The wrapper's primary refusal used to test only git's OUTPUT, so a
	# corrupt index (rc 128, EMPTY stdout) read as "clean" and preflight said
	# "safe to run" over uncommitted work.
	cd "$REPO" || return 1
	_stub_cli "openwiki/0.4.0"
	_write_claude_json ""
	printf 'GARBAGE' >"$REPO/.git/index"
	_run_skill status
	[[ $output == *"Tree:      UNKNOWN"* ]]
	_run_skill preflight
	[ "$status" -eq 1 ]
	[[ $output == *"cannot determine tree state"* ]]
	[[ $output != *"preflight OK"* ]]
}

@test "SKILL.md documents only invocations that actually exist (p1r1)" {
	# Five reviewers caught SKILL.md advertising `--with-openwiki`, a flag
	# bootstrap-repo.sh rejects with exit 2. Any flag the skill tells an agent
	# to pass must be one the script accepts.
	local skill_md="$PLUGIN/skills/openwiki-lane/SKILL.md"
	local boot="$PLUGIN/scripts/bootstrap-repo.sh"
	local flags
	flags=$(grep -oE 'bootstrap-repo\.sh[^`]*--[a-z-]+' "$skill_md" | grep -oE '\-\-[a-z-]+' | sort -u || true)
	for f in $flags; do
		grep -qE "^[[:space:]]*$f\)" "$boot" || {
			echo "SKILL.md documents $f but bootstrap-repo.sh has no such flag"
			return 1
		}
	done
	# And the run.sh subcommands it advertises must all be real.
	for c in status preflight doctor; do
		grep -q "run.sh $c" "$skill_md" || {
			echo "SKILL.md stopped documenting the $c subcommand"
			return 1
		}
		run env HOME="$TEST_TMP/home" bash -c "cd '$REPO' && '$SKILL' $c"
		[ "$status" -ne 2 ] || {
			echo "$c is documented but rejected as a usage error"
			return 1
		}
	done
}
