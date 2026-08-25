#!/usr/bin/env bats
# covers: scripts/bootstrap-machine.sh
#
# (#2629) bootstrap-machine had NO suite before this. These tests pin the
# OpenWiki step — the machine lane that makes the free in-chat MCP path
# exist — plus two honesty properties that are easy to regress:
#   * `--dry-run` must ANNOUNCE the MCP wiring it would perform (a bare
#     `command -v openwiki` guard hides it, since nothing was installed).
#   * a REAL run with no CLI on PATH must WARN that it skipped the wiring
#     rather than silently omitting the section.
#
# p1r1 test-analyzer, both fixed here:
#   * NOT ONE test asserted exit status, and the script genuinely exits 2 on
#     a machine where `gh api releases/latest` returns nothing — so the suite
#     was 6/6 green against an aborting script. Every test now asserts rc,
#     and passes --tag to sidestep that network lookup entirely.
#   * The suite depended on `openwiki` being ABSENT from the ambient PATH —
#     which this very step exists to make false. PATH is now controlled, so
#     both the installed and not-installed branches are driven deliberately.
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
	mkdir -p "$TEST_TMP/home" "$TEST_TMP/bin"
	# Real tools the script needs, minus anything that would make the
	# openwiki branch nondeterministic.
	# Only the tools that do NOT live in /usr/bin:/bin need linking in.
	for t in jq brew npm gh; do
		p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$TEST_TMP/bin/$t"
	done
	# Fail LOUD rather than silently testing the wrong branch: this suite's
	# not-installed cases depend on openwiki being unreachable via
	# /usr/bin:/bin (it installs to a brew/npm prefix instead).
	if [ -x /usr/bin/openwiki ] || [ -x /bin/openwiki ]; then
		echo "FATAL: openwiki present in /usr/bin or /bin — fixture PATH isolation broken" >&2
		return 1
	fi
	# Earlier steps `exit 2` when these are missing (semgrep block on pip3,
	# coderabbit block on npm), which would abort before the openwiki section
	# under test. Stubs make those steps take their already-installed path.
	for t in semgrep coderabbit pip3; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bin/$t"
		chmod +x "$TEST_TMP/bin/$t"
	done
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

_stub_openwiki() { # put a fake CLI on the controlled PATH
	printf '#!/usr/bin/env bash\n[ "$1" = "--version" ] && { echo "openwiki/0.4.0"; exit 0; }\nexit 0\n' >"$TEST_TMP/bin/openwiki"
	chmod +x "$TEST_TMP/bin/openwiki"
}

# --tag pins the plugin version so the script never reaches the network
# `gh api releases/latest` lookup (which exits 2 when it returns nothing).
_dry_run() {
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" bash "$SCRIPT" --dry-run --tag v0.0.0
}

@test "dry-run SUCCEEDS and announces the pinned openwiki install" {
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"npm install -g openwiki@"* ]]
}

@test "dry-run ANNOUNCES the MCP wiring it would perform (no silent skip)" {
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"integrations install claude"* ]]
}

@test "dry-run states the session-restart requirement" {
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"restart the Claude Code session"* ]]
}

@test "already-installed CLI is reported, not reinstalled" {
	# Previously unreachable: the suite silently relied on openwiki being
	# absent from the ambient PATH, so this branch had zero coverage.
	_stub_openwiki
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"openwiki CLI already installed"* ]]
	[[ $output != *"npm install -g openwiki@"* ]]
}

@test "already-wired MCP is reported as satisfied, not re-wired" {
	_stub_openwiki
	_write_claude_json '{"command":"openwiki","args":["mcp","--host","claude"]}'
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"MCP server already wired"* ]]
	[[ $output != *"wiring the openwiki MCP server"* ]]
}

@test "the obsolete source-build wiring is REPLACED, not accepted as wired" {
	# ~/.openwiki-main is the pre-0.4.0 hack. Treating it as "already wired"
	# would strand a machine on a build that only exists locally.
	_stub_openwiki
	_write_claude_json '{"command":"node","args":["/Users/x/.openwiki-main/dist/cli/cli.js","mcp"]}'
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"wiring the openwiki MCP server"* ]]
	[[ $output != *"MCP server already wired"* ]]
}

@test "OPENWIKI_PIN overrides the default pin (toolchain stays controllable)" {
	_write_claude_json ""
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" OPENWIKI_PIN=9.9.9 \
		bash "$SCRIPT" --dry-run --tag v0.0.0
	[ "$status" -eq 0 ]
	[[ $output == *"openwiki@9.9.9"* ]]
}

@test "REAL run with no CLI on PATH WARNS that it skipped the wiring (not silent)" {
	# The DRY_RUN guard fixed the preview; this pins the ACTUAL run, which is
	# where the silent skip lived. Reachable because the npm-absent branch
	# warns-and-continues (unlike its siblings, which exit 2) and because the
	# npm global bin may not be on PATH.
	#
	# SAFETY: this is the one test that runs without --dry-run, so every
	# mutating command is stubbed — `brew` reports each formula as already
	# installed (so no `brew install` ever fires on the developer's machine),
	# and gh/security are no-ops. HOME is the fixture, so nothing touches the
	# real ~/.claude. The openwiki section runs BEFORE the plugin-cache clone,
	# so the assertions land before any network step.
	# rm FIRST: these fixture entries are symlinks to the real binaries, and
	# `printf > symlink` writes THROUGH the link — i.e. straight into
	# /opt/homebrew/bin/gh. Removing the link makes the redirect create a
	# plain file in the fixture instead.
	# git is stubbed too so the plugin-cache clone cannot reach the network
	# (and cannot abort the run before the end-of-run summary asserted below).
	rm -f "$TEST_TMP/bin/brew" "$TEST_TMP/bin/gh" "$TEST_TMP/bin/security" "$TEST_TMP/bin/git"
	for t in brew gh security git; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bin/$t"
		chmod +x "$TEST_TMP/bin/$t"
	done
	rm -f "$TEST_TMP/bin/npm" "$TEST_TMP/bin/openwiki"
	_write_claude_json ""
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" bash "$SCRIPT" --tag v0.0.0
	[[ $output == *"npm not available"* ]]
	[[ $output == *"SKIPPED the MCP wiring"* ]]
	# ...and the skip is surfaced again at the end, so automation cannot read
	# an openwiki-less bootstrap as clean.
	[[ $output == *"MCP wiring was SKIPPED"* ]]
}
