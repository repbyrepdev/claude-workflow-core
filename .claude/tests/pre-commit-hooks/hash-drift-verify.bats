#!/usr/bin/env bats
# covers: pre-commit-hooks/hash-drift-verify.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	SHIM="${REPO_ROOT}/pre-commit-hooks/hash-drift-verify.sh"
	TEST_TMP=$(mktemp -d -t hdv.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}

	# Build a self-contained fixture: pre-commit-hooks/hash-drift-verify.sh
	# next to a stub scripts/hash-drift.sh so the relative resolution works.
	(
		set -e
		mkdir -p "$TEST_TMP/pre-commit-hooks" "$TEST_TMP/scripts"
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
	cat >"$TEST_TMP/scripts/hash-drift.sh" <<EOF
#!/bin/bash
echo "stub-hash-drift called: \$*" >&2
exit $1
EOF
	chmod +x "$TEST_TMP/scripts/hash-drift.sh"
}

@test "forwards exit 0 from hash-drift.sh --verify clean" {
	_write_stub_hash_drift 0
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"stub-hash-drift called: --verify"* ]]
}

@test "forwards exit 1 from hash-drift.sh --verify (drift)" {
	_write_stub_hash_drift 1
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 1 ]
}

@test "missing scripts/hash-drift.sh sibling → exit 2 with clear error" {
	# Don't write the stub — verify the shim fails-closed.
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"sibling scripts/hash-drift.sh not found"* ]]
	[[ $output == *"Reinstall the plugin"* ]]
}

@test "non-executable hash-drift.sh → exit 2" {
	cat >"$TEST_TMP/scripts/hash-drift.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
	# Intentionally NOT chmod +x
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 2 ]
	[[ $output == *"not found or non-executable"* ]]
}

@test "HASH_DRIFT_VERIFY_SKIP=1 bypass exits 0 + audit-logs to stderr" {
	_write_stub_hash_drift 1
	HASH_DRIFT_VERIFY_SKIP=1 run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"HASH_DRIFT_VERIFY_SKIP=1"* ]]
	[[ $output == *"audit-logged"* ]]
}

@test "uses exec — no subshell layer in process tree" {
	# exec replaces the shim process with hash-drift.sh. A bash invocation
	# of `bash -c 'exec ./shim.sh'` should NOT show a wrapping bash for
	# the shim itself after exec fires.
	_write_stub_hash_drift 0
	run "$TEST_TMP/pre-commit-hooks/hash-drift-verify.sh"
	[ "$status" -eq 0 ]
	# stub stderr was emitted (proves the exec actually ran the sibling)
	[[ $output == *"stub-hash-drift called"* ]]
}
