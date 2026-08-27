#!/usr/bin/env bats
# covers: _lib/resolve-plugin-helper.sh
# shellcheck disable=SC2030,SC2031  # bats @test bodies run in subshells; per-test REPO_ROOT export is intentional + isolated
#
# #223 warn-on-drift: resolve_plugin_helper checks $REPO_ROOT/.claude/<rel>
# BEFORE the canonical $plugin_root/<rel>. A stale local copy silently shadows
# the SSOT (these paths are NOT hash-tracked). These tests lock:
#   - local copy still wins (override capability preserved);
#   - when a canonical ALSO exists and DIFFERS, a loud #223 stderr warning fires
#     but the LOCAL copy is still returned;
#   - byte-identical legacy behavior when NO canonical exists (no warning);
#   - silent when local == canonical;
#   - plugin-cache fallback + not-found (rc 1) unchanged.
#
# The lib is copied into a synthetic <plugin>/_lib/ so BASH_SOURCE-relative
# plugin-root resolution points at our fixture, not the real repo.

setup() {
	LIB_SRC="${BATS_TEST_DIRNAME}/../../../_lib/resolve-plugin-helper.sh"
	[ -f "$LIB_SRC" ]
	TEST_TMP=$(mktemp -d -t rph.XXXXXX) || return 1
	PLUGIN="$TEST_TMP/plugin"
	REPO="$TEST_TMP/repo"
	mkdir -p "$PLUGIN/_lib" "$PLUGIN/scripts/copilot" "$REPO/.claude/scripts/copilot"
	cp "$LIB_SRC" "$PLUGIN/_lib/resolve-plugin-helper.sh"
	LIB="$PLUGIN/_lib/resolve-plugin-helper.sh"
	REL="scripts/copilot/try-free.sh"
	LOCAL_COPY="$REPO/.claude/$REL"
	CANONICAL="$PLUGIN/$REL"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rph.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "no canonical + local exists → returns local, NO warning (legacy byte-identical)" {
	echo "local-only" >"$LOCAL_COPY"
	# canonical intentionally absent
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	run resolve_plugin_helper "$REL"
	[ "$status" -eq 0 ]
	[ "$output" = "$LOCAL_COPY" ]
	[[ $output != *"WARNING"* ]] || return 1
	[[ $output != *"#223"* ]]
}

@test "canonical exists + DIFFERS → warns (#223) but still returns local" {
	echo "local-content" >"$LOCAL_COPY"
	echo "canonical-content" >"$CANONICAL"
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	# Capture stdout + stderr together to assert the warning + the returned path.
	run resolve_plugin_helper "$REL"
	[ "$status" -eq 0 ]
	# stdout (path) is on the first line; the warning is on stderr (merged by run).
	[[ $output == *"$LOCAL_COPY"* ]] || return 1
	[[ $output == *"#223 possible stale override shadow"* ]] || return 1
	[[ $output == *"$CANONICAL"* ]] # warning names the canonical
}

@test "warning goes to stderr; stdout is ONLY the resolved path" {
	echo "local-content" >"$LOCAL_COPY"
	echo "canonical-content" >"$CANONICAL"
	export REPO_ROOT="$REPO"
	# Redirect stderr to /dev/null INSIDE the run so only stdout is captured.
	# (No top-level `. "$LIB"` — the run below sources it fresh in its own shell.)
	run bash -c '. "$1"; resolve_plugin_helper "$2" 2>/dev/null' _ "$LIB" "$REL"
	[ "$status" -eq 0 ]
	[ "$output" = "$LOCAL_COPY" ] # clean single-line path, no warning text
}

@test "canonical exists + IDENTICAL → returns local, NO warning" {
	echo "same-bytes" >"$LOCAL_COPY"
	echo "same-bytes" >"$CANONICAL"
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	run resolve_plugin_helper "$REL"
	[ "$status" -eq 0 ]
	[ "$output" = "$LOCAL_COPY" ]
	# #223 phase2: assert on the stable warning marker ("#223 possible stale
	# override shadow") that the IDENTICAL case must NOT emit, rather than the
	# generic "WARNING" token — ties the assertion to the exact stale-shadow
	# string in resolve-plugin-helper.sh:74.
	[[ $output != *"#223"* ]]
}

@test "no local copy + canonical exists → plugin-cache fallback" {
	echo "canonical-content" >"$CANONICAL"
	# no local copy
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	run resolve_plugin_helper "$REL"
	[ "$status" -eq 0 ]
	[ "$output" = "$CANONICAL" ]
}

@test "neither local nor canonical → returns 1" {
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	run resolve_plugin_helper "scripts/copilot/nonexistent.sh"
	[ "$status" -eq 1 ]
	# Behavior contract (CR #223): not-found returns rc 1 with NO output —
	# neither a resolved path on stdout nor a warning on stderr (run merges both).
	[ -z "$output" ]
}

@test "leading .claude/ prefix is stripped before resolution" {
	echo "local-only" >"$LOCAL_COPY"
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	run resolve_plugin_helper ".claude/$REL"
	[ "$status" -eq 0 ]
	[ "$output" = "$LOCAL_COPY" ]
}

@test "missing rel-path argument → returns 2" {
	export REPO_ROOT="$REPO"
	# shellcheck source=../../../_lib/resolve-plugin-helper.sh
	. "$LIB"
	run resolve_plugin_helper ""
	[ "$status" -eq 2 ]
	[[ $output == *"missing rel-path"* ]]
}
