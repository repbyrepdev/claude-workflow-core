#!/usr/bin/env bats
# covers: hooks/pre-compact-flush.sh

# v0.30.B (#188): regression tests for the .claude/logs/*.jsonl rotation
# block added to pre-compact-flush.sh. Verifies: over-cap logs are trimmed
# to the last MAX_LOG_LINES, under-cap logs are left untouched, the pre-trim
# copy is archived, a bad MAX env falls back to 500 (never wipes), and the
# hook still exits 0 (PreCompact non-blocking contract).

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/pre-compact-flush.sh"
	[ -f "$HOOK" ]
	TEST_TMP=$(mktemp -d -t precompact-rotate.XXXXXX)
	# Hook uses relative paths (.claude/logs, .claude/session-log-archive),
	# so run it from inside a synthetic repo root.
	mkdir -p "$TEST_TMP/.claude/logs"
	# _lib.sh is sourced via "$(dirname "$0")/_lib.sh"; copy the hook + a
	# stub _lib so the source + session_state_read calls don't abort.
	cp "$HOOK" "$TEST_TMP/pre-compact-flush.sh"
	cat >"$TEST_TMP/_lib.sh" <<'LIB'
hook_log_run() { :; }
session_state_read() { echo ""; }
LIB
}

teardown() {
	[ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
}

_run_hook() {
	# PreCompact reads stdin (JSON payload); feed an empty object.
	(cd "$TEST_TMP" && echo '{}' | PRE_COMPACT_LOG_MAX_LINES="${1:-500}" bash ./pre-compact-flush.sh)
}

@test "over-cap log trimmed to last MAX_LOG_LINES" {
	# 600 lines, cap 100 → expect 100 after.
	for i in $(seq 1 600); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/big.jsonl"
	run _run_hook 100
	[ "$status" -eq 0 ]
	count=$(wc -l <"$TEST_TMP/.claude/logs/big.jsonl" | tr -d ' ')
	[ "$count" -eq 100 ]
	# Last line preserved (most recent kept).
	[ "$(tail -1 "$TEST_TMP/.claude/logs/big.jsonl")" = '{"n":600}' ]
	# First kept line is 501 (600 - 100 + 1).
	[ "$(head -1 "$TEST_TMP/.claude/logs/big.jsonl")" = '{"n":501}' ]
}

@test "under-cap log left untouched (no needless rewrite)" {
	for i in $(seq 1 50); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/small.jsonl"
	before=$(md5 -q "$TEST_TMP/.claude/logs/small.jsonl" 2>/dev/null || md5sum "$TEST_TMP/.claude/logs/small.jsonl" | awk '{print $1}')
	run _run_hook 100
	[ "$status" -eq 0 ]
	after=$(md5 -q "$TEST_TMP/.claude/logs/small.jsonl" 2>/dev/null || md5sum "$TEST_TMP/.claude/logs/small.jsonl" | awk '{print $1}')
	[ "$before" = "$after" ]
	# No pre-trim archive should exist for an untouched file.
	run bash -c "ls $TEST_TMP/.claude/session-log-archive/small-pretrim-* 2>/dev/null"
	[ "$status" -ne 0 ]
}

@test "pre-trim copy is archived before trimming" {
	for i in $(seq 1 300); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/big.jsonl"
	run _run_hook 100
	[ "$status" -eq 0 ]
	# An archive copy with the full 300 lines must exist.
	archive=$(find "$TEST_TMP/.claude/session-log-archive" -name 'big-pretrim-*.jsonl' 2>/dev/null | head -1)
	[ -n "$archive" ]
	[ "$(wc -l <"$archive" | tr -d ' ')" -eq 300 ]
}

@test "garbage MAX env falls back to 500 (never wipes the log)" {
	for i in $(seq 1 600); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/big.jsonl"
	run _run_hook "not-a-number"
	[ "$status" -eq 0 ]
	# 600 > 500 fallback → trimmed to 500, NOT wiped to 0.
	count=$(wc -l <"$TEST_TMP/.claude/logs/big.jsonl" | tr -d ' ')
	[ "$count" -eq 500 ]
}

@test "hook exits 0 even with no logs dir (PreCompact non-blocking)" {
	rm -rf "$TEST_TMP/.claude/logs"
	run _run_hook 100
	[ "$status" -eq 0 ]
}
