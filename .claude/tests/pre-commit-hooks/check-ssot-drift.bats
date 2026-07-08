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
	# Clean pass AND no skip message: proves the check actually evaluated the
	# fixture (a missing/unparsed config would skip or error, not silently pass).
	[ "$status" -eq 0 ]
	[[ $output != *skipping* ]]
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

@test "multi-digit claim extracts in full (10 == 10; greedy-prefix regression #2387)" {
	# Old single-pass sed let the greedy .* prefix eat the leading "1",
	# extracting "0" and false-BLOCKing. 10 claimed vs 10 actual must pass.
	printf 'There are 10 required status checks.\n' >"$TEST_TMP/claim.md"
	printf 'required:\n%s' "$(for i in 0 1 2 3 4 5 6 7 8 9; do printf '  - check_name: c%s\n' "$i"; done)" >"$TEST_TMP/required.yml"
	write_config
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -eq 0 ]
	[[ $output != *skipping* ]]
	[[ $output != *drift* ]]
}

@test "multi-digit claim still BLOCKS on real divergence (claim 10 vs SSOT 3)" {
	# Companion to the regression test: the two-step extraction must not
	# weaken detection — a genuinely wrong multi-digit claim still blocks.
	printf 'There are 10 required status checks.\n' >"$TEST_TMP/claim.md"
	write_config
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -ne 0 ]
	[[ $output == *drift* ]]
	[[ $output == *10* ]]
}

@test "shipped .claude/ssot-checks.yml is loadable with at least one check" {
	run yq -r '.checks | length' "$REPO_ROOT/.claude/ssot-checks.yml"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test ".gitignore keeps .claude/ssot-checks.yml trackable (negation wins)" {
	# git check-ignore exits 1 for a NOT-ignored path (what we want) and 128 on
	# a fatal error; assert the precise code plus empty output so a git error
	# cannot masquerade as a clean not-ignored result. A 0 exit would mean the
	# negation failed and the guard would ship dormant on a fresh clone.
	run git -C "$REPO_ROOT" check-ignore .claude/ssot-checks.yml
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

# --- #2291: extended coverage — kind:list, no-config, staging filter,
# --- yq-missing fail-closed, and malformed-config behaviour ---

# A kind:list config: inline items (one per regex match) vs an SSOT yq list.
write_list_config() {
	cat >"$TEST_TMP/ssot-checks.yml" <<EOF
checks:
  - name: required-checks-list
    kind: list
    claim:
      file: $TEST_TMP/claim-list.md
      regex: 'check: ([a-z]+)'
    ssot:
      file: $TEST_TMP/required.yml
      list: '.required[].check_name'
    description: test-list
EOF
}

@test "kind:list passes when the inline set matches the SSOT list" {
	printf 'check: a\ncheck: b\ncheck: c\n' >"$TEST_TMP/claim-list.md"
	write_list_config
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -eq 0 ]
	[[ $output != *drift* ]]
}

@test "kind:list BLOCKS when the inline set diverges from the SSOT list" {
	printf 'check: a\ncheck: b\ncheck: c\n' >"$TEST_TMP/claim-list.md"
	# SSOT gains a fourth entry the inline list lacks → drift.
	printf 'required:\n  - check_name: a\n  - check_name: b\n  - check_name: c\n  - check_name: d\n' >"$TEST_TMP/required.yml"
	write_list_config
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -ne 0 ]
	[[ $output == *drift* ]]
}

@test "check-ssot-drift passes when the config file is absent (exit 0)" {
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/does-not-exist.yml' '$SCRIPT'"
	# Clean pass with no output proves the absent-config short-circuit ran (a
	# real check run would emit drift/skip text).
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "check-ssot-drift skips a check whose files are not staged" {
	# A mismatched count config that WOULD block if evaluated...
	printf 'required:\n  - check_name: a\n  - check_name: b\n  - check_name: c\n  - check_name: d\n' >"$TEST_TMP/required.yml"
	write_config
	# ...but staging an unrelated file activates the staging filter, which skips
	# checks whose claim/ssot files are not among the staged paths.
	(cd "$TEST_TMP" && : >other.txt && git add other.txt)
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -eq 0 ]
	[[ $output != *drift* ]]
}

@test "check-ssot-drift fails closed when yq is unavailable (exit 1)" {
	write_config
	# A PATH with git + bash but no yq → command -v yq fails → fail-closed.
	nobin="$TEST_TMP/nobin"
	mkdir -p "$nobin"
	ln -s "$(command -v git)" "$nobin/git"
	ln -s "$(command -v bash)" "$nobin/bash"
	run bash -c "cd '$TEST_TMP' && PATH='$nobin' SSOT_CHECKS_CONFIG='$TEST_TMP/ssot-checks.yml' '$SCRIPT'"
	[ "$status" -eq 1 ]
	[[ $output == *yq* ]]
}

@test "check-ssot-drift exits 2 on a malformed config" {
	printf 'checks: [unclosed sequence\n' >"$TEST_TMP/bad.yml"
	run bash -c "cd '$TEST_TMP' && SSOT_CHECKS_CONFIG='$TEST_TMP/bad.yml' '$SCRIPT'"
	# Key assertions last: exit 2 AND the parse-failure message pin the intended
	# branch (the only exit-2 path is the yq config-parse failure).
	[ "$status" -eq 2 ]
	[[ $output == *parsing* ]]
}
