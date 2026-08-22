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
	[ -x "$SCRIPT" ]
	[ -f "$LIB" ]
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
	[ "$status" -eq 0 ]
	[ -x "$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh" ]
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
	[ -f "$hooks_dir/skill-bypass-guard.sh" ]
	run grep -cE '^#[[:space:]]*auto-register:[[:space:]]*true' "$hooks_dir/skill-bypass-guard.sh"
	[ "$output" = "0" ] # precondition: this hook does NOT opt in
	"$SCRIPT" --generate
	[ -x "$PLUGIN_LAUNCHER_DIR/skill-bypass-guard.sh" ]
}

@test "helpers (_*) and installers (install-*) get no launcher" {
	"$SCRIPT" --generate
	run bash -c "ls -1 '$PLUGIN_LAUNCHER_DIR'/_* '$PLUGIN_LAUNCHER_DIR'/install-* 2>/dev/null | wc -l | tr -d ' '"
	[ "$output" = "0" ]
}

@test "launcher parses under bash 3.2 (macOS /bin/bash), not just modern bash" {
	# The case-pattern-inside-$() form needs a leading `(` on bash 3.2. Static
	# linting does NOT catch the difference — only a real 3.2 parse does.
	"$SCRIPT" --generate
	run /bin/bash -n "$PLUGIN_LAUNCHER_DIR/phase1-directive-pending-guard.sh"
	[ "$status" -eq 0 ]
}

@test "launcher resolves the newest version that ACTUALLY contains its hook" {
	mkdir -p "$CR/0.34.121/hooks" # newer, but does NOT ship demo.sh
	printf '#!/usr/bin/env bash\necho ran-0.34.108\n' >"$CR/0.34.108/hooks/demo.sh"
	chmod +x "$CR/0.34.108/hooks/demo.sh"
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run "$TEST_TMP/demo.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "ran-0.34.108" ]
}

@test "launcher forwards argv, stdin, and the real hook's exit status" {
	printf '#!/usr/bin/env bash\necho "argv=[$*] stdin=[$(cat)]"\nexit 7\n' >"$CR/0.34.108/hooks/demo.sh"
	chmod +x "$CR/0.34.108/hooks/demo.sh"
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run bash -c "printf PAYLOAD | '$TEST_TMP/demo.sh' --flag a"
	[ "$status" -eq 7 ]
	[ "$output" = "argv=[--flag a] stdin=[PAYLOAD]" ]
}

@test "launcher fails OPEN with a named warning when no cache version has the hook" {
	# A hook we cannot locate must never wedge the session.
	. "$LIB"
	pcr_launcher_body demo.sh >"$TEST_TMP/demo.sh"
	chmod +x "$TEST_TMP/demo.sh"
	run "$TEST_TMP/demo.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"no plugin-cache version"* ]]
}

@test "migrate rewrites a pinned ref onto its launcher" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ]
	[ "$(_pinned_count)" = "0" ]
	run jq -r '[.. | strings | select(test("/launchers/"))] | length' "$CLAUDE_SETTINGS_FILE"
	[ "$output" = "1" ]
}

@test "defect 1: a ref with NO launcher is left pinned, never dangled" {
	# The warning must be enforced by a membership gate, not just printed. The
	# pre-fix walk rewrote every matching ref including ones it warned about.
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh" "0.34.100:no-such-hook.sh"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ]
	[[ $output == *"no launcher for no-such-hook.sh"* ]]
	# the un-launchered ref is still pinned (safe), not pointing at a missing file
	run grep -c "0.34.100/hooks/no-such-hook.sh" "$CLAUDE_SETTINGS_FILE"
	[ "$output" = "1" ]
	[ ! -e "$PLUGIN_LAUNCHER_DIR/no-such-hook.sh" ]
}

@test "defect 2: a MIXED-version settings.json migrates every version, not just max" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh" "0.34.100:ship-cycle-guard.sh"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ]
	[[ $output == *"v0.34.100"* ]] # per-version reporting, not an averaged max
	[[ $output == *"v0.34.108"* ]]
	[ "$(_pinned_count)" = "0" ]
}

@test "defect 4: file mode is preserved across the rewrite" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	chmod 600 "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ]
	run bash -c "stat -f '%Lp' '$CLAUDE_SETTINGS_FILE' 2>/dev/null || stat -c '%a' '$CLAUDE_SETTINGS_FILE'"
	[ "$output" = "600" ]
}

@test "defect 5: re-running keeps exactly ONE pristine backup (no self-overwrite)" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	cp "$CLAUDE_SETTINGS_FILE" "$TEST_TMP/original.json"
	"$SCRIPT" --migrate
	"$SCRIPT" --migrate # second run: nothing pinned, must not create/clobber
	run bash -c "ls -1 '$CLAUDE_SETTINGS_FILE'.bak-launchers.* 2>/dev/null | wc -l | tr -d ' '"
	[ "$output" = "1" ]
	# and that one backup is still the PRE-migration content
	run bash -c "diff -q '$TEST_TMP/original.json' \"\$(ls -1 '$CLAUDE_SETTINGS_FILE'.bak-launchers.*)\" >/dev/null && echo same"
	[ "$output" = "same" ]
}

@test "defect 6: corrupt settings.json is refused by name and left byte-identical" {
	"$SCRIPT" --generate
	printf 'not json {{{' >"$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --migrate
	[ "$status" -eq 3 ]
	[[ $output == *"not valid JSON"* ]]
	[[ $output == *"refusing to touch"* ]]
	[ "$(cat "$CLAUDE_SETTINGS_FILE")" = "not json {{{" ]
}

@test "unrelated settings keys survive the rewrite" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	run jq -r '.unrelated' "$CLAUDE_SETTINGS_FILE"
	[ "$output" = "keep-me" ]
}

@test "migration is idempotent — a second run reports nothing pinned" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	"$SCRIPT" --migrate
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ]
	[[ $output == *"no version-pinned hook refs"* ]]
}

@test "--check reports drift without mutating settings.json" {
	"$SCRIPT" --generate
	_seed_settings "0.34.108:phase1-directive-pending-guard.sh"
	local before
	before=$(cat "$CLAUDE_SETTINGS_FILE")
	run "$SCRIPT" --check
	[ "$status" -eq 1 ] # drift found
	[ "$(cat "$CLAUDE_SETTINGS_FILE")" = "$before" ]
}

@test "absent settings.json is a no-op, not an error" {
	rm -f "$CLAUDE_SETTINGS_FILE"
	run "$SCRIPT" --migrate
	[ "$status" -eq 0 ]
	[[ $output == *"nothing to migrate"* ]]
}

@test "pcr_newest_complete honors semver ordering (0.10.0 beats 0.9.5)" {
	mkdir -p "$PLUGIN_CACHE_ROOT/0.9.5/hooks" "$PLUGIN_CACHE_ROOT/0.10.0/hooks"
	touch "$PLUGIN_CACHE_ROOT/0.9.5/hooks/x.sh" "$PLUGIN_CACHE_ROOT/0.10.0/hooks/x.sh"
	. "$LIB"
	run pcr_newest_complete "$PLUGIN_CACHE_ROOT" hooks/x.sh
	[ "$status" -eq 0 ]
	[[ $output == */0.10.0 ]]
}

@test "pcr_newest_complete returns rc 1 when no version satisfies the probe" {
	mkdir -p "$PLUGIN_CACHE_ROOT/0.9.5/hooks"
	. "$LIB"
	run pcr_newest_complete "$PLUGIN_CACHE_ROOT" hooks/absent.sh
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}
