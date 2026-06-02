#!/usr/bin/env bats
# covers: scripts/meta-bootstrap.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/meta-bootstrap.sh"
	TEST_TMP=$(mktemp -d -t meta-bootstrap-repo.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */meta-bootstrap-repo.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--target repo without target-dir exits 2" {
	run "$SCRIPT" --target repo
	[ "$status" -eq 2 ]
	[[ $output == *"requires a target directory"* ]]
}

@test "--target repo --verify-only against empty dir fails (no manifest files)" {
	mkdir -p "$TEST_TMP/empty"
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/empty"
	[ "$status" -eq 1 ]
	[[ $output == *"--verify-only failed"* ]]
}

@test "--target repo bootstraps an empty dir then verifies clean (no gh remote = no label-remote check)" {
	mkdir -p "$TEST_TMP/target"
	run "$SCRIPT" --target repo -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	[[ $output == *"bootstrapped + verified"* ]]
	# Assert files from BOTH scopes landed — pre-commit-config.yaml is
	# plugin-scope, consumer-only files prove the orchestrator's
	# --scope both verify actually catches consumer drift.
	[ -f "$TEST_TMP/target/.pre-commit-config.yaml" ]
	[ -f "$TEST_TMP/target/.claude/skills/ship-pr-cycle/run.sh" ]
	[ -f "$TEST_TMP/target/.claude/skills/ship-pr-cycle/SKILL.md" ]
	[ -f "$TEST_TMP/target/.claude/hooks/review-log.sh" ]
	# #223: the ship-pr-cycle runtime shims land too (phase0.5 + post-commit).
	[ -f "$TEST_TMP/target/.claude/hooks/phase0.5-copilot-prefilter.sh" ]
	[ -f "$TEST_TMP/target/.claude/hooks/post-commit-ship-cycle.sh" ]
	# #234: the byte-SSOT CodeRabbit base is written, AND the live
	# .coderabbit.yaml is composed from it. With no per-repo overlay, the
	# composed config must equal the base verbatim (compose-coderabbit.sh).
	[ -f "$TEST_TMP/target/.coderabbit.base.yaml" ]
	[ -f "$TEST_TMP/target/.coderabbit.yaml" ]
	diff "$TEST_TMP/target/.coderabbit.base.yaml" "$TEST_TMP/target/.coderabbit.yaml"
}

@test "--target repo --verify-only on bootstrapped dir succeeds (re-runs clean)" {
	mkdir -p "$TEST_TMP/target"
	run "$SCRIPT" --target repo -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/target"
	[ "$status" -eq 0 ]
	[[ $output == *"--verify-only complete"* ]]
}

@test "--target repo detects partial bootstrap (consumer file deleted)" {
	# Bootstrap, then delete a consumer-scope file → verify must fail.
	# Pins the --scope both contract: catches consumer drift the prior
	# --scope plugin orchestrator would have silently missed.
	mkdir -p "$TEST_TMP/target"
	"$SCRIPT" --target repo -- "$TEST_TMP/target" >/dev/null 2>&1
	rm -f "$TEST_TMP/target/.claude/skills/ship-pr-cycle/run.sh"
	run "$SCRIPT" --target repo --verify-only -- "$TEST_TMP/target"
	[ "$status" -eq 1 ]
	[[ $output == *"--verify-only failed"* ]]
}

@test "--target repo --verify-only without target-dir exits 2 (same arg requirement)" {
	run "$SCRIPT" --target repo --verify-only
	[ "$status" -eq 2 ]
}

@test "--target repo with empty-string target-dir exits 2" {
	run "$SCRIPT" --target repo -- ""
	[ "$status" -eq 2 ]
	[[ $output == *"requires a target directory"* ]]
}

@test "--target repo rejects extra positional args (silent-drop would mask typos)" {
	mkdir -p "$TEST_TMP/target"
	run "$SCRIPT" --target repo -- "$TEST_TMP/target" --force
	[ "$status" -eq 2 ]
	[[ $output == *"accepts exactly one positional argument"* ]]
}

@test "--target repo against target-dir that is a regular file fails cleanly" {
	touch "$TEST_TMP/regular-file"
	run "$SCRIPT" --target repo -- "$TEST_TMP/regular-file"
	[ "$status" -eq 1 ]
	[[ $output == *"aborting before verify"* ]]
}
