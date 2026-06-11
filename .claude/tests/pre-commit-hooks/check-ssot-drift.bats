#!/usr/bin/env bats
# covers: pre-commit-hooks/check-ssot-drift.sh
#
# #2315: check-ssot-drift was dormant until .claude/ssot-checks.yml shipped a
# non-empty config (the gitignore negation makes it trackable). These tests pin
# the activation: a matching count passes, a mismatched count BLOCKS, the
# shipped config is loadable, and the negation keeps the config from being
# re-ignored (which would silently re-dormant the guard on a fresh clone).
#
# The hook runs each check unconditionally when nothing is staged (the staging
# filter only narrows when STAGED_PATHS is non-empty), so the fixtures below do
# not stage files — matching the documented direct-invocation behavior.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/check-ssot-drift.sh"
	[ -f "$SCRIPT" ]
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	TEST_TMP=$(mktemp -d -t check-ssot-drift.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		cd "$TEST_TMP" || exit 1
		git init -q
		git config user.email t@t.t
		git config user.name t
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
	printf 'There are 3 required status checks (a, b, c).\n' >"$TEST_TMP/claim.md"
	printf 'required:\n  - check_name: a\n  - check_name: b\n  - check_name: c\n' >"$TEST_TMP/required.yml"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && rm -rf "$TEST_TMP"
}

# Build a config whose claim/ssot point at the absolute fixture paths, so the
# hook's _abs_path passes them through (REPO_ROOT resolution irrelevant).
write_config() {
	cat >"$TEST_TMP/ssot-checks.yml" <<EOF
checks:
  - name: required-checks-count
    kind: count
    claim:
      file: $TEST_TMP/claim.md
      regex: '([0-9]+) required status checks'
    ssot:
      file: $TEST_TMP/required.yml
      count: '.required | length'
    description: test
EOF
}

@test "check-ssot-drift passes when claim count matches SSOT (3 == 3)" {
	write_config
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -eq 0 ]
}

@test "check-ssot-drift BLOCKS when claim count diverges (claim 3 vs SSOT 4)" {
	printf 'required:\n  - check_name: a\n  - check_name: b\n  - check_name: c\n  - check_name: d\n' >"$TEST_TMP/required.yml"
	write_config
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	# Key assertions last: a non-zero exit AND a drift message prove the check
	# actually fired and detected the mismatch (not a silent skip).
	[ "$status" -ne 0 ]
	[[ $output == *drift* ]]
}

@test "shipped .claude/ssot-checks.yml is loadable with at least one check" {
	run yq -r '.checks | length' "$REPO_ROOT/.claude/ssot-checks.yml"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test ".gitignore keeps .claude/ssot-checks.yml trackable (negation wins)" {
	# git check-ignore exits non-zero when a path is NOT ignored — the state we
	# want. A zero exit would mean the negation failed and the guard would ship
	# dormant on a fresh clone.
	run git -C "$REPO_ROOT" check-ignore .claude/ssot-checks.yml
	[ "$status" -ne 0 ]
}
