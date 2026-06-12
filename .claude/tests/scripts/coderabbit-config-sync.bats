#!/usr/bin/env bats
# covers: scripts/compose-coderabbit.sh
#
# #2297/#2299: drift guard for this repo's COMMITTED CodeRabbit config. The
# composed .coderabbit.yaml (the file CodeRabbit actually reads) is per-repo —
# NOT byte-SSOT, NOT in bootstrap-manifest.yml, and covered by no hash gate — so
# an overlay/base edit committed WITHOUT re-running compose-coderabbit.sh would
# silently ship a stale config (phase1 #2297: 3 agents flagged the ungated
# overlay -> composed divergence). This asserts the committed .coderabbit.yaml is
# byte-in-sync with a fresh compose(base, overlay), and pins the #2297
# code_generation block's CORRECT nesting (CR silently ignores a flat
# code_generation.path_instructions). A full pre-commit gate (catching drift at
# the overlay-edit commit, not just the test run) is the follow-up — #2402.

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	TEST_TMP=$(mktemp -d -t cr-config-sync.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	if [ -n "${TEST_TMP:-}" ] && [[ $TEST_TMP == */cr-config-sync.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "committed .coderabbit.yaml is byte-in-sync with compose(base, overlay)" {
	# Recompose from the committed inputs. The real regen runs from the repo root
	# (`--out .coderabbit.yaml` -> dirname=repo -> consumer hooks = repo/.claude/
	# hooks); --out here lands in a tmp dir, so pin that consumer-hooks dir
	# explicitly to reproduce the same #2254 canonical-mirror exclusion set.
	run env COMPOSE_CR_CONSUMER_HOOKS_DIR="$REPO_ROOT/.claude/hooks" \
		"$REPO_ROOT/scripts/compose-coderabbit.sh" \
		--base "$REPO_ROOT/.coderabbit.base.yaml" \
		--overlay "$REPO_ROOT/.coderabbit.overlay.yaml" \
		--out "$TEST_TMP/recompose.yaml"
	[ "$status" -eq 0 ]
	# Byte-diff: a stale committed .coderabbit.yaml (overlay edited without regen)
	# fails here. Remedy on failure: re-run compose-coderabbit.sh + git add it.
	diff "$TEST_TMP/recompose.yaml" "$REPO_ROOT/.coderabbit.yaml"
}

@test "overlay code_generation reaches composed with the CORRECT nesting" {
	# CR nests path_instructions under code_generation.docstrings / .unit_tests;
	# a flat code_generation.path_instructions is VALID-by-omission yet silently
	# ignored by CR (no error), so guard the nesting mechanically.
	[ "$(yq '.code_generation.docstrings.path_instructions | length' "$REPO_ROOT/.coderabbit.yaml")" -ge 1 ]
	[ "$(yq '.code_generation.unit_tests.path_instructions | length' "$REPO_ROOT/.coderabbit.yaml")" -ge 1 ]
	# The mis-nested flat form must be ABSENT (its presence = dropped guidance).
	[ "$(yq '.code_generation.path_instructions // "ABSENT"' "$REPO_ROOT/.coderabbit.yaml")" = "ABSENT" ]
}
