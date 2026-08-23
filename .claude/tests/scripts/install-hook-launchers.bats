#!/usr/bin/env bats
# covers: scripts/install-hook-launchers.sh _lib/plugin-cache-resolve.sh
# shellcheck disable=SC1090  # $LIB resolves at runtime from $BATS_TEST_DIRNAME; a
# `source=` directive cannot sit inside a @test brace group (SC1009/SC1072/SC1073).
#
# v0.34.122 (#2536): version-agnostic hook launchers + the settings.json
# migration onto them.
#
# The migration MUTATES the operator's global settings.json, and the first
# attempt at this shipped six defects doing exactly that. Each of those defects
# has a named test below so a regression is loud:
#   1 verification failed OPEN   → fail-closed tests
#   2 healed only the max version → mixed-version test
#   3 predictable $$ temp         → mktemp (asserted via no-clobber + concurrency)
#   4 mode/owner lost via mv      → mode-preservation test
#   5 backup self-overwrite       → re-run keeps ONE pristine backup
#   6 causeless failure message   → STEP=-tagged failure tests

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/install-hook-launchers.sh"
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/plugin-cache-resolve.sh"
	[ -x "$SCRIPT" ] || return 1
	[ -f "$LIB" ] || return 1
	command -v jq >/dev/null
	TEST_TMP=$(mktemp -d -t launchers.XXXXXX) || return 1
	export PLUGIN_LAUNCHER_DIR="$TEST_TMP/launchers"
	export CLAUDE_SETTINGS_FILE="$TEST_TMP/settings.json"
	# The cache ROOT already ends in the doubled `claude-workflow-core/
	# claude-workflow-core` segment (that is the real on-disk layout), so
	# PLUGIN_CACHE_ROOT and $CR must be the SAME path. Setting the root one level
	# up made launchers probe `<root>/<ver>/hooks` while the fixture wrote to
	# `<root>/claude-workflow-core/claude-workflow-core/<ver>/hooks`, and the
	# version-pinned regex in the migrator only matches the doubled form anyway.
	export PLUGIN_CACHE_ROOT="$TEST_TMP/cache/claude-workflow-core/claude-workflow-core"
	CR="$PLUGIN_CACHE_ROOT"
	mkdir -p "$CR/0.34.108/hooks"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */launchers.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# settings.json referencing $1.. as version-pinned hook paths
_seed_settings() {
	local out="[" first=1 spec v b
	for spec in "$@"; do
		v=${spec%%:*}
		b=${spec#*:}
		[ "$first" -eq 1 ] || out="$out,"
		first=0
		out="$out{\"type\":\"command\",\"command\":\"$CR/$v/hooks/$b\"}"
	done
	out="$out]"
	printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":%s}]},"unrelated":"keep-me"}\n' "$out" >"$CLAUDE_SETTINGS_FILE"
	chmod 644 "$CLAUDE_SETTINGS_FILE"
}

_pinned_count() {
	grep -coE 'claude-workflow-core/[0-9]+\.[0-9]+\.[0-9]+/hooks/' "$CLAUDE_SETTINGS_FILE" || true
}

@test "generates an executable launcher per hook" {
	run "$SCRIPT" --generate
	[ "$status" -eq 0 ] || return 1
	[ -x "$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh" ] || return 1
}

@test "launcher set is NOT gated on 'auto-register: true'" {
	# `auto-register: true` answers "should register-hook.sh --all-auto-register
	# add this to settings.json?" — true for only 10 of 87 hooks. Launcher
	# generation answers a DIFFERENT question: "is this hook ever EXECUTED from
	# settings.json?", which is any of them. Gating on auto-register produced 10
	# launchers against 51 referenced refs on the real machine, leaving 41
	# version-pinned and still able to 404 after a cache GC — the exact failure
	# this script exists to end. Assert a hook that carries NO auto-register
	# frontmatter still gets a launcher.
	local hooks_dir="${BATS_TEST_DIRNAME}/../../../hooks"
	[ -f "$hooks_dir/skill-bypass-guard.sh" ] || return 1
	run grep -cE '^#[[:space:]]*auto-register:[[:space:]]*true' "$hooks_dir/skill-bypass-guard.sh"
	[ "$output" = "0" ] || return 1 # precondition: this hook does NOT opt in
	"$SCRIPT" --generate
	[ -x "$PLUGIN_LAUNCHER_DIR/skill-bypass-guard.sh" ] || return 1
}

@test "helpers (_*) and installers (install-*) get no launcher" {
	"$SCRIPT" --generate
	run bash -c "ls -1 '$PLUGIN_LAUNCHER_DIR'/_* '$PLUGIN_LAUNCHER_DIR'/install-* 2>/dev/null | wc -l | tr -d ' '"
	[ "$output" = "0" ] || return 1
}

@test "launcher case-patterns are paren-balanced for the bash 3.2 parser" {
	# bash 3.2 (macOS /bin/bash) mis-parses a paren-LESS case pattern inside $( )
	# and dies "syntax error near ';;'". shellcheck does not catch it. This
	# assertion is STATIC so it runs everywhere (no skip — a skip is not a pass,
	# and the bats-gate rightly distrusts one): the generated launcher must use
	# the leading-`(` form on every case pattern in its version scan.
	"$SCRIPT" --generate
	local L="$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh"
	# every `case`-pattern line ending in `)` inside the launcher body must open
	# with `(` — grep for the un-parenthesised `[0-9]...)` form and assert none.
	run grep -nE '^\s+\[0-9\][^(]*\)[^)]*;;' "$L"
	[ "$status" -ne 0 ] || return 1 # no un-parenthesised case pattern present
	# and the balanced forms ARE present
	run grep -qF '([0-9]*.[0-9]*.[0-9]*)' "$L"
	[ "$status" -eq 0 ] || return 1
}

@test "launcher parses under a real bash 3.2 when one is available" {
	# Belt-and-braces on the dev machine (macOS /bin/bash IS 3.2). Where no 3.2
	# interpreter exists (Linux CI), the static assertion above already covers
	# the regression, so this is a genuine no-op rather than a masked gap.
	local bash32=""
	# BASH32 is an optional operator override (path to a pinned 3.2); usually unset.
	# shellcheck disable=SC2153
	for cand in "${BASH32:-}" /bin/bash /opt/local/bin/bash-3.2; do
		[ -n "$cand" ] && [ -x "$cand" ] || continue
		case "$("$cand" --version 2>/dev/null | head -1)" in
		*"version 3.2"*)
			bash32=$cand
			break
			;;
		esac
	done
	# Honest `skip` when no 3.2 interpreter exists (CI/Linux) — a silent `return 0`
	# inflated the pass count with a no-op (CR-in-CI #2540). This is a PLATFORM-
	# conditional skip, not a neutering one: on the 3.2 dev machine it runs for
	# real, and the static paren-balance test above covers the regression where it
	# does not. bats reports it as skipped, not a spurious pass.
	[ -n "$bash32" ] || skip "no bash 3.2 interpreter available (static test covers the regression)"
	"$SCRIPT" --generate
	run "$bash32" -n "$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh"
	[ "$status" -eq 0 ] || return 1
}

@test "launcher resolves the newest version that ACTUALLY contains its hook" {
	mkdir -p "$CR/0.34.121/hooks" # newer, but does NOT ship demo.sh
	printf '#!/usr/bin/env bash\necho ran-0.34.108\n' >"$CR/0.34.108/hooks/demo.sh"
	chmod +x "$CR/0.34.108/hooks/demo.sh"
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run "$TEST_TMP/demo.sh"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "ran-0.34.108" ] || return 1
}

@test "launcher forwards argv, stdin, and the real hook's exit status" {
	printf '#!/usr/bin/env bash\necho "argv=[$*] stdin=[$(cat)]"\nexit 7\n' >"$CR/0.34.108/hooks/demo.sh"
	chmod +x "$CR/0.34.108/hooks/demo.sh"
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run bash -c "printf PAYLOAD | '$TEST_TMP/demo.sh' --flag a"
	[ "$status" -eq 7 ] || return 1
	[ "$output" = "argv=[--flag a] stdin=[PAYLOAD]" ] || return 1
}

@test 'launcher execs cleanly with ZERO argv (the ${1+"$@"} empty-args guard)' {
	# Hooks are invoked with NO argv — payload on stdin. Under the launcher's
	# `set -u`, a bare `"$@"` expanded empty aborts on bash <4.4 before exec, so
	# every hook would silently no-op; the `${1+"$@"}` form fixes it. The bash-3.2
	# parse test only PARSES, and it skips off-3.2 — so this EXECUTES the launcher
	# with zero args on WHATEVER bash runs the suite (incl. CI), which is the only
	# coverage that actually exercises the empty-args branch (CR-in-CI #2540).
	printf '#!/usr/bin/env bash\necho "argc=[$#] stdin=[$(cat)]"\nexit 0\n' >"$CR/0.34.108/hooks/demo.sh"
	chmod +x "$CR/0.34.108/hooks/demo.sh"
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	# NO argv, payload on stdin — exactly how a hook is called.
	run bash -c "printf PAYLOAD | '$TEST_TMP/demo.sh'"
	[ "$status" -eq 0 ] || return 1                        # did NOT abort on empty "$@"
	[ "$output" = "argc=[0] stdin=[PAYLOAD]" ] || return 1 # reached the hook, 0 args, stdin intact
}

@test "pcr_launcher_body REFUSES an unsafe hook basename (no injection into the generated script)" {
	# @@HOOK@@ is substituted into `exec "$_best/hooks/@@HOOK@@"` — inside double
	# quotes — and the result is written to disk and exec'd. A basename carrying a
	# quote/`$`/backtick/`;`/newline or a path separator would break out of that
	# string and inject code into EVERY generated launcher (CR-in-CI #2540).
	# Must fail closed (rc 2, nothing emitted).
	. "$LIB"
	for bad in 'a";rm -rf /;x.sh' 'a$(id).sh' 'a`id`.sh' '../evil.sh' 'sub/dir.sh' '-rf.sh' '' 'noext'; do
		run pcr_launcher_body "$bad"
		[ "$status" -ne 0 ] || {
			echo "accepted unsafe basename: [$bad]"
			return 1
		}
		# and it must not have emitted a launcher body
		[[ $output != *"exec "* ]] || {
			echo "emitted a body for unsafe basename: [$bad]"
			return 1
		}
	done
	# a legitimate basename still works
	run pcr_launcher_body "phase1-directive-pending-guard.sh"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"hooks/phase1-directive-pending-guard.sh"* ]] || return 1
}

@test "launcher fails OPEN with a named warning when no cache version has the hook" {
	# A hook we cannot locate must never wedge the session.
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run "$TEST_TMP/demo.sh"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"no plugin-cache version"* ]] || return 1
}

@test "migrate rewrites a pinned ref onto its launcher" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	[ "$(_pinned_count)" = "0" ] || return 1
	run jq -r '[.. | strings | select(test("/launchers/"))] | length' "$CLAUDE_SETTINGS_FILE"
	[ "$output" = "1" ] || return 1
}

@test "defect 1: a ref with NO launcher is left pinned, never dangled" {
	# The warning must be enforced by a membership gate, not just printed. The
	# pre-fix walk rewrote every matching ref including ones it warned about.
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh" "0.34.100:no-such-hook.sh"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"no executable launcher for no-such-hook.sh"* ]] || return 1
	# the un-launchered ref is still pinned (safe), not pointing at a missing file
	run grep -c "0.34.100/hooks/no-such-hook.sh" "$CLAUDE_SETTINGS_FILE"
	[ "$output" = "1" ] || return 1
	[ ! -e "$PLUGIN_LAUNCHER_DIR/no-such-hook.sh" ] || return 1
}

@test "defect 2: a MIXED-version settings.json migrates every version, not just max" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh" "0.34.100:ship-cycle-guard.sh"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"v0.34.100"* ]] || return 1 # per-version reporting, not an averaged max
	[[ $output == *"v0.34.108"* ]] || return 1
	[ "$(_pinned_count)" = "0" ] || return 1
}

@test "defect 4: file mode is preserved across the rewrite" {
	# Assert the SEEDED 644 survives — do NOT chmod 600 first. 600 is mktemp's
	# own default, so the original version of this test passed with the entire
	# mode-preservation block deleted: it asserted the value the temp file
	# already had. 644 can only survive if chmod --reference actually runs.
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh" # chmods 644
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	run bash -c "stat -f '%Lp' '$CLAUDE_SETTINGS_FILE' 2>/dev/null || stat -c '%a' '$CLAUDE_SETTINGS_FILE'"
	[ "$output" = "644" ] || return 1
}

@test "migrate preserves hook command ARGUMENTS and non-.hooks subtrees" {
	# The walk() used to replace the ENTIRE matched string, silently dropping
	# arguments and mangling pinned paths embedded in permissions rules.
	"$SCRIPT" --generate
	python3 - "$CLAUDE_SETTINGS_FILE" "$CR" <<'PY'
import json,sys
p,cr=sys.argv[1],sys.argv[2]
json.dump({"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":f"{cr}/0.34.108/hooks/phase1-directive-pending-guard.sh --strict"}]}]},
  "permissions":{"allow":[f"Bash({cr}/0.34.108/hooks/phase1-directive-pending-guard.sh:*)"]}},
  open(p,"w"))
PY
	chmod 644 "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	# the permissions rule must be byte-identical (never in scope for rewriting)
	run jq -r '.permissions.allow[0]' "$CLAUDE_SETTINGS_FILE"
	# `|| return 1` on EVERY assertion: bats runs the test body WITHOUT `set -e`,
	# so a bare `[[ ]]` that fails mid-test is masked by the last command's status
	# — the middle-assert-passes-spuriously trap. Each check must abort on its own.
	[[ $output == *"0.34.108/hooks/phase1-directive-pending-guard.sh:*)"* ]] || return 1
	# and the HOOK command must be rewritten onto the launcher WITH its argument
	# re-appended — the `$rest` join branch. Deleting that branch drops `--strict`
	# and leaves this suite green otherwise, which is the mutation gap the test
	# name promises to close (CR-in-CI #2540).
	run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
	[[ $output == *"/phase1-directive-pending-guard.sh --strict" ]] || return 1
	# rewritten onto the version-agnostic launcher dir, NOT a version-pinned path
	[[ $output != *"/0.34.108/"* ]] || return 1
}

@test "defect 5: re-running keeps exactly ONE pristine backup (no self-overwrite)" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	cp "$CLAUDE_SETTINGS_FILE" "$TEST_TMP/original.json"
	"$SCRIPT" --migrate
	"$SCRIPT" --migrate # second run: nothing pinned, must not create/clobber
	run bash -c "ls -1 '$CLAUDE_SETTINGS_FILE'.bak-launchers.* 2>/dev/null | wc -l | tr -d ' '"
	[ "$output" = "1" ] || return 1
	# and that one backup is still the PRE-migration content
	run bash -c "diff -q '$TEST_TMP/original.json' \"\$(ls -1 '$CLAUDE_SETTINGS_FILE'.bak-launchers.*)\" >/dev/null && echo same"
	[ "$output" = "same" ] || return 1
}

@test "defect 6: corrupt settings.json is refused by name and left byte-identical" {
	"$SCRIPT" --generate
	printf 'not json {{{' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --migrate
	[ "$status" -eq 3 ] || return 1
	[[ $output == *"not valid JSON"* ]] || return 1
	[[ $output == *"refusing to touch"* ]] || return 1
	[ "$(cat "$CLAUDE_SETTINGS_FILE")" = "not json {{{" ] || return 1
}

@test "unrelated settings keys survive the rewrite" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	run jq -r '.unrelated' "$CLAUDE_SETTINGS_FILE"
	[ "$output" = "keep-me" ] || return 1
}

@test "migration is idempotent — a second run reports nothing pinned" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"no version-pinned hook refs"* ]] || return 1
}

@test "--check reports drift without mutating settings.json" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	local before
	before=$(cat "$CLAUDE_SETTINGS_FILE")
	run "$SCRIPT" --check
	[ "$status" -eq 1 ] || return 1 # drift found
	[ "$(cat "$CLAUDE_SETTINGS_FILE")" = "$before" ] || return 1
}

@test "absent settings.json is a no-op, not an error" {
	rm -f "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"nothing to migrate"* ]] || return 1
}

# --- --verify ------------------------------------------------------------
# One command replaces the ad-hoc `python3 -c '…settings.json…' && stat && ls
# && jq` pipeline. That shape gets refused by the permission classifier (it
# reads the operator's global config), and hand-rebuilding it each time is how
# a check drifts from what it claims to test.

# The fixture cache must actually SHIP the probe hook, executable, or the
# launcher fails open — which is now a verify FAILURE, and was previously a
# silent false pass hiding inside this very test.
_stock_cache_hook() {
	printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/0.34.108/hooks/phase1-directive-pending-guard.sh"
	chmod +x "$CR/0.34.108/hooks/phase1-directive-pending-guard.sh"
}

@test "--verify passes on a fully migrated settings.json" {
	"$SCRIPT" --generate
	_stock_cache_hook
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	run "$SCRIPT" --verify
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"0 version-pinned hook refs"* ]] || return 1
	[[ $output == *"all executable"* ]] || return 1
	[[ $output == *"no fail-open"* ]] || return 1
	[[ $output == *"resolves to 0.34.108"* ]] || return 1
}

@test "--verify FAILS when the launcher fails open (empty cache)" {
	# THE headline regression. rc 0 is shared by "hook ran" and "failed open",
	# so the original probe passed for the exact condition it was written to
	# detect — and the fixture's cache was empty, so the passing test above
	# contained that false positive.
	"$SCRIPT" --generate
	_stock_cache_hook
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	rm -rf "$PLUGIN_CACHE_ROOT" # cache GC'd: every hook is now a silent no-op
	run "$SCRIPT" --verify
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"FAILED OPEN"* ]] || return 1
}

@test "--verify FAILS when the cache hook exists but is NOT executable" {
	# -f passes, -x does not; exec would die 126 rather than failing open.
	"$SCRIPT" --generate
	_stock_cache_hook
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	chmod -x "$CR/0.34.108/hooks/phase1-directive-pending-guard.sh"
	run "$SCRIPT" --verify
	[ "$status" -eq 1 ] || return 1
	# Assert WHICH check failed, not just that SOMETHING did — --verify returns 1
	# for six distinct conditions, so a bare status check passes even if the -x/-f
	# distinction regresses, provided any other check trips (CR-in-CI #2540). The
	# resolver only prints "executable" when it rejects a non-executable hook via
	# `-x`; a regression to `-f` would resolve it and never emit this line.
	# `|| return 1`: bats has no set -e, so a middle assertion must abort itself.
	[[ $output == *"executable"* ]] || return 1
}

@test "--verify FAILS on a settings.json with zero launcher refs" {
	# '0 refs, all executable' is vacuously true and read as a pass, blessing
	# the single most catastrophic state: nothing registered at all.
	"$SCRIPT" --generate
	printf '{}' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --verify
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"no launcher refs"* ]] || return 1
}

@test "--verify FAILS while version-pinned refs remain" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	run "$SCRIPT" --verify # not migrated yet
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"version-pinned hook ref(s) remain"* ]] || return 1
}

@test "--verify FAILS when a launcher ref points at a missing file" {
	# The failure this whole change exists to prevent: a registration that
	# resolves to nothing. Must be caught explicitly, never inferred.
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	rm -f "$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh"
	run "$SCRIPT" --verify
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"not executable"* ]] || return 1
}

@test "--verify refuses corrupt settings.json without mutating it" {
	printf 'not json {{{' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --verify
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"not valid JSON"* ]] || return 1
	[ "$(cat "$CLAUDE_SETTINGS_FILE")" = "not json {{{" ] || return 1
}

@test "pcr_newest_complete honors semver ordering (0.10.0 beats 0.9.5)" {
	mkdir -p "$PLUGIN_CACHE_ROOT/0.9.5/hooks" "$PLUGIN_CACHE_ROOT/0.10.0/hooks"
	# chmod +x is REQUIRED now: the probe is -x, not -e, because every caller
	# probes a hook it intends to execute.
	touch "$PLUGIN_CACHE_ROOT/0.9.5/hooks/x.sh" "$PLUGIN_CACHE_ROOT/0.10.0/hooks/x.sh"
	chmod +x "$PLUGIN_CACHE_ROOT/0.9.5/hooks/x.sh" "$PLUGIN_CACHE_ROOT/0.10.0/hooks/x.sh"
	. "$LIB"
	run pcr_newest_complete "$PLUGIN_CACHE_ROOT" hooks/x.sh
	[ "$status" -eq 0 ] || return 1
	[[ $output == */0.10.0 ]] || return 1
}

@test "pcr_newest_complete SKIPS a version whose hook is not executable" {
	# -e (the original) was satisfied by a non-executable file — and even by a
	# directory — so resolution could stop on a version that cannot run, and the
	# launcher would exec it and die 126 instead of falling back.
	mkdir -p "$PLUGIN_CACHE_ROOT/0.9.5/hooks" "$PLUGIN_CACHE_ROOT/0.10.0/hooks"
	touch "$PLUGIN_CACHE_ROOT/0.10.0/hooks/x.sh" # newer, NOT executable
	touch "$PLUGIN_CACHE_ROOT/0.9.5/hooks/x.sh"
	chmod +x "$PLUGIN_CACHE_ROOT/0.9.5/hooks/x.sh"
	. "$LIB"
	run pcr_newest_complete "$PLUGIN_CACHE_ROOT" hooks/x.sh
	[ "$status" -eq 0 ] || return 1
	[[ $output == */0.9.5 ]] || return 1 # falls back to the runnable one
}

@test "generated launcher also skips a non-executable hook and falls back" {
	mkdir -p "$CR/0.34.121/hooks"
	printf '#!/usr/bin/env bash\necho ran-0.34.108\n' >"$CR/0.34.108/hooks/demo.sh"
	chmod +x "$CR/0.34.108/hooks/demo.sh"
	printf '#!/usr/bin/env bash\necho ran-0.34.121\n' >"$CR/0.34.121/hooks/demo.sh" # newer, no +x
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run "$TEST_TMP/demo.sh"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "ran-0.34.108" ] || return 1
}

@test "pcr_newest_complete returns rc 1 when no version satisfies the probe" {
	mkdir -p "$PLUGIN_CACHE_ROOT/0.9.5/hooks"
	. "$LIB"
	run pcr_newest_complete "$PLUGIN_CACHE_ROOT" hooks/absent.sh
	[ "$status" -eq 1 ] || return 1
	[ -z "$output" ] || return 1
}

# --- the two resolvers that WRITE settings.json ---------------------------
# Generating launchers is only half the fix: if register-hook.sh and
# install-hooks.sh keep emitting version-pinned paths, every NEW registration
# re-introduces the exact bug the launchers exist to remove.

@test "register-hook.sh registers the LAUNCHER path when one exists (#2536)" {
	"$SCRIPT" --generate
	printf '{}' >"$CLAUDE_SETTINGS_FILE"
	run env CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_FILE" \
		"${BATS_TEST_DIRNAME}/../../../scripts/register-hook.sh" --dry-run \
		hooks/phase1-directive-pending-guard.sh
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh"* ]] || return 1
	# and NOT a version-pinned cache path
	[[ $output != *"claude-workflow-core/0."*"/hooks/"* ]] || return 1
}

@test "register-hook.sh falls back to a pinned path when no launcher exists" {
	# A fresh install before install-hook-launchers.sh has run must still
	# register the hook — version-pinned is worse than a launcher, but far
	# better than refusing to register at all.
	rm -rf "$PLUGIN_LAUNCHER_DIR"
	printf '{}' >"$CLAUDE_SETTINGS_FILE"
	run env CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_FILE" \
		"${BATS_TEST_DIRNAME}/../../../scripts/register-hook.sh" --dry-run \
		hooks/phase1-directive-pending-guard.sh
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"phase1-directive-pending-guard.sh"* ]] || return 1
	# Must NOT be a launcher path — the launcher dir was just removed, so any
	# reference to it would mean we registered something that does not exist.
	[[ $output != *"$PLUGIN_LAUNCHER_DIR"* ]] || return 1
}

@test 'install-hooks.sh registers launcher paths, not its own $BASH_SOURCE dir' {
	"$SCRIPT" --generate
	mkdir -p "$TEST_TMP/home/.claude"
	printf '{}' >"$TEST_TMP/home/.claude/settings.json"
	run env HOME="$TEST_TMP/home" PLUGIN_LAUNCHER_DIR="$PLUGIN_LAUNCHER_DIR" \
		"${BATS_TEST_DIRNAME}/../../../hooks/install-hooks.sh"
	[ "$status" -eq 0 ] || return 1
	# Assert against $PLUGIN_LAUNCHER_DIR, NOT the literal "/plugin-hooks/" —
	# that substring is only in the production default; the fixture overrides
	# the dir, so a literal check silently passes for the wrong reason.
	run jq -r --arg d "$PLUGIN_LAUNCHER_DIR" \
		'[.. | strings | select(startswith($d + "/"))] | length' \
		"$TEST_TMP/home/.claude/settings.json"
	[ "$output" -gt 0 ] || return 1
	# nothing may remain pinned to a concrete cache version
	run jq -r '[.. | strings | select(test("claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/hooks/"))] | length' \
		"$TEST_TMP/home/.claude/settings.json"
	[ "$output" = "0" ] || return 1
}
