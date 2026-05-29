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
	# Strengthened (P1 R1): no rotation archives should be created when the
	# logs dir is absent — proves the [ -d "$LOGS_DIR" ] guard skipped the
	# block cleanly rather than erroring past it.
	run bash -c "find $TEST_TMP/.claude/session-log-archive -name '*-pretrim-*.jsonl' 2>/dev/null | head -1"
	[ -z "$output" ]
}

@test "multi-file: over-cap trimmed, under-cap sibling untouched, one archive" {
	# P1 R1 (pr-test-analyzer crit-4): the real trigger is a MIX of over-
	# and under-cap logs in one for-loop pass. A loop-scoping bug (stray
	# break, leaked _trim_tmp) would pass every single-file case but fail
	# here. Seed both; assert independent handling.
	for i in $(seq 1 600); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/big.jsonl"
	for i in $(seq 1 50); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/small.jsonl"
	small_before=$(md5 -q "$TEST_TMP/.claude/logs/small.jsonl" 2>/dev/null || md5sum "$TEST_TMP/.claude/logs/small.jsonl" | awk '{print $1}')
	run _run_hook 100
	[ "$status" -eq 0 ]
	# big trimmed to cap, small byte-identical
	[ "$(wc -l <"$TEST_TMP/.claude/logs/big.jsonl" | tr -d ' ')" -eq 100 ]
	small_after=$(md5 -q "$TEST_TMP/.claude/logs/small.jsonl" 2>/dev/null || md5sum "$TEST_TMP/.claude/logs/small.jsonl" | awk '{print $1}')
	[ "$small_before" = "$small_after" ]
	# exactly one pretrim archive (big only, not small)
	count=$(find "$TEST_TMP/.claude/session-log-archive" -name '*-pretrim-*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
	[ "$count" -eq 1 ]
	[ -n "$(find "$TEST_TMP/.claude/session-log-archive" -name 'big-pretrim-*.jsonl' 2>/dev/null | head -1)" ]
}

@test "at-cap boundary (lines == MAX) left untouched (-gt not -ge)" {
	# P1 R1 (pr-test-analyzer crit-3): off-by-one guard. A flip from -gt to
	# -ge would needlessly rewrite + archive a log sitting exactly at cap.
	for i in $(seq 1 100); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/atcap.jsonl"
	before=$(md5 -q "$TEST_TMP/.claude/logs/atcap.jsonl" 2>/dev/null || md5sum "$TEST_TMP/.claude/logs/atcap.jsonl" | awk '{print $1}')
	run _run_hook 100
	[ "$status" -eq 0 ]
	after=$(md5 -q "$TEST_TMP/.claude/logs/atcap.jsonl" 2>/dev/null || md5sum "$TEST_TMP/.claude/logs/atcap.jsonl" | awk '{print $1}')
	[ "$before" = "$after" ]
	[ -z "$(find "$TEST_TMP/.claude/session-log-archive" -name 'atcap-pretrim-*.jsonl' 2>/dev/null | head -1)" ]
}

@test "archive-failure path preserves the original (never-wipe safety)" {
	# P1 R1 (pr-test-analyzer crit-6 + silent-failure-hunter): the headline
	# safety claim is "a failure mid-rotation can't truncate the log". Make
	# the archive dir unwritable so the cp fails; the trim must still NOT
	# destroy the original beyond the cap, and the hook must exit 0 + WARN.
	for i in $(seq 1 600); do echo "{\"n\":$i}"; done >"$TEST_TMP/.claude/logs/big.jsonl"
	# Pre-create the archive dir so the hook's top-level `mkdir -p` no-ops,
	# then make ONLY that dir unwritable so the rotation's archive cp fails
	# while .claude/ and .claude/logs/ (where the trim tmp lives) stay
	# writable. This isolates the archive-failure path without breaking the
	# hook's own setup.
	mkdir -p "$TEST_TMP/.claude/session-log-archive"
	chmod 555 "$TEST_TMP/.claude/session-log-archive" 2>/dev/null || skip "cannot chmod to simulate unwritable dir"
	run _run_hook 100
	chmod 755 "$TEST_TMP/.claude/session-log-archive" 2>/dev/null || true
	[ "$status" -eq 0 ]
	# Archive cp failed but the trim tmp lives under writable .claude/logs,
	# so the trim succeeds → 100. The original must be cleanly trimmed, never
	# a partial/empty file.
	count=$(wc -l <"$TEST_TMP/.claude/logs/big.jsonl" | tr -d ' ')
	[ "$count" -eq 100 ]
	# WARN should have been emitted about the failed archive.
	[[ $output == *"pre-trim archive"* ]] || [[ $output == *"WARN"* ]]
	# And NO archive file should exist (the cp genuinely failed).
	[ -z "$(find "$TEST_TMP/.claude/session-log-archive" -name 'big-pretrim-*.jsonl' 2>/dev/null | head -1)" ]
}
