#!/usr/bin/env bats
# covers: scripts/install-machine.sh
#
# Tests for the operator-time machine setup wrapper (#71).
# Verifies that it correctly composes the three pieces:
#   1. install-register-hook-permissions.sh check (Step 1)
#   2. hooks/install-hooks.sh (Step 2)
#   3. migrate-settings.sh (Step 3, --no-migrate skippable)

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/install-machine.sh"
	TEST_TMP=$(cd "$(mktemp -d -t install-machine.XXXXXX)" && pwd -P) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */install-machine.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: build a fake plugin layout with all three sibling scripts
# replaced by stubs that log invocation. Stubs can be tuned to return
# different exit codes per test scenario.
_install_fake_layout() {
	local perms_check_rc=$1 # 0 = allowlist present, 1 = missing
	local installer_rc=${2:-0}
	local migrate_rc=${3:-0}

	local scripts_dir="$TEST_TMP/fakerepo/scripts"
	local hooks_dir="$TEST_TMP/fakerepo/hooks"
	mkdir -p "$scripts_dir" "$hooks_dir"
	cp "$SCRIPT" "$scripts_dir/install-machine.sh"
	chmod +x "$scripts_dir/install-machine.sh"

	# Stub install-register-hook-permissions.sh — honor the --check flag
	cat >"$scripts_dir/install-register-hook-permissions.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "stub-perms called: \$*" >>"$TEST_TMP/calls.log"
if [ "\${1:-}" = "--check" ]; then
	exit $perms_check_rc
fi
if [ "\${1:-}" = "--json" ]; then
	echo '{"permissions":{"allow":["stub"]}}'
	exit 0
fi
exit 0
EOF
	chmod +x "$scripts_dir/install-register-hook-permissions.sh"

	# Stub hooks/install-hooks.sh
	cat >"$hooks_dir/install-hooks.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "stub-installer called: \$*" >>"$TEST_TMP/calls.log"
exit $installer_rc
EOF
	chmod +x "$hooks_dir/install-hooks.sh"

	# Stub migrate-settings.sh
	cat >"$scripts_dir/migrate-settings.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "stub-migrate called: \$*" >>"$TEST_TMP/calls.log"
exit $migrate_rc
EOF
	chmod +x "$scripts_dir/migrate-settings.sh"

	# Stub register-hook.sh (used by --check mode to approximate
	# install-hooks.sh's --check semantics).
	cat >"$scripts_dir/register-hook.sh" <<EOF
#!/bin/bash
set -euo pipefail
echo "stub-register called: \$*" >>"$TEST_TMP/calls.log"
exit 0
EOF
	chmod +x "$scripts_dir/register-hook.sh"

	echo "$scripts_dir/install-machine.sh"
}

@test "script exists and is executable" {
	[ -x "$SCRIPT" ]
}

@test "--help shows usage" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"operator-time machine setup"* ]]
	[[ $output == *"Acceptance criteria"* ]]
}

@test "unknown flag rejected with exit 2" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ $output == *"unknown flag"* ]]
}

# --- Step 1: classifier allowlist ----------------------------------

@test "allowlist missing → exit 2 with operator instructions" {
	fake=$(_install_fake_layout 1)
	run "$fake"
	[ "$status" -eq 2 ]
	[[ $output == *"Allowlist patterns missing"* ]]
	[[ $output == *"ONE-TIME setup required"* ]]
	[[ $output == *"--json"* ]]
}

@test "allowlist missing + --check → exit 1 (drift)" {
	fake=$(_install_fake_layout 1)
	run "$fake" --check
	[ "$status" -eq 1 ]
	[[ $output == *"Allowlist patterns missing"* ]]
}

# --- Step 2: installer composition --------------------------------

@test "allowlist present → runs install-hooks installer" {
	fake=$(_install_fake_layout 0 0 0)
	run "$fake" --no-migrate
	[ "$status" -eq 0 ]
	[[ $output == *"Step 2: register plugin hooks"* ]]
	# Stub installer was invoked
	[ -f "$TEST_TMP/calls.log" ]
	got=$(grep -c "stub-installer called" "$TEST_TMP/calls.log")
	[ "$got" -eq 1 ]
}

@test "installer returns non-zero → exit propagates" {
	fake=$(_install_fake_layout 0 5 0)
	run "$fake" --no-migrate
	# install-hooks.sh exit 5 should kill the script via set -e
	[ "$status" -ne 0 ]
}

# --- Step 3: migration toggle -------------------------------------

@test "--no-migrate skips Step 3" {
	fake=$(_install_fake_layout 0 0 0)
	run "$fake" --no-migrate
	[ "$status" -eq 0 ]
	[[ $output == *"SKIPPED via --no-migrate"* ]]
	# Stub migrate NOT invoked
	run ! grep -q "stub-migrate called" "$TEST_TMP/calls.log"
}

@test "default runs Step 3 migration" {
	fake=$(_install_fake_layout 0 0 0)
	run "$fake"
	[ "$status" -eq 0 ]
	[[ $output == *"Step 3: bump stale path versions"* ]]
	got=$(grep -c "stub-migrate called" "$TEST_TMP/calls.log")
	[ "$got" -eq 1 ]
}

# --- precondition: missing sibling script ------------------------

@test "missing install-register-hook-permissions.sh → exit 2" {
	fake=$(_install_fake_layout 0)
	rm -f "$TEST_TMP/fakerepo/scripts/install-register-hook-permissions.sh"
	run "$fake"
	[ "$status" -eq 2 ]
	[[ $output == *"required sibling script not found"* ]]
}

@test "missing hooks/install-hooks.sh → exit 2" {
	fake=$(_install_fake_layout 0)
	rm -f "$TEST_TMP/fakerepo/hooks/install-hooks.sh"
	run "$fake"
	[ "$status" -eq 2 ]
	[[ $output == *"required sibling script not found"* ]]
}
