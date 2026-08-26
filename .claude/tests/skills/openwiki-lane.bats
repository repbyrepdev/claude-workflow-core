#!/usr/bin/env bats
# covers: skills/openwiki-lane/run.sh skills/openwiki-lane/SKILL.md _lib/openwiki-mcp-state.sh
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
	# _run_skill pins PATH to the fixture bin + /usr/bin:/bin, so anything the
	# wrapper needs that lives elsewhere (jq, on a Homebrew machine) has to be
	# linked in explicitly.
	#
	# FAIL LOUD when one is absent. `cmd -v && ln -sf` alone links nothing and
	# continues, so the wrapper takes a DIFFERENT branch — a missing jq turns
	# every MCP assertion into "unknown (jq missing)" and the failure names an
	# output mismatch instead of the real cause. Both tools are load-bearing:
	# git backs the fixture repo and every tree assertion, jq backs
	# _write_claude_json and the whole MCP probe.
	for t in jq git; do
		p=$(command -v "$t" 2>/dev/null) || {
			echo "FATAL: required fixture tool '$t' not on PATH — this suite cannot test what it claims to" >&2
			return 1
		}
		ln -sf "$p" "$TEST_TMP/bin/$t"
	done
	# Fail LOUD rather than silently testing the wrong branch: the CLI-absent
	# cases depend on openwiki being unreachable except via _stub_cli, and
	# openwiki installs to a brew/npm prefix, never to /usr/bin or /bin.
	if [ -x /usr/bin/openwiki ] || [ -x /bin/openwiki ]; then
		echo "FATAL: openwiki present in /usr/bin or /bin — fixture PATH isolation broken" >&2
		return 1
	fi
}

teardown() {
	cd /tmp 2>/dev/null || true
	[ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */openwiki-skill.* ]] && rm -rf "$TEST_TMP"
}

# Puts a bare openwiki on PATH. It takes NO version argument: the probe reads
# the resolved binary's package.json and never asks the CLI anything, so a
# stub that answered `--version` would prove the STUB honours a contract the
# real CLI never had — the fixture shape that let the every-run reinstall bug
# ship. Tests that need a version build a package layout instead (see
# "version probe: reports the real version from the resolved package").
_stub_cli() {
	rm -f "$TEST_TMP/bin/openwiki"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bin/openwiki"
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

_run_skill() { # $1 = subcommand; PATH is the fixture bin ONLY, HOME is the fixture
	# The ambient PATH is deliberately NOT retained. Half this suite drives the
	# CLI-absent branch ("CLI: absent", the missing-CLI preflight refusal), and
	# `scripts/bootstrap-machine.sh` installs openwiki to a brew/npm prefix on
	# every developer machine — so an inherited PATH turns those tests into
	# assertions about whoever is running them. _stub_cli is the only way the
	# CLI becomes reachable here.
	run env PATH="$TEST_TMP/bin:/usr/bin:/bin" HOME="$TEST_TMP/home" bash -c "cd '$REPO' && '$SKILL' $1"
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
	[[ $output == *"cannot resolve a git repo root"* ]]
	# The real "not a repository" text comes through from git itself now, so
	# this case and the broken-git case below read differently (p2r1).
	[[ $output == *"not a git repository"* ]]
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

@test "status reports a wired MCP, and a present-but-unidentifiable CLI honestly" {
	# Renamed: this used to claim it "reports the installed CLI version" and
	# assert *"0.4.0"*, which stopped being true when the probe switched to
	# reading the resolved binary's package — the bare stub has none. It stayed
	# green only because a mid-test `[[ ]]` is a no-op under bash 3.2, so the
	# name outlived the behaviour by a whole review round. The version case now
	# lives in "reports the real version from the resolved package".
	_stub_cli
	_write_claude_json '{"command":"openwiki","args":["mcp","--host","claude"]}'
	_run_skill status
	[ "$status" -eq 0 ]
	case "$output" in
	*"MCP:       wired"*) ;;
	*)
		echo "expected a wired MCP row; got: $output"
		return 1
		;;
	esac
	# A CLI with no package above it is PRESENT but unidentifiable — never
	# "absent", and never a fabricated version.
	case "$output" in
	*"CLI:       present (version unknown"*) ;;
	*)
		echo "expected a present-but-unknown CLI row; got: $output"
		return 1
		;;
	esac
	[[ $output != *"SOURCE-BUILD HACK"* ]]
}

@test "status FLAGS the obsolete source-build MCP wiring (the office-mini hack)" {
	# operations.md Install: a ~/.openwiki-main entry means the machine predates
	# 0.4.0's native integration and should be superseded, not copied.
	_stub_cli
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
	[ "$status" -eq 0 ]
	[[ $output == *"the steering channel"* ]]
}

@test "preflight REFUSES a dirty tree, naming gotcha 5 (rc 1)" {
	_stub_cli
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
	_stub_cli
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

@test "version probe: reads the PACKAGE, never asks the CLI (ci-followup)" {
	# The probe used to run `openwiki --version`, which the real CLI answers
	# with "Unknown option: --version" — so a healthy machine reported the
	# version as unreadable forever, and the same wrong assumption made
	# bootstrap-machine reinstall on every run.
	#
	# The stub below SCREAMS a version on every invocation. If the probe ever
	# goes back to asking the CLI, that string reaches the table and this test
	# fails — the assertion that matters here.
	#
	# NOTE the case/[ ] forms: on bash 3.2 (what bats runs under on macOS) a
	# failing `[[ ]]` fires neither errexit nor the ERR trap unless it is the
	# test's LAST command, so mid-test `[[ ]]` assertions are silent no-ops.
	cd "$REPO" || return 1
	rm -f "$TEST_TMP/bin/openwiki"
	printf '#!/usr/bin/env bash\necho "openwiki/9.9.9-FROM-CLI"\nexit 0\n' >"$TEST_TMP/bin/openwiki"
	chmod +x "$TEST_TMP/bin/openwiki"
	_write_claude_json ""
	_run_skill status
	[ "$status" -eq 0 ]
	case "$output" in
	*9.9.9-FROM-CLI*)
		echo "the probe asked the CLI for its version: $output"
		return 1
		;;
	esac
	# The stub is a plain file with no openwiki package.json above it, so the
	# honest answer names THAT — not some other cause the probe never checked.
	case "$output" in
	*"no openwiki package.json above the resolved binary"*) ;;
	*)
		echo "expected the not-found sentence; got: $output"
		return 1
		;;
	esac
	# Exactly one CLI line — a multi-line probe would break the table.
	[ "$(printf '%s\n' "$output" | grep -c 'CLI:')" -eq 1 ]
}

@test "version probe: reports the real version from the resolved package (ci-followup)" {
	# The positive half, and the proof it follows PATH rather than npm: the
	# package sits under the fixture's own tree, nowhere `npm root -g` knows.
	cd "$REPO" || return 1
	local pkg="$TEST_TMP/lanepkg/openwiki"
	mkdir -p "$pkg/dist"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$pkg/dist/cli.js"
	chmod +x "$pkg/dist/cli.js"
	printf '{"name":"openwiki","version":"0.4.0"}' >"$pkg/package.json"
	rm -f "$TEST_TMP/bin/openwiki"
	ln -s "$pkg/dist/cli.js" "$TEST_TMP/bin/openwiki"
	_write_claude_json ""
	_run_skill status
	[ "$status" -eq 0 ]
	case "$output" in
	*"CLI:       0.4.0"*) ;;
	*)
		echo "expected the package version in the table; got: $output"
		return 1
		;;
	esac
	[ "$(printf '%s\n' "$output" | grep -c 'CLI:')" -eq 1 ]
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

@test "MCP probe: a NON-OBJECT entry is unknown, never 'wired' (p2r1)" {
	# `jq -e .mcpServers.openwiki` is true for a string or a number too, and
	# `"str" | (.args // [])` then errors — which the `|| args=""` fallback
	# turned into the empty string, i.e. the *_) "wired" arm. A hand-edited
	# config would report the server as working when nothing can launch it.
	cd "$REPO" || return 1
	for shape in '"just-a-string"' '42' 'true' '["a","b"]'; do
		_write_claude_json "$shape"
		_run_skill status
		[ "$status" -eq 0 ]
		[[ $output == *"MCP:       unknown"* ]] || {
			echo "shape $shape did not report unknown: $output"
			return 1
		}
		[[ $output != *"MCP:       wired"* ]] || {
			echo "shape $shape reported WIRED: $output"
			return 1
		}
	done
	# `false` is falsy to `jq -e` but is still a malformed entry, not absence.
	_write_claude_json 'false'
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"MCP:       unknown"* ]]
	# ...and a real object still reads as wired, so this is not over-broad.
	_write_claude_json '{"command":"openwiki","args":["mcp"]}'
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"MCP:       wired"* ]]
}

@test "MCP probe: an object with malformed .args is unknown, not wired (p2r3)" {
	# One level below the type check: the ENTRY is an object but .args is a
	# string, so `(.args // []) | join(" ")` errors — and swallowing that into
	# args="" dropped straight through to the *_) "wired" arm. Same fail-open,
	# one nesting level down.
	cd "$REPO" || return 1
	for bad in '{"command":"openwiki","args":"mcp"}' '{"command":"openwiki","args":42}' '{"command":"openwiki","args":{"a":1}}'; do
		_write_claude_json "$bad"
		_run_skill status
		[ "$status" -eq 0 ]
		[[ $output == *".args is"*"not an array"* ]] || {
			echo "entry $bad did not report a malformed .args: $output"
			return 1
		}
		[[ $output != *"MCP:       wired"* ]] || {
			echo "entry $bad reported WIRED: $output"
			return 1
		}
	done
	# An entry with NO .args at all is legitimate (the `// []` default), so
	# this must not have become an over-broad refusal.
	_write_claude_json '{"command":"openwiki"}'
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"MCP:       wired"* ]]
}

@test "doctor keeps rc 0 but does NOT swallow an undocumented preflight rc (p2r1)" {
	# doctor is contractually always rc 0 (it reports; preflight gates), and
	# `_preflight || true` honoured that by swallowing EVERY status — so a
	# crash mid-probe was indistinguishable from the ordinary "unsafe" it is
	# meant to absorb. rc 1 stays quiet; anything else says so out loud.
	cd "$REPO" || return 1
	_stub_cli
	_write_claude_json ""
	echo dirty >"$REPO/uncommitted"
	_run_skill doctor
	[ "$status" -eq 0 ]
	[[ $output == *"REFUSING"* ]]
	[[ $output != *"preflight itself failed"* ]]

	# The already-covered UNKNOWN path (a corrupt index) is preflight's rc 1
	# too, so it stays quiet as well.
	#
	# HONEST SCOPE: nothing here drives the warning ARM. _preflight only ever
	# returns 0 or 1, and it is a shell function inside the script, so an
	# undocumented status cannot be induced through the CLI surface. The arm
	# exists for the next probe someone adds to _preflight — the point of the
	# finding — and these assertions pin that today's paths all stay inside
	# the documented vocabulary.
}

@test "the shared probe is executable as itself and covers every state (ci-r1)" {
	# _lib/openwiki-mcp-state.sh is the SSOT both callers parse through. Its
	# direct-execution mode is the only way to exercise the parser without a
	# caller's policy layered on top — and it is what makes the probe citable
	# as prove-yourself evidence, which needs a cycle-critical file in COMMAND
	# position rather than only inside a fixture.
	local lib="$PLUGIN/_lib/openwiki-mcp-state.sh"
	[ -x "$lib" ]
	local cfg="$TEST_TMP/probe.json"

	run "$lib" "$TEST_TMP/definitely-not-here.json"
	[ "$status" -eq 0 ]
	[ "$output" = "no-config" ]

	printf 'NOT JSON{{{' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "bad-json" ]

	# Every shape → its own token. The parser must never answer "wired" for
	# anything it did not fully validate.
	printf '%s' '{"mcpServers":{}}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "not-wired" ]

	printf '%s' '{"mcpServers":"oops"}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "unreadable" ]

	printf '%s' '{"mcpServers":{"openwiki":"str"}}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "bad-entry:string" ]

	printf '%s' '{"mcpServers":{"openwiki":{"args":{"a":1}}}}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "bad-args:object" ]

	printf '%s' '{"mcpServers":{"openwiki":{"command":"node","args":["/x/.openwiki-main/dist/cli/cli.js","mcp"]}}}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "source-hack" ]

	printf '%s' '{"mcpServers":{"openwiki":{"command":"openwiki","args":["mcp"]}}}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "wired" ]

	# An entry with no .args at all is legitimate — `.args // []` defaults it.
	printf '%s' '{"mcpServers":{"openwiki":{"command":"openwiki"}}}' >"$cfg"
	run "$lib" "$cfg"
	[ "$status" -eq 0 ]
	[ "$output" = "wired" ]
}

@test "installed-version: every token, driven directly (ci-r1)" {
	# The version probe is the one whose bug got past the entire suite and was
	# caught only by running the real thing on a real machine. Drive every
	# branch through the lib's own CLI mode, where each is actually reachable —
	# the bootstrap-machine suite cannot make jq absent, because macOS ships
	# /usr/bin/jq.
	local lib="$PLUGIN/_lib/openwiki-mcp-state.sh"
	local b="$TEST_TMP/probebin"
	mkdir -p "$b"
	# Everything the probe itself needs, minus jq — so the no-jq branch is
	# reachable by simply not linking it.
	local tool tp
	for tool in readlink dirname; do
		tp=$(command -v "$tool") || {
			echo "FATAL: probe dependency '$tool' not on PATH"
			return 1
		}
		ln -sf "$tp" "$b/$tool"
	done

	# no-cli — nothing named openwiki anywhere on PATH.
	run env PATH="$b" "$lib" installed-version
	[ "$status" -eq 0 ]
	[ "$output" = "no-cli" ]

	# A real package layout: bin symlink -> pkg/dist/cli.js, package.json at
	# the package root. This is nowhere npm knows about, which is the point:
	# the probe follows PATH, not `npm root -g`.
	local pkg="$TEST_TMP/probepkg/openwiki"
	mkdir -p "$pkg/dist"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$pkg/dist/cli.js"
	chmod +x "$pkg/dist/cli.js"
	printf '{"name":"openwiki","version":"0.4.0"}' >"$pkg/package.json"
	ln -sf "$pkg/dist/cli.js" "$b/openwiki"

	# no-jq — the CLI resolves, but nothing can parse its package.json. This
	# is NOT a reinstallable state, which is why it gets its own token.
	run env PATH="$b" "$lib" installed-version
	[ "$status" -eq 0 ]
	[ "$output" = "no-jq" ]

	# With jq: the healthy case, reported from the package the BINARY belongs
	# to rather than from any global root.
	ln -sf "$(command -v jq)" "$b/jq"
	run env PATH="$b" "$lib" installed-version
	[ "$status" -eq 0 ]
	[ "$output" = "0.4.0" ]

	# not-found — a CLI on PATH with no openwiki package.json above it.
	rm -f "$pkg/package.json"
	run env PATH="$b" "$lib" installed-version
	[ "$status" -eq 0 ]
	[ "$output" = "not-found" ]

	# A package.json belonging to something ELSE must not answer for openwiki:
	# the walk matches on .name, not on "first package.json found".
	printf '{"name":"not-openwiki","version":"9.9.9"}' >"$pkg/package.json"
	run env PATH="$b" "$lib" installed-version
	[ "$status" -eq 0 ]
	[ "$output" = "not-found" ]

	# bad-version — found the package, but .version is not a bare semver.
	# Refused rather than rendered: it is self-attested, from a user-writable
	# directory, and it reaches operator logs and an agent's status field.
	local bad
	for bad in '"0.4.0\u001b[31mEVIL"' '"v0.4.0"' '"not-a-version"' 'null'; do
		printf '{"name":"openwiki","version":%s}' "$bad" >"$pkg/package.json"
		run env PATH="$b" "$lib" installed-version
		[ "$status" -eq 0 ]
		[ "$output" = "bad-version" ] || {
			echo "version $bad should be refused; got: $output"
			return 1
		}
	done

	# A DANGLING symlink is reported as no-cli, not unresolvable: `command -v`
	# refuses a link that does not resolve to an executable, so the probe never
	# reaches its own resolver. Asserting what actually happens rather than what
	# the token list suggests — `unresolvable` is defence for a resolver failure
	# that PATH lookup does not currently let through.
	printf '{"name":"openwiki","version":"0.4.0"}' >"$pkg/package.json"
	rm -f "$b/openwiki"
	ln -s "$TEST_TMP/definitely-not-here/cli.js" "$b/openwiki"
	run env PATH="$b" "$lib" installed-version
	[ "$status" -eq 0 ]
	[ "$output" = "no-cli" ]
}

@test "an rc-0 git WARNING does not turn a clean tree DIRTY (ci-r1)" {
	# `git status --porcelain 2>&1` folded stderr into the porcelain output,
	# and the verdict was `[ -n "$out" ]`. git writes advice, CRLF notices and
	# unreadable-config warnings to stderr and still exits 0 — so a CLEAN tree
	# came back DIRTY, preflight said "commit or stash", `git status` showed
	# nothing to commit, and the warning itself was never printed.
	cd "$REPO" || return 1
	_stub_cli
	_write_claude_json ""
	rm -f "$TEST_TMP/bin/git"
	cat >"$TEST_TMP/bin/git" <<STUB
#!/usr/bin/env bash
# Clean porcelain on stdout, a warning on stderr, exit 0 — what a real git
# does with e.g. an unreadable global config.
if [ "\$1" = "-C" ]; then shift 2; fi
if [ "\$1" = "status" ]; then
  echo "warning: unable to access '/nonexistent/.gitconfig': Permission denied" >&2
  exit 0
fi
if [ "\$1" = "rev-parse" ]; then echo "$REPO"; exit 0; fi
exit 0
STUB
	chmod +x "$TEST_TMP/bin/git"
	_run_skill status
	[ "$status" -eq 0 ]
	[[ $output == *"Tree:      clean"* ]] || {
		echo "an rc-0 warning was read as tree state: $output"
		return 1
	}
	# ...and the warning is still SHOWN. Fixing the verdict by discarding the
	# message would trade one silent failure for another.
	[[ $output == *"Tree warn:"* ]]
	[[ $output == *"Permission denied"* ]]

	# preflight agrees: nothing to refuse.
	_run_skill preflight
	[ "$status" -eq 0 ]
	[[ $output != *"REFUSING"* ]]
}

@test "a BROKEN git is not reported as 'wrong directory' (p2r1)" {
	# Trying to drive doctor with a git that exits 42 revealed the wrapper
	# never gets that far: the repo-root probe discarded git's stderr and
	# blamed the cwd, so `git` being broken or missing wore the label "not
	# inside a git repo" — sending the operator to cd somewhere else.
	cd "$REPO" || return 1
	# rm -f FIRST: setup() links the real git in here, and `printf >` FOLLOWS a
	# symlink — without this it truncates /usr/bin/git. (SIP refuses on macOS,
	# which is how this was caught; a Linux dev box would not have refused.)
	rm -f "$TEST_TMP/bin/git"
	printf '#!/usr/bin/env bash\necho "git: broken toolchain" >&2\nexit 42\n' >"$TEST_TMP/bin/git"
	chmod +x "$TEST_TMP/bin/git"
	_run_skill doctor
	[ "$status" -eq 2 ]
	[[ $output == *"git said: git: broken toolchain"* ]]
	[[ $output == *"git itself is broken or missing"* ]]
}

@test "tree probe FAILS CLOSED: a git error is UNKNOWN and refuses (p1r1)" {
	# The wrapper's primary refusal used to test only git's OUTPUT, so a
	# corrupt index (rc 128, EMPTY stdout) read as "clean" and preflight said
	# "safe to run" over uncommitted work.
	cd "$REPO" || return 1
	_stub_cli
	_write_claude_json ""
	printf 'GARBAGE' >"$REPO/.git/index"
	_run_skill status
	# status REPORTS state and never fails on it — including the unknown that
	# preflight then refuses on. Pinning rc 0 here is what keeps those two
	# contracts from collapsing into one.
	[ "$status" -eq 0 ]
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
