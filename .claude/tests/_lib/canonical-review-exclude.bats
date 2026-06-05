#!/usr/bin/env bats
# covers: _lib/canonical-review-exclude.sh
# shellcheck disable=SC2030,SC2031  # bats @test bodies run in subshells; per-test cd is intentional + isolated
#
# #2240 canonical-review-EXCLUSION: REVIEW layers (phase1 agents, phase2 local
# CR-CLI) skip files byte-identical to the pinned canonical. canonical_review_
# excluded wraps the #2235 hash-equality predicate (canonical_consumer_skip);
# canonical_review_noncanonical_changed lists the consumer-authored (non-
# excluded) slice of `git diff --name-only base..HEAD`. Same synthetic
# <plugin>/_lib + <consumer-repo> fixture as canonical-consumer-skip.bats, with
# BOTH libs copied into the synthetic plugin _lib so review-exclude sources its
# predicate (BASH_SOURCE-relative) from the fixture, not the real repo.

setup() {
	REVEX_SRC="${BATS_TEST_DIRNAME}/../../../_lib/canonical-review-exclude.sh"
	SKIP_SRC="${BATS_TEST_DIRNAME}/../../../_lib/canonical-consumer-skip.sh"
	[ -f "$REVEX_SRC" ]
	[ -f "$SKIP_SRC" ]
	TEST_TMP=$(mktemp -d -t cre.XXXXXX) || return 1
	PLUGIN="$TEST_TMP/plugin"
	REPO="$TEST_TMP/repo"
	mkdir -p "$PLUGIN/_lib" "$PLUGIN/hooks" "$PLUGIN/.claude-plugin" "$REPO/.claude/hooks"
	cp "$REVEX_SRC" "$PLUGIN/_lib/canonical-review-exclude.sh"
	cp "$SKIP_SRC" "$PLUGIN/_lib/canonical-consumer-skip.sh"
	LIB="$PLUGIN/_lib/canonical-review-exclude.sh"
	# Synthetic plugin: has plugin.json (so the predicate's BASH_SOURCE-relative
	# plugin-root resolves to the fixture) + is a git repo with a `main`.
	printf '{"name":"x"}\n' >"$PLUGIN/.claude-plugin/plugin.json"
	printf 'canonical body\n' >"$PLUGIN/hooks/foo.sh"
	(cd "$PLUGIN" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm x && git branch -M main) || return 1
	# Synthetic consumer: a git repo with NO plugin.json.
	(cd "$REPO" && git init -q && git config user.email t@t && git config user.name t) || return 1
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */cre.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# --- canonical_review_excluded (thin wrapper over canonical_consumer_skip) ---

@test "excluded: consumer + byte-identical canonical → EXCLUDE (rc 0)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded ".claude/hooks/foo.sh"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "excluded: consumer + modified canonical → review it (rc 1)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	printf '# local drift\n' >>"$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "excluded: consumer + non-canonical file → review it (rc 1)" {
	printf 'domain-only\n' >"$REPO/.claude/hooks/domain.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded ".claude/hooks/domain.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "excluded: plugin repo (has plugin.json) → NEVER exclude (rc 1)" {
	cd "$PLUGIN"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded "hooks/foo.sh"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "excluded: empty arg → review it (rc 1)" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded ""
	[ "$status" -eq 1 ]
	[ -z "$output" ]
}

@test "excluded: predicate unavailable (lib sourced without its sibling) → fail-safe review it (rc 1)" {
	# Copy ONLY canonical-review-exclude.sh somewhere WITHOUT canonical-consumer-
	# skip.sh beside it: the `. predicate || true` no-ops, canonical_consumer_skip
	# stays undefined, and the wrapper must fail SAFE toward reviewing.
	mkdir -p "$TEST_TMP/lonely"
	cp "$REVEX_SRC" "$TEST_TMP/lonely/canonical-review-exclude.sh"
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$TEST_TMP/lonely/canonical-review-exclude.sh"
	run canonical_review_excluded ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ]
}

# --- canonical_review_noncanonical_changed (diff minus excluded) ---

@test "noncanonical_changed (consumer): lists consumer-authored, drops byte-identical mirror" {
	cd "$REPO"
	printf 'readme\n' >README.md
	git add -A && git commit -qm base
	git branch -M main
	git checkout -q -b feat
	# Canonical mirror byte-identical to the pinned canonical → must be EXCLUDED.
	cp "$PLUGIN/hooks/foo.sh" ".claude/hooks/foo.sh"
	# Consumer-authored change (the pin) → must be INCLUDED.
	printf 'repos: []\n' >".pre-commit-config.yaml"
	git add -A && git commit -qm changes
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_noncanonical_changed main
	[ "$status" -eq 0 ]
	[[ $output == *".pre-commit-config.yaml"* ]] # consumer-authored present
	[[ $output != *".claude/hooks/foo.sh"* ]]    # canonical mirror absent
}

@test "noncanonical_changed (plugin): returns ALL changed files (producer, nothing excluded)" {
	cd "$PLUGIN"
	git checkout -q -b feat
	printf 'new body\n' >"hooks/bar.sh"
	git add -A && git commit -qm add-bar
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_noncanonical_changed main
	[ "$status" -eq 0 ]
	[[ $output == *"hooks/bar.sh"* ]]
}

@test "noncanonical_changed (consumer): all-canonical diff → empty output, rc 0" {
	# #2240 r1 pr-test-analyzer: the verbatim-treadmill terminator. A consumer
	# whose ENTIRE diff is byte-identical canonical mirrors must echo NOTHING
	# (rc 0) — the caller maps that to the 'return []' prompt.
	cd "$REPO"
	printf 'readme\n' >README.md
	git add -A && git commit -qm base
	git branch -M main
	git checkout -q -b feat
	mkdir -p ".claude/_lib"
	cp "$PLUGIN/hooks/foo.sh" ".claude/hooks/foo.sh"
	cp "$PLUGIN/_lib/canonical-consumer-skip.sh" ".claude/_lib/canonical-consumer-skip.sh"
	git add -A && git commit -qm all-canonical
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_noncanonical_changed main
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "noncanonical_changed: git diff failure (base ref absent) → rc 2 (fail-safe, not empty)" {
	# #2240 r1 silent-failure-hunter: a FAILED git diff must propagate as rc 2,
	# NOT a swallowed empty result that callers misread as 'nothing to review'.
	cd "$REPO"
	printf 'readme\n' >README.md
	git add -A && git commit -qm base
	git branch -M main
	git checkout -q -b feat
	printf 'x\n' >consumer.txt
	git add -A && git commit -qm change
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_noncanonical_changed nonexistent-base-ref
	[ "$status" -eq 2 ]
	[ -z "$output" ]
}

@test "noncanonical_changed (consumer): multiple consumer files all listed, mirror dropped" {
	# #2240 r1 pr-test-analyzer: prove per-file selectivity with >1 consumer file.
	cd "$REPO"
	printf 'readme\n' >README.md
	git add -A && git commit -qm base
	git branch -M main
	git checkout -q -b feat
	cp "$PLUGIN/hooks/foo.sh" ".claude/hooks/foo.sh" # canonical mirror → dropped
	printf 'a\n' >alpha.txt                          # consumer-authored → listed
	printf 'b\n' >beta.txt                           # consumer-authored → listed
	git add -A && git commit -qm changes
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_noncanonical_changed main
	[ "$status" -eq 0 ]
	[[ $output == *"alpha.txt"* ]]
	[[ $output == *"beta.txt"* ]]
	[[ $output != *".claude/hooks/foo.sh"* ]]
}
