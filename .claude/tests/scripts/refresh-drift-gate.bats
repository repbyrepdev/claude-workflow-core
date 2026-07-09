#!/usr/bin/env bats
# covers: scripts/refresh-from-source.sh
#
# #2525 mirror-test drift gate: a cascade re-pin updates the consumer's
# mirror HOOKS but not the consumer's local bats copies of them, so the
# tests drift from the hook contract and go red — silently, since consumer
# bats is not a required CI check. The gate runs the covering consumer bats
# for every replaced mirror hook at REFRESH time and fails loud (rc=4) on
# drift, so it can never merge unseen.
#
# Each test builds a self-contained scratch PLUGIN tree (so PLUGIN_ROOT
# resolves to the scratch, not the real repo) + a scratch CONSUMER, then
# drives the REAL refresh-from-source.sh against them.

setup() {
	command -v bats >/dev/null || skip "bats not on PATH"
	command -v yq >/dev/null || skip "yq required"
	command -v jq >/dev/null || skip "jq required"
	REAL_SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/refresh-from-source.sh"
	[ -f "$REAL_SCRIPT" ] || skip "refresh-from-source.sh not found"
	TEST_TMP=$(mktemp -d -t rfs-drift.XXXXXX) || {
		echo "FATAL mktemp" >&2
		return 1
	}
	PLUGIN="$TEST_TMP/plugin"
	CONSUMER="$TEST_TMP/consumer"
	_build_plugin
	_build_consumer
}

teardown() {
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rfs-drift.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Scratch plugin: the script derives PLUGIN_ROOT from its own dir, so the
# copy at $PLUGIN/scripts/ makes PLUGIN_ROOT=$PLUGIN. The SSOT list needs
# only correct KEYS (paths); the hash VALUE is recomputed live, so a dummy
# is fine. testhook.sh is the NEW contract (`echo new`).
_build_plugin() {
	mkdir -p "$PLUGIN/scripts" "$PLUGIN/hooks" "$PLUGIN/.claude" "$PLUGIN/.claude-plugin" "$PLUGIN/.github"
	cp "$REAL_SCRIPT" "$PLUGIN/scripts/refresh-from-source.sh"
	chmod +x "$PLUGIN/scripts/refresh-from-source.sh"
	printf '#!/usr/bin/env bash\necho new\n' >"$PLUGIN/hooks/testhook.sh"
	chmod +x "$PLUGIN/hooks/testhook.sh"
	printf '{"files": {"hooks/testhook.sh": "0000000000000000000000000000000000000000000000000000000000000000"}}\n' \
		>"$PLUGIN/.claude/.source-hashes.json"
	printf '{"name":"t","version":"9.9.9"}\n' >"$PLUGIN/.claude-plugin/plugin.json"
	printf 'consumers: []\n' >"$PLUGIN/.github/consumers.yml"
}

# Scratch consumer: OLD mirror hook (`echo old`, different hash → refresh
# will REPLACE it) + a covering bats. The bats body is written per-test.
_build_consumer() {
	mkdir -p "$CONSUMER/.claude/hooks" "$CONSUMER/.claude/tests/hooks"
	printf '#!/usr/bin/env bash\necho old\n' >"$CONSUMER/.claude/hooks/testhook.sh"
	chmod +x "$CONSUMER/.claude/hooks/testhook.sh"
}

# Write the consumer's covering bats asserting a given expected output.
_write_consumer_test() { # $1 = expected hook output
	cat >"$CONSUMER/.claude/tests/hooks/testhook.bats" <<EOF
#!/usr/bin/env bats
# covers: .claude/hooks/testhook.sh
@test "testhook emits the expected contract" {
	run bash "\$BATS_TEST_DIRNAME/../../hooks/testhook.sh"
	[ "\$status" -eq 0 ]
	[ "\$output" = "$1" ]
}
EOF
}

@test "drift gate: consumer test matching the NEW hook contract → refresh rc=0" {
	# Test asserts `new` — after the hook is refreshed to `echo new`, it
	# passes, so the gate is satisfied and refresh succeeds.
	_write_consumer_test new
	run bash "$PLUGIN/scripts/refresh-from-source.sh" --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"[REPLACED] hooks/testhook.sh"* ]]
	[[ $output == *"drift-gate"* ]]
	[[ $output == *"all covering consumer tests pass"* ]]
	# The hook was actually refreshed to the new contract.
	[ "$(bash "$CONSUMER/.claude/hooks/testhook.sh")" = "new" ]
}

@test "drift gate: STALE consumer test (asserts OLD contract) → refresh rc=4, BLOCKED" {
	# Test still asserts `old` — after the hook is refreshed to `echo new`
	# it FAILS, exactly the silent-drift the gate must catch. refresh must
	# exit 4 and name the drifted file.
	_write_consumer_test old
	run bash "$PLUGIN/scripts/refresh-from-source.sh" --consumer-path "$CONSUMER"
	[ "$status" -eq 4 ]
	[[ $output == *"[REPLACED] hooks/testhook.sh"* ]]
	[[ $output == *"drift-gate"* ]]
	[[ $output == *"BLOCKED"* ]]
	[[ $output == *"testhook.bats"* ]]
}

@test "drift gate: REFRESH_DRIFT_GATE_SKIP=1 overrides a drifted test → rc=0" {
	# The escape hatch for a genuine unrelated pre-existing failure: the
	# stale test still drifts, but the gate is skipped so refresh succeeds.
	_write_consumer_test old
	run env REFRESH_DRIFT_GATE_SKIP=1 bash "$PLUGIN/scripts/refresh-from-source.sh" --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"[REPLACED] hooks/testhook.sh"* ]]
	[[ $output == *"drift-gate] skipped"* ]]
}

@test "drift gate: no covering consumer test → gate no-ops, refresh rc=0" {
	# A consumer that keeps no bats covering the replaced hook has nothing
	# to drift; the gate must not block (fails open with a note).
	rm -f "$CONSUMER/.claude/tests/hooks/testhook.bats"
	run bash "$PLUGIN/scripts/refresh-from-source.sh" --consumer-path "$CONSUMER"
	[ "$status" -eq 0 ]
	[[ $output == *"[REPLACED] hooks/testhook.sh"* ]]
	[[ $output == *"no consumer bats cover"* ]]
}
