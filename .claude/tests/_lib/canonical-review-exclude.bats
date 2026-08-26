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
	git add -A && git commit -qm mirror # #2329: review layers exclude on the COMMITTED blob
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded ".claude/hooks/foo.sh"
	[ "$status" -eq 0 ]
	[ -z "$output" ] # silent rc-function — must not leak stdout/stderr
}

@test "excluded: consumer + modified (committed-drift) canonical → review it (rc 1)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	printf '# local drift\n' >>"$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm drift # committed blob DIFFERS from canonical
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
	[ -z "$output" ] # fail-safe is silent — no stdout/stderr leak (#2240 phase2 CR)
}

@test "excluded: committed predicate gone, working-tree present → #2329 fallback EXCLUDES worktree mirror (rc 0)" {
	# #2327 r1 pr-test-analyzer: the #2329 committed→working-tree fallback branch.
	# An OLDER cached canonical-consumer-skip.sh (pre-#2328) defines only the
	# working-tree predicate; canonical_review_excluded must fall back to it, NOT
	# fail-safe to review. Simulate by unset-ing the committed fn post-source.
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# Byte-identical in the WORKING TREE (NOT committed) — the fallback's
	# working-tree predicate skips on the worktree file without needing a commit.
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	unset -f canonical_consumer_skip_committed
	run canonical_review_excluded ".claude/hooks/foo.sh"
	[ "$status" -eq 0 ] # fell back to working-tree predicate → excluded
	[ -z "$output" ]
}

@test "excluded: new (uncommitted) mirror not in HEAD → review it (rc 1), unlike working-tree" {
	# #2327 r1 pr-test-analyzer: the new-file behavior CHANGE at the review layer.
	# A file byte-identical to canonical in the WORKING TREE but not yet committed
	# is reviewed (committed predicate gates on HEAD) — phase1 scopes on
	# `git diff base..HEAD`. The old working-tree predicate would have EXCLUDED it.
	cd "$REPO"
	printf 'readme\n' >README.md
	git add -A && git commit -qm base                # HEAD exists, but foo.sh is NOT in it
	cp "$PLUGIN/hooks/foo.sh" ".claude/hooks/foo.sh" # worktree mirror, uncommitted
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_excluded ".claude/hooks/foo.sh"
	[ "$status" -eq 1 ] # not in HEAD → committed predicate reviews it
	[ -z "$output" ]
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
	[[ $output == *".pre-commit-config.yaml"* ]] # consumer-authored present || return 1
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
	# #2240 phase2 CR: the failure surfaces a diagnostic (not swallowed silently).
	[[ $output == *"git diff against base"* ]]
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
	[[ $output == *"alpha.txt"* ]] || return 1
	[[ $output == *"beta.txt"* ]] || return 1
	[[ $output != *".claude/hooks/foo.sh"* ]]
}

# --- canonical_review_filtered_finding_count (#2249 phase2 hash-filter) ---

@test "phase2_filtered_count (consumer): drops findings on canonical mirrors, keeps consumer-authored" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm mirror # #2329: phase2 exclusion is on the COMMITTED blob
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' \
		'{"type":"finding","fileName":".claude/hooks/foo.sh"}' \
		'{"type":"finding","fileName":".pre-commit-config.yaml"}' \
		'{"type":"complete","findings":2}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ] # canonical mirror dropped, consumer-authored kept
}

@test "phase2_filtered_count (plugin): counts ALL findings (producer, no exclusion)" {
	cd "$PLUGIN"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' \
		'{"type":"finding","fileName":"hooks/foo.sh"}' \
		'{"type":"finding","fileName":"hooks/bar.sh"}' \
		'{"type":"complete","findings":2}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 2 ]
}

@test "phase2_filtered_count: no finding lines → falls back to complete count" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' '{"type":"complete","findings":4}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 4 ]
}

@test "phase2_filtered_count: missing/unreadable file → 0" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	run canonical_review_filtered_finding_count "$TEST_TMP/nope.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 0 ]
}

@test "phase2_filtered_count: fail-safe — predicate unavailable → full count (no false-clean)" {
	# Source the function's file WITHOUT its sibling predicate beside it:
	# canonical_review_excluded falls safe (rc 1 = review) for every file, so
	# NOTHING is dropped → full count. Guards against a broken setup masking
	# real findings as clean.
	mkdir -p "$TEST_TMP/lonely"
	cp "$REVEX_SRC" "$TEST_TMP/lonely/canonical-review-exclude.sh"
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$TEST_TMP/lonely/canonical-review-exclude.sh"
	printf '%s\n' \
		'{"type":"finding","fileName":".claude/hooks/foo.sh"}' \
		'{"type":"finding","fileName":".pre-commit-config.yaml"}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 2 ]
}

@test "filtered_finding_count (consumer): all findings on canonical mirrors → 0" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	mkdir -p "$REPO/.claude/_lib"
	cp "$PLUGIN/_lib/canonical-consumer-skip.sh" "$REPO/.claude/_lib/canonical-consumer-skip.sh"
	cd "$REPO"
	git add -A && git commit -qm mirrors # #2329: phase2 exclusion is on the COMMITTED blob
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' \
		'{"type":"finding","fileName":".claude/hooks/foo.sh"}' \
		'{"type":"finding","fileName":".claude/_lib/canonical-consumer-skip.sh"}' \
		'{"type":"complete","findings":2}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 0 ] # all mirrors dropped; saw=1 so NOT the complete fallback
}

@test "filtered_finding_count: noisy TEE_OUT (banner lines interleaved) → counts findings, not 0" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	# Realistic CR-CLI TEE_OUT: status/banner/heartbeat noise around finding lines.
	# A whole-stream `jq -rs` slurp would FAIL on the non-JSON lines → silent 0.
	{
		echo '=== Running coderabbit review --agent -t committed --base main ==='
		echo '{"type":"status","phase":"analyzing"}'
		echo '{"type":"finding","fileName":".pre-commit-config.yaml"}'
		echo 'CodeRabbit: heartbeat reviewing...'
		echo '{"type":"finding","fileName":"README.md"}'
		echo '{"type":"complete","findings":2}'
	} >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 2 ] # both consumer findings counted despite the noise
}

@test "filtered_finding_count: finding keyed by .file (not .fileName) is handled" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm mirror # #2329: phase2 exclusion is on the COMMITTED blob
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' \
		'{"type":"finding","file":".claude/hooks/foo.sh"}' \
		'{"type":"finding","file":".pre-commit-config.yaml"}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ] # .file mirror dropped, .file consumer kept
}

@test "filtered_finding_count: path-less finding is KEPT (never under-counted)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	git add -A && git commit -qm mirror # #2329: phase2 exclusion is on the COMMITTED blob
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' \
		'{"type":"finding","fileName":".claude/hooks/foo.sh"}' \
		'{"type":"finding","message":"no path on this finding"}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ] # mirror dropped; the path-less finding KEPT (fail-safe)
}

@test "filtered_finding_count: complete event with null findings → 0" {
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' '{"type":"complete","findings":null}' >"$TEST_TMP/cr.jsonl"
	run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 0 ]
}

@test "filtered_finding_count: jq absent → full textual count (no filtering, fail-safe)" {
	cp "$PLUGIN/hooks/foo.sh" "$REPO/.claude/hooks/foo.sh"
	cd "$REPO"
	# shellcheck source=../../../_lib/canonical-review-exclude.sh
	. "$LIB"
	printf '%s\n' \
		'{"type":"finding","fileName":".claude/hooks/foo.sh"}' \
		'{"type":"finding","fileName":".pre-commit-config.yaml"}' >"$TEST_TMP/cr.jsonl"
	# A PATH with no jq → the function can't parse paths → keeps ALL finding
	# lines (fail-safe toward counting, NEVER a false-clean). grep is the only
	# external the jq-less path needs; symlink it into the restricted PATH.
	mkdir -p "$TEST_TMP/nojq"
	ln -s "$(command -v grep)" "$TEST_TMP/nojq/grep"
	PATH="$TEST_TMP/nojq" run canonical_review_filtered_finding_count "$TEST_TMP/cr.jsonl"
	[ "$status" -eq 0 ]
	[ "$output" -eq 2 ] # no jq → no exclusion → both kept (incl the mirror)
}
