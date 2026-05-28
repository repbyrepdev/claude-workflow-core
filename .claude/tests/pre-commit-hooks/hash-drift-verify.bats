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

@test "HASH_DRIFT_VERIFY_SKIP=1 bypass exits 0 + writes JSONL audit log (per #148 path)" {
	_write_stub_hash_drift 1
	HASH_DRIFT_VERIFY_SKIP=1 HOME="$TEST_TMP/home" run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"HASH_DRIFT_VERIFY_SKIP=1"* ]]
	[[ $output == *"BYPASS"* ]]
	# CR Phase 2 MAJOR: log path is hash-drift-skip.jsonl per #148 spec.
	[ -f "$TEST_TMP/home/.claude/logs/hash-drift-skip.jsonl" ]
	jq -e . "$TEST_TMP/home/.claude/logs/hash-drift-skip.jsonl"
	grep -q '"event":"hash-drift-verify-skip"' "$TEST_TMP/home/.claude/logs/hash-drift-skip.jsonl"
}

@test "HASH_DRIFT_VERIFY_SKIP=1 FAILS CLOSED when audit log write fails (mkdir denied)" {
	_write_stub_hash_drift 1
	# Remove the pre-created .claude dir (setup() created it for the
	# happy-path test) + recreate parent as unwritable so mkdir -p
	# .claude/logs inside the shim fails.
	rm -rf "$TEST_TMP/home/.claude"
	mkdir -p "$TEST_TMP/home"
	chmod 0500 "$TEST_TMP/home"
	HASH_DRIFT_VERIFY_SKIP=1 HOME="$TEST_TMP/home" run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	# Restore perms for teardown cleanup
	chmod 0755 "$TEST_TMP/home"
	# Per CR Phase 2: bypass must fail-closed when audit-logging fails.
	[ "$status" -eq 2 ]
	[[ $output == *"audit log write FAILED"* ]]
	[[ $output == *"#148"* ]]
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
