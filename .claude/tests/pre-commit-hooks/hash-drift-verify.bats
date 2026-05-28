#!/usr/bin/env bats
# covers: pre-commit-hooks/hash-drift-verify.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd) || {
		echo "FATAL: cd to repo root failed" >&2
		return 1
	}
	SHIM="${REPO_ROOT}/pre-commit-hooks/hash-drift-verify.sh"
	TEST_TMP=$(mktemp -d -t hdv.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}

	(
		set -e
		mkdir -p "$TEST_TMP/pre-commit-hooks" "$TEST_TMP/scripts" "$TEST_TMP/home/.claude/logs"
		cp "$SHIM" "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
		chmod +x "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */hdv.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_stub_hash_drift() {
	# $1 = exit code the stub returns
	# Writes args to a file for exact-match assertion + emits stderr for visibility.
	cat >"$TEST_TMP/scripts/hash-drift.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >"$TEST_TMP/stub-args.txt"
echo "stub-hash-drift called: \$*" >&2
exit $1
EOF
	chmod +x "$TEST_TMP/scripts/hash-drift.sh"
}

@test "forwards exit 0 from hash-drift.sh --verify clean" {
	_write_stub_hash_drift 0
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 0 ]
	# r2 silent-failure-hunter MEDIUM: assert EXACT args, not substring.
	# Locks the contract: shim passes ONLY `--verify`, no extras.
	[ -f "$TEST_TMP/stub-args.txt" ]
	[ "$(cat "$TEST_TMP/stub-args.txt")" = "--verify" ]
}

@test "forwards exit 1 from hash-drift.sh --verify (drift)" {
	_write_stub_hash_drift 1
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 1 ]
}

@test "missing scripts/hash-drift.sh sibling → exit 2 with MISSING-specific diagnostic" {
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"sibling scripts/hash-drift.sh MISSING"* ]]
	[[ $output == *"Reinstall the plugin"* ]]
}

@test "non-executable hash-drift.sh → exit 2 with chmod-specific diagnostic" {
	cat >"$TEST_TMP/scripts/hash-drift.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
	# Intentionally NOT chmod +x
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"NOT EXECUTABLE"* ]]
	[[ $output == *"chmod +x"* ]]
}

@test "sibling path is a directory → exit 2 with directory-specific diagnostic" {
	mkdir -p "$TEST_TMP/scripts/hash-drift.sh"
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"is a directory, not a file"* ]]
}

@test "HASH_DRIFT_VERIFY_SKIP=1 bypass exits 0 + writes JSONL audit log" {
	_write_stub_hash_drift 1
	HASH_DRIFT_VERIFY_SKIP=1 HOME="$TEST_TMP/home" run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"HASH_DRIFT_VERIFY_SKIP=1"* ]]
	[[ $output == *"BYPASS"* ]]
	# r2 silent-failure-hunter HIGH: assert the audit log file was written.
	[ -f "$TEST_TMP/home/.claude/logs/hash-drift-verify-bypass.jsonl" ]
	# Parseable JSON
	jq -e . "$TEST_TMP/home/.claude/logs/hash-drift-verify-bypass.jsonl"
	# Contains the expected event marker
	grep -q '"event":"hash-drift-verify-skip"' "$TEST_TMP/home/.claude/logs/hash-drift-verify-bypass.jsonl"
}

@test "extra args rejected with exit 2 + clear message (locked-down contract)" {
	_write_stub_hash_drift 0
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh" --json --plugin-cache /tmp/x
	[ "$status" -eq 2 ]
	[[ $output == *"this shim hardcodes --verify"* ]]
	[[ $output == *"extra args rejected"* ]]
	# Stub should NOT have been invoked.
	[ ! -f "$TEST_TMP/stub-args.txt" ]
}
