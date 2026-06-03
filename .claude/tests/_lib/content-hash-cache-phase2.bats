#!/usr/bin/env bats
# covers: _lib/content-hash-cache.sh
#
# v0.32.11 (#249-grp): unit-tests for the phase2 review-result cache (cap-reset
# treadmill fix). The cache lets ship-pr-cycle reuse a prior CR-CLI findings
# count when the committed review surface is unchanged, instead of re-invoking
# CR's non-deterministic engine (which oscillated false-positives + burned the
# 10/hr budget across 3 reviews of one unchanged SHA on PR #254). Locks: get
# miss → empty; put→get round-trip; latest-entry-wins; put rejects non-numeric
# count + empty key (best-effort — never writes garbage, never fails the
# caller); and the content key is deterministic + changes only when the
# reviewed diff content changes.

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/content-hash-cache.sh"
	[ -f "$LIB" ]
	command -v jq >/dev/null
	command -v git >/dev/null
	TEST_TMP=$(mktemp -d -t chcache.XXXXXX) || return 1
	export REPO_ROOT="$TEST_TMP"
	# shellcheck source=../../../_lib/content-hash-cache.sh
	. "$LIB"
	LEDGER="$TEST_TMP/.claude/.review-cache/phase2-results.jsonl"
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */chcache.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "get on absent ledger → miss (empty, rc 0)" {
	run phase2_review_cache_get deadbeef
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "put then get → hit (returns the count)" {
	phase2_review_cache_put deadbeef 3 abc1234
	run phase2_review_cache_get deadbeef
	[ "$status" -eq 0 ]
	[ "$output" = "3" ]
}

@test "latest entry wins for a key (most recent put)" {
	phase2_review_cache_put deadbeef 3 abc1234
	phase2_review_cache_put deadbeef 0 def5678
	run phase2_review_cache_get deadbeef
	[ "$output" = "0" ]
}

@test "get for an unknown key → miss" {
	phase2_review_cache_put deadbeef 3 abc1234
	run phase2_review_cache_get otherkey
	[ -z "$output" ]
}

@test "put rejects non-numeric count (no ledger write, rc 0)" {
	run phase2_review_cache_put somekey notanumber abc1234
	[ "$status" -eq 0 ]
	[ ! -f "$LEDGER" ] || [ "$(wc -l <"$LEDGER" | tr -d ' ')" = "0" ]
}

@test "put rejects empty key (no ledger write, rc 0)" {
	run phase2_review_cache_put "" 2 abc1234
	[ "$status" -eq 0 ]
	[ ! -f "$LEDGER" ] || [ "$(wc -l <"$LEDGER" | tr -d ' ')" = "0" ]
}

@test "key is deterministic + content-sensitive" {
	(
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
		printf 'one\n' >f.txt
		git add f.txt
		git commit -qm base
		git branch -M main # rename current branch to main regardless of git default
		git checkout -q -b feat
		printf 'two\n' >>f.txt
		git add f.txt
		git commit -qm change
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	local K1="$output"
	[ -n "$K1" ] # non-empty for a real (non-empty) diff
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	[ "$output" = "$K1" ] # deterministic: same surface → same key
	# A further commit that changes content must change the key (cache miss →
	# fresh review), which is what stops a stale-cache false hit.
	(cd "$TEST_TMP" && printf 'three\n' >>f.txt && git add f.txt && git commit -qm more)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	[ "$output" != "$K1" ] # content changed → key changed
}

@test "standalone fallback: REPO_ROOT unset resolves to repo root, not parent" {
	# CR #284: the suite always pre-sets REPO_ROOT, so the fixed `:-` fallback
	# (<repo>/_lib/.. = repo, was overshooting to the parent) could regress
	# unnoticed. Source with REPO_ROOT unset and assert it resolves to the repo.
	local expected
	expected=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
	run bash -c "unset REPO_ROOT; . '$LIB' && printf '%s' \"\$REPO_ROOT\""
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
}

@test "consumer layout: REPO_ROOT unset → git rev-parse root, CACHE_DIR not doubled .claude (#2224)" {
	# CR #2224 (critical): the dirname-relative fallback is LAYOUT-DEPENDENT. In
	# the PLUGIN this lib lives at <repo>/_lib/ (dirname/.. = repo, correct); in
	# CONSUMERS it lives at <repo>/.claude/_lib/ (dirname/.. = <repo>/.claude, one
	# level too shallow → CACHE_DIR became <repo>/.claude/.claude/.review-cache).
	# The fix prefers `git rev-parse --show-toplevel`, which is correct in BOTH
	# layouts. Reproduce the CONSUMER layout: copy the lib to <repo>/.claude/_lib/,
	# source with REPO_ROOT unset, assert REPO_ROOT = the true repo root and
	# CACHE_DIR = <repo>/.claude/.review-cache (NOT the doubled-.claude path). A
	# revert to dirname-relative-only FAILS here (resolves to <repo>/.claude).
	local crepo
	crepo=$(mktemp -d -t chcons.XXXXXX) || return 1
	(
		cd "$crepo"
		git init -q
		mkdir -p .claude/_lib
		cp "$LIB" .claude/_lib/content-hash-cache.sh
	)
	# True repo root (resolve symlinks: macOS /tmp → /private/tmp, matching what
	# `git rev-parse --show-toplevel` returns).
	local expected
	expected=$(cd "$crepo" && pwd -P)
	run bash -c "unset REPO_ROOT; . '$crepo/.claude/_lib/content-hash-cache.sh' && printf '%s\n%s' \"\$REPO_ROOT\" \"\$CACHE_DIR\""
	[ "$status" -eq 0 ]
	local got_root got_cache
	got_root=$(printf '%s' "$output" | sed -n '1p')
	got_cache=$(printf '%s' "$output" | sed -n '2p')
	[ "$got_root" = "$expected" ]
	[ "$got_cache" = "$expected/.claude/.review-cache" ]
	# Explicit anti-regression: the doubled-.claude path must NOT appear.
	[[ $got_cache != *"/.claude/.claude/"* ]]
	rm -rf "$crepo"
}

@test "cache_prune prunes PHASE2_RESULT_LEDGER (old dropped, recent kept)" {
	# CR #284: the new dual-ledger retention path was unpinned. Seed one ancient
	# + one future-dated entry; prune drops the ancient, keeps the future one.
	mkdir -p "$(dirname "$LEDGER")"
	printf '{"ts":"2000-01-01T00:00:00Z","content_hash":"old","sha":"a","findings":1}\n' >"$LEDGER"
	printf '{"ts":"2099-01-01T00:00:00Z","content_hash":"new","sha":"b","findings":0}\n' >>"$LEDGER"
	run cache_prune 30
	[ "$status" -eq 0 ]
	run grep -c '"content_hash":"old"' "$LEDGER"
	[ "$output" = "0" ] # ancient entry pruned
	run grep -c '"content_hash":"new"' "$LEDGER"
	[ "$output" = "1" ] # recent entry kept
}

@test "empty review surface → stable empty-blob key (not empty output)" {
	(
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
		printf 'x\n' >f.txt
		git add f.txt
		git commit -qm base
		git branch -M main
		git checkout -q -b feat # no new commits → main...HEAD diff is empty
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	# An empty surface hashes to git's well-known empty-blob SHA — a stable,
	# valid key. Two empty surfaces ARE genuinely identical, so a shared key is
	# safe (and phase2 is only reached with >=1 commit ahead anyway).
	[ "$output" = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" ]
}

@test "malformed ledger line → clean miss + stderr breadcrumb (never a crash)" {
	mkdir -p "$(dirname "$LEDGER")"
	printf 'this is not json\n' >"$LEDGER"
	run phase2_review_cache_get somekey
	[ "$status" -eq 0 ]                 # best-effort: never fails caller
	[[ $output == *"jq read failed"* ]] # surfaces a breadcrumb (fail-safe → fresh review)
}
