#!/usr/bin/env bats
# covers: _lib/plugin-cache-resolve.sh
#
# The generated launcher (pcr_launcher_body) is standalone and cannot source the
# lib, so it repeats the cache-root default literal from pcr_cache_root(). CR-in-CI
# #2540 flagged that nothing detects drift between the two copies — the bats
# fixtures set PLUGIN_CACHE_ROOT, so both sides use the override and a changed
# default passes every other test. This test greps both literals and asserts they
# are byte-identical, which is the drift guard that makes the duplication safe.

setup() {
	LIB="$BATS_TEST_DIRNAME/../../../_lib/plugin-cache-resolve.sh"
	[ -f "$LIB" ]
}

# Extract every `${PLUGIN_CACHE_ROOT:-...}` default literal in the file. There
# must be exactly two (the lib accessor + the launcher body) and they must match.
@test "cache-root default is identical in the lib accessor and the generated launcher" {
	run grep -oE '\$\{PLUGIN_CACHE_ROOT:-[^}]+\}' "$LIB"
	# `|| return 1` on every assertion: bats has no set -e, so a failing middle
	# check ([ "$uniq" -eq 1 ] is the drift signal, but is not the last line)
	# would be masked by the final command's status.
	[ "$status" -eq 0 ] || return 1

	# Exactly two occurrences — accessor and launcher. A third copy without this
	# test being updated is itself drift worth failing on.
	local count
	count=$(printf '%s\n' "$output" | grep -c .)
	[ "$count" -eq 2 ] || return 1

	# Both lines must be byte-identical — THE drift check.
	local uniq
	uniq=$(printf '%s\n' "$output" | sort -u | grep -c .)
	[ "$uniq" -eq 1 ] || return 1

	# And it must actually be the expected path, so a matched-but-wrong pair
	# (both edited to the same wrong value) still fails.
	printf '%s\n' "$output" | grep -qF '${PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}' || return 1
}
