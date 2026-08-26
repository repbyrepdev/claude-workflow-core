#!/usr/bin/env bats
# covers: scripts/bootstrap-machine.sh scripts/meta-bootstrap-manifest.yml
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
	#
	# jq and npm are LOAD-BEARING, so their absence fails loud: jq backs
	# _write_claude_json and every MCP-state assertion, npm backs every
	# install/reinstall assertion (without it the script takes its
	# npm-not-available branch and the failure names an output mismatch
	# rather than the missing tool). brew and gh stay soft — the steps that
	# use them are stubbed or irrelevant here.
	for t in jq npm; do
		p=$(command -v "$t" 2>/dev/null) || {
			echo "FATAL: required fixture tool '$t' not on PATH — this suite cannot test what it claims to" >&2
			return 1
		}
		ln -sf "$p" "$TEST_TMP/bin/$t"
	done
	for t in brew gh; do
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

_stub_openwiki() { # $1 = version the INSTALLED PACKAGE reports ("" = unreadable)
	# The CLI itself is a bare stub: the version probe deliberately does NOT
	# ask it anything. `openwiki --version` is not a supported flag, and a
	# fixture that implements one is a fixture proving the stub honours a
	# contract the real CLI never had — which is exactly how the every-run
	# reinstall bug shipped.
	printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bin/openwiki"
	chmod +x "$TEST_TMP/bin/openwiki"
	# The probe reads $(npm root -g)/openwiki/package.json, so drive it there.
	mkdir -p "$TEST_TMP/npmroot"
	rm -rf "$TEST_TMP/npmroot/openwiki"
	if [ -n "${1-0.4.0}" ]; then
		mkdir -p "$TEST_TMP/npmroot/openwiki"
		printf '{"version":"%s"}' "${1-0.4.0}" >"$TEST_TMP/npmroot/openwiki/package.json"
	fi
	# npm stub: answers `root -g` with the fixture root, no-ops otherwise so
	# the install paths stay drivable.
	rm -f "$TEST_TMP/bin/npm"
	printf '#!/usr/bin/env bash\nif [ "$1" = "root" ]; then echo "%s"; exit 0; fi\nexit 0\n' \
		"$TEST_TMP/npmroot" >"$TEST_TMP/bin/npm"
	chmod +x "$TEST_TMP/bin/npm"
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
	[[ $output == *"already installed at the pin (0.4.0)"* ]]
	[[ $output != *"npm install -g openwiki@"* ]]
}

@test "an installed CLI at the WRONG version is reinstalled at the pin (p2r1)" {
	# `command -v openwiki` enforces "some openwiki exists" — the one thing a
	# pin is meant to rule out. A machine that installed 0.3.x before this
	# step existed kept it forever while the repo-side toolchain pin moved,
	# which is precisely the two-lanes-disagree failure the lockstep test
	# exists to prevent.
	_stub_openwiki "openwiki/0.3.1"
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"openwiki is 0.3.1, pin is 0.4.0 — reinstalling"* ]]
	[[ $output == *"npm install -g openwiki@0.4.0"* ]]
	[[ $output != *"already installed at the pin"* ]]
}

@test "the version comes from the INSTALLED PACKAGE, not a CLI flag (ci-followup)" {
	# The probe used to run `openwiki --version`, which the real CLI answers
	# with "Unknown option: --version" — so a correctly pinned machine read as
	# unreadable and reinstalled on every run. It reads
	# $(npm root -g)/openwiki/package.json now: offline, authoritative, and
	# independent of whichever flags the CLI exposes this release.
	#
	# No `openwiki` invocation is stubbed for versioning at all, which is the
	# point — a fixture that answers --version proves the STUB honours a
	# contract, not the CLI.
	_stub_openwiki "0.4.0"
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"already installed at the pin (0.4.0)"* ]]
	[[ $output != *"reinstalling"* ]]
}

@test "an UNREADABLE version counts as a mismatch, not as 'fine' (p2r1)" {
	# "cannot confirm the pin holds" must not report as "the pin holds".
	_stub_openwiki ""
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"an unreadable version, pin is 0.4.0 — reinstalling"* ]]
	[[ $output != *"already installed at the pin"* ]]
}

@test "version drift with no npm WARNS and hands over the command (p2r1)" {
	# The correction needs npm. Without it the run must still refuse to call
	# the drifted install healthy — the same warn-and-continue shape as the
	# no-CLI-at-all case, but naming the version it actually found.
	_stub_openwiki "openwiki/0.3.1"
	rm -f "$TEST_TMP/bin/npm"
	_write_claude_json ""
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"openwiki is 0.3.1, pin is 0.4.0,"* ]]
	[[ $output == *"npm install -g openwiki@0.4.0"* ]]
	[[ $output != *"already installed at the pin"* ]]
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

@test "a MALFORMED MCP entry is re-wired, not accepted as wired (p2r3)" {
	# The inline condition here reported malformed entries as WIRED: `jq -e
	# .mcpServers.openwiki` is truthy for a string, `"str" | (.args // [])`
	# then errors to EMPTY stdout, and `! grep -q openwiki-main` reads empty
	# as "not the hack". So a hand-broken config took the already-wired path
	# and the repair this step exists to perform never ran.
	_stub_openwiki
	for bad in '"just-a-string"' '42' 'true' '["a"]' \
		'{"command":"openwiki","args":"mcp"}' \
		'{"command":"openwiki","args":{"a":1}}'; do
		_write_claude_json "$bad"
		_dry_run
		[ "$status" -eq 0 ]
		[[ $output == *"wiring the openwiki MCP server"* ]] || {
			echo "entry $bad was NOT re-wired: $output"
			return 1
		}
		[[ $output != *"MCP server already wired"* ]] || {
			echo "entry $bad reported already wired: $output"
			return 1
		}
	done
	# Invalid JSON entirely must also route to the repair, not to "wired".
	printf 'NOT JSON{{{' >"$TEST_TMP/home/.claude.json"
	_dry_run
	[ "$status" -eq 0 ]
	[[ $output == *"wiring the openwiki MCP server"* ]]
	[[ $output != *"MCP server already wired"* ]]
}

@test "--help exits 0 despite the file's comment count (ci-r1)" {
	# `grep '^#' "$0" | head -28` makes head close the pipe, grep take
	# SIGPIPE, and `set -o pipefail` + `set -e` abort the help path BEFORE its
	# own `exit 0` — so --help returned non-zero once this file grew past 28
	# comment lines, which the OpenWiki block did. Nothing covered --help.
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" bash "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"bootstrap-machine"* ]]
	# Still prints a usable help body, not one truncated line.
	[ "$(printf '%s\n' "$output" | wc -l)" -ge 10 ]
}

@test "a FAILED openwiki install degrades, it does not abort the bootstrap (ci-r1)" {
	# `_run` under `set -e` made every OpenWiki command load-bearing for the
	# WHOLE run: a registry blip during the install would abort before the
	# plugin cache, the Keychain report and the summary. The section already
	# warns-and-continues when npm is MISSING; a FAILED install has to degrade
	# the same way.
	# Stub the LATER real-run steps (gh extension install, brew, security,
	# git) so the only failure under test is the openwiki one — an
	# unauthenticated `gh` would otherwise abort the run after this section
	# and the assertion would pass for the wrong reason.
	rm -f "$TEST_TMP/bin/brew" "$TEST_TMP/bin/gh" "$TEST_TMP/bin/security" "$TEST_TMP/bin/git"
	for t in brew gh security git; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bin/$t"
		chmod +x "$TEST_TMP/bin/$t"
	done
	rm -f "$TEST_TMP/bin/npm"
	printf '#!/usr/bin/env bash\necho "npm ERR! network timeout" >&2\nexit 1\n' >"$TEST_TMP/bin/npm"
	chmod +x "$TEST_TMP/bin/npm"
	rm -f "$TEST_TMP/bin/openwiki"
	_write_claude_json ""
	# A REAL run (not --dry-run): _run only executes for real.
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" bash "$SCRIPT" --tag v0.0.0
	[ "$status" -eq 0 ]
	[[ $output == *"FAILED"* ]]
	# The run REACHES its end rather than dying at the failed install...
	[[ $output == *"bootstrap-machine complete"* ]]
	# ...and the summary says the wiring was skipped, so automation cannot
	# read an openwiki-less bootstrap as clean.
	[[ $output == *"MCP wiring was SKIPPED"* ]]
}

@test "openwiki is registered in the machine-verification SSOT (#2632)" {
	# meta-bootstrap.sh verifies a machine against targets.machine in
	# scripts/meta-bootstrap-manifest.yml. A tool this script INSTALLS but
	# that the manifest does not list is unverifiable: a machine that skipped
	# the step, or lost the CLI to an npm prefix change, still reports clean.
	# The manifest suite drives stub manifests only, so nothing else pins the
	# real file's contents.
	run env M="openwiki" yq -r '.targets.machine.commands[] | select(. == strenv(M))' \
		"$REPO_ROOT/scripts/meta-bootstrap-manifest.yml"
	[ "$status" -eq 0 ]
	[ "$output" = "openwiki" ] || {
		echo "targets.machine.commands does not list openwiki"
		return 1
	}
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
	# A missing npm is a WARN-and-continue by design (openwiki is one step of a
	# machine bootstrap, not its point). Asserting rc here is what separates
	# that deliberate degrade from the script aborting — the exact confusion
	# that let this suite run 6/6 green against a script exiting 2.
	[ "$status" -eq 0 ]
	[[ $output == *"npm not available"* ]]
	[[ $output == *"SKIPPED the MCP wiring"* ]]
	# ...and the skip is surfaced again at the end, so automation cannot read
	# an openwiki-less bootstrap as clean.
	[[ $output == *"MCP wiring was SKIPPED"* ]]
}
