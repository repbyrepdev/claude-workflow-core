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
	# Assert -x (not just -f): the manifest declares both mode 755, so bootstrap
	# must materialize them executable (#223 phase2 — a -f-only check passed even
	# if the exec bit was dropped).
	[ -x "$TEST_TMP/target/.claude/hooks/phase0.5-copilot-prefilter.sh" ]
	[ -x "$TEST_TMP/target/.claude/hooks/post-commit-ship-cycle.sh" ]
	# #234/#2379: the byte-SSOT CodeRabbit base is written, AND the live
	# .coderabbit.yaml is composed from it. Since #2254/#2257,
	# compose-coderabbit.sh appends per-file canonical-mirror-hook
	# `!.claude/hooks/<name>` excludes to .reviews.auto_review.path_filters — and
	# that yq pass reflows base's folded block scalars + drops blank lines — so
	# the composed config is NOT byte-identical to base (the prior
	# `diff base composed` was stale, predating #2254, + brittle to yq's reflow).
	# Real invariant: the bootstrap's composed .coderabbit.yaml reproduces a fresh
	# compose of the bootstrapped base via the SAME path production takes — --out
	# INSIDE the target tree, so compose derives the consumer-hooks dir from
	# dirname(--out)=target (the production branch, not the env-override branch).
	# (compose's overlay-merge + tool-pinning correctness is unit-tested in
	# bootstrap-coderabbit-compose.bats; the #2257 consumer-override branch is
	# tracked for unit coverage in #2400.)
	[ -f "$TEST_TMP/target/.coderabbit.base.yaml" ]
	[ -f "$TEST_TMP/target/.coderabbit.yaml" ]
	run "$REPO_ROOT/scripts/compose-coderabbit.sh" \
		--base "$TEST_TMP/target/.coderabbit.base.yaml" \
		--out "$TEST_TMP/target/.coderabbit.recompose.yaml"
	[ "$status" -eq 0 ]
	# Compose must NOT warn about an unresolved consumer-hooks dir — that path
	# silently over-excludes every canonical hook (compose-coderabbit.sh ~L209).
	# The warning is a cross-file contract: assert it is ABSENT from this run AND
	# that the exact phrase still EXISTS in compose-coderabbit.sh, so a drift in
	# the wording fails this test (forcing a co-update) instead of silently
	# passing the negative match.
	_warn="every canonical hook will be excluded"
	grep -qF "$_warn" "$REPO_ROOT/scripts/compose-coderabbit.sh"
	[[ $output != *"$_warn"* ]]
	diff "$TEST_TMP/target/.coderabbit.recompose.yaml" "$TEST_TMP/target/.coderabbit.yaml"
	# Completeness, not mere presence: in a fresh bootstrap EVERY canonical hook
	# (hooks/*.sh) is excluded as a byte-identical mirror (#2254/#2257), so the
	# composed exclude count must equal the canonical hook count — catches a
	# partial/zero-injection regression the determinism diff above cannot. Count
	# via yq on the parsed path_filters (NOT grep: the injected head_comment also
	# quotes the `!.claude/hooks/<name>` pattern, so a raw grep over-counts by 1).
	n_canonical=$(find "$REPO_ROOT/hooks" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
	n_excluded=$(yq '[.reviews.auto_review.path_filters[] | select(test("^!\.claude/hooks/"))] | length' "$TEST_TMP/target/.coderabbit.yaml")
	[ "$n_excluded" -gt 0 ]
	[ "$n_excluded" -eq "$n_canonical" ]
	# Base content survives compose (not just determinism): a known base key.
	[ "$(yq '.reviews.profile' "$TEST_TMP/target/.coderabbit.yaml")" = assertive ]
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
