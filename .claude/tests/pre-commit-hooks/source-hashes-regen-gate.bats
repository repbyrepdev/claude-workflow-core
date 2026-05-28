#!/usr/bin/env bats
# covers: pre-commit-hooks/source-hashes-regen-gate.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	HOOK="${REPO_ROOT}/pre-commit-hooks/source-hashes-regen-gate.sh"
	HASH_DRIFT="${REPO_ROOT}/scripts/hash-drift.sh"
	TEST_TMP=$(mktemp -d -t shrg.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	# Build a synthetic plugin fixture with hash-drift + the hook itself
	# co-located so the hook can resolve hash-drift relative to repo root.
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .claude-plugin .claude hooks _lib scripts pre-commit-hooks
		echo '{"version":"0.0.0"}' >.claude-plugin/plugin.json
		cp "$HASH_DRIFT" scripts/hash-drift.sh
		cp "$HOOK" pre-commit-hooks/source-hashes-regen-gate.sh
		chmod +x scripts/hash-drift.sh pre-commit-hooks/source-hashes-regen-gate.sh
		# One initial tracked file in each SSOT dir
		cat >hooks/sample-hook.sh <<'F'
#!/bin/bash
echo "v1"
F
		cat >_lib/sample-lib.sh <<'F'
#!/bin/bash
echo "lib v1"
F
		chmod +x hooks/sample-hook.sh _lib/sample-lib.sh
		# Generate baseline + commit everything
		scripts/hash-drift.sh --generate >/dev/null
		git add .
		git commit -q -m "baseline"
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */shrg.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "passes when no SSOT-tracked files staged" {
	cd "$TEST_TMP" || return 1
	# Stage a non-tracked file
	echo "README content" >README.md
	git add README.md
	run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 0 ]
}

@test "fails when hooks/X.sh staged without .source-hashes.json" {
	cd "$TEST_TMP" || return 1
	# Modify a tracked hook without regenerating
	echo "echo v2" >>hooks/sample-hook.sh
	git add hooks/sample-hook.sh
	run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 1 ]
	[[ $output == *".source-hashes.json"* ]]
	[[ $output == *"is NOT"* ]] || [[ $output == *"missing"* ]] || [[ $output == *"refresh"* ]]
}

@test "fails when _lib/X.sh staged without .source-hashes.json" {
	cd "$TEST_TMP" || return 1
	echo "echo lib v2" >>_lib/sample-lib.sh
	git add _lib/sample-lib.sh
	run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 1 ]
	[[ $output == *".source-hashes.json"* ]]
}

@test "passes when staged file + fresh hashes both staged" {
	cd "$TEST_TMP" || return 1
	echo "echo v2" >>hooks/sample-hook.sh
	scripts/hash-drift.sh --generate >/dev/null
	git add hooks/sample-hook.sh .claude/.source-hashes.json
	run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 0 ]
}

@test "fails when staged file + STALE hashes both staged" {
	cd "$TEST_TMP" || return 1
	# Modify hook content but stage OLD hashes (regen-then-modify-again)
	echo "echo v2" >>hooks/sample-hook.sh
	# DO NOT regen; just touch hashes file to force a stale "staged" version
	cp .claude/.source-hashes.json .claude/.source-hashes.json.fake
	echo "{}" >.claude/.source-hashes.json
	git add hooks/sample-hook.sh .claude/.source-hashes.json
	run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 1 ]
	[[ $output == *"stale"* ]] || [[ $output == *"diverges"* ]]
}

@test "bypass env SOURCE_HASHES_REGEN_SKIP=1 lets staged-stale through" {
	cd "$TEST_TMP" || return 1
	echo "echo v2" >>hooks/sample-hook.sh
	git add hooks/sample-hook.sh
	SOURCE_HASHES_REGEN_SKIP=1 run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 0 ]
	[[ $output == *"SOURCE_HASHES_REGEN_SKIP"* ]]
}

@test "fails-loud if hash-drift.sh is missing" {
	cd "$TEST_TMP" || return 1
	rm scripts/hash-drift.sh
	echo "echo v2" >>hooks/sample-hook.sh
	git add hooks/sample-hook.sh
	run pre-commit-hooks/source-hashes-regen-gate.sh
	[ "$status" -eq 2 ]
	[[ $output == *"hash-drift.sh"* ]]
}
