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

@test "audit-ledger + session-state commits do NOT change the key (#2230 no treadmill)" {
	# v0.34.30 (#2230): the prove-yourself audit ledger lives IN CR's committed
	# review surface; before the pathspec exclude, committing audit records busted
	# this content-hash key + needlessly re-triggered the CR-CLI (the audit-commit
	# treadmill). Assert the key is INVARIANT to a commit that touches ONLY
	# .claude/audit/prove-yourself.jsonl (and .claude/.session-state/) while the
	# real code under review is unchanged.
	(
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
		printf 'one\n' >f.txt
		git add f.txt
		git commit -qm base
		git branch -M main
		git checkout -q -b feat
		printf 'two\n' >>f.txt
		git add f.txt
		git commit -qm change
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	local K1="$output"
	[ -n "$K1" ]
	# Commit ONLY audit/session-state bookkeeping — no change to f.txt.
	(
		cd "$TEST_TMP"
		mkdir -p .claude/audit .claude/.session-state/prove-yourself
		printf '{"finding":"x","status":"covered"}\n' >.claude/audit/prove-yourself.jsonl
		printf '{"id":"y"}\n' >.claude/.session-state/prove-yourself/y.json
		git add -f .claude/audit/prove-yourself.jsonl .claude/.session-state/prove-yourself/y.json
		git commit -qm "audit: record finding"
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	# Key UNCHANGED: the excluded paths never enter the review-surface hash, so an
	# audit-only commit is a cache HIT (no needless re-review).
	[ "$output" = "$K1" ]
	# Sanity: a real code change still busts the key (exclude isn't over-broad).
	(cd "$TEST_TMP" && printf 'three\n' >>f.txt && git add f.txt && git commit -qm real)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	[ "$output" != "$K1" ]
}

@test "exclude is file/dir-PRECISE: sibling paths inside the namespaces still bust the key (#2230 not over-broad)" {
	# r1 pr-test-analyzer (#2230): the #2230-treadmill test above proves the
	# excludes HIT the two bookkeeping paths; this test pins the OTHER boundary —
	# the excludes are file/dir-precise, NOT a broad `.claude/**` or
	# `.claude/audit/**` glob. A future glob-broadening (e.g. excluding all of
	# .claude/audit/ or all of .claude/) would silently stop reviewing real code
	# living beside the bookkeeping paths; this assertion breaches first.
	#   - `:(exclude).claude/audit/prove-yourself.jsonl` is a SINGLE FILE — a
	#     sibling .claude/audit/other.jsonl must NOT be excluded.
	#   - `:(exclude).claude/.session-state/` is ONE DIR — a non-session-state
	#     file directly under .claude/ must NOT be excluded.
	(
		cd "$TEST_TMP"
		git init -q
		git config user.email t@t.t
		git config user.name t
		printf 'one\n' >f.txt
		git add f.txt
		git commit -qm base
		git branch -M main
		git checkout -q -b feat
		printf 'two\n' >>f.txt
		git add f.txt
		git commit -qm change
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	local K1="$output"
	[ -n "$K1" ]
	# A SIBLING file under .claude/audit/ (NOT prove-yourself.jsonl) must change
	# the key — only the named file is excluded, not the whole dir.
	(
		cd "$TEST_TMP"
		mkdir -p .claude/audit
		printf '{"other":"record"}\n' >.claude/audit/other.jsonl
		git add -f .claude/audit/other.jsonl
		git commit -qm "audit: sibling file (not excluded)"
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	local K2="$output"
	[ "$K2" != "$K1" ] # sibling under .claude/audit/ is reviewed → key changed
	# A non-session-state file directly under .claude/ must ALSO change the key —
	# only .claude/.session-state/ is excluded, not all of .claude/.
	(
		cd "$TEST_TMP"
		printf 'config\n' >.claude/other-config.txt
		git add -f .claude/other-config.txt
		git commit -qm "claude: non-session-state file (not excluded)"
	)
	run phase2_review_cache_key main
	[ "$status" -eq 0 ]
	[ "$output" != "$K2" ] # file directly under .claude/ is reviewed → key changed
}

@test "standalone fallback: REPO_ROOT unset resolves to repo root, not parent" {
	# CR #284: the suite always pre-sets REPO_ROOT, so the fixed `:-` fallback
	# (<repo>/_lib/.. = repo, was overshooting to the parent) could regress
	# unnoticed. Source with REPO_ROOT unset and assert it resolves to the repo.
	local expected
	# pwd -P (physical): git rev-parse --show-toplevel resolves symlinks, so a
	# symlinked checkout would false-fail a logical-pwd assertion (CR #2226;
	# mirrors the consumer-layout test below).
	expected=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd -P)
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
	# NB: cleanup is the final `rm -rf "$crepo"` below. A bats `RETURN` trap here
	# (CR #2226 suggestion) BREAKS bats — bats uses RETURN traps for its own
	# per-test teardown, so overriding it fails the test (`not ok ... rm failed`).
	# A leaked temp dir on a rare mid-test failure is trivial (OS cleans TMPDIR).
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

@test "put with an unwritable ledger → best-effort rc 0 + 'phase2 cache write failed' breadcrumb (#2230)" {
	# r1 pr-test-analyzer (#2230): the v0.34.30 phase2_review_cache_put breadcrumb
	# (a write to a read-only CACHE_DIR / degraded jq) had no coverage. Mirror the
	# GET-path "jq read failed" test above: point PHASE2_RESULT_LEDGER at a file
	# under a chmod-555 dir so the `>>` append fails with EACCES, then assert the
	# function is still best-effort (rc 0) AND surfaces the breadcrumb.
	if [ "$(id -u)" -eq 0 ]; then
		skip "non-root only — write-failure relies on DAC perms root bypasses (#2230)"
	fi
	local rodir="$TEST_TMP/readonly"
	mkdir -p "$rodir"
	chmod 555 "$rodir"
	# Restore +w in teardown's reach: TEST_TMP rm -rf needs to recurse in.
	export PHASE2_RESULT_LEDGER="$rodir/phase2-results.jsonl"
	run phase2_review_cache_put goodkey 3 abc1234
	chmod u+w "$rodir"                             # so teardown's rm -rf can recurse
	[ "$status" -eq 0 ]                            # best-effort: a write miss never fails the cycle
	[[ $output == *"phase2 cache write failed"* ]] # surfaces a breadcrumb
	[ ! -s "$PHASE2_RESULT_LEDGER" ]               # nothing landed (write was denied)
}

# --- #2490/#2491: findings_detail round-trip ------------------------------
# The count-only cache produced a directive that told the operator to "address
# EACH of the N findings" while handing them nothing but N. These pin the
# detail channel AND its fail-open contract: a bad detail blob must never cost
# us the COUNT, which is what the cache-hit decision actually runs on.

_detail2='[{"severity":"major","file":"a.sh","summary":"boom"},{"severity":"minor","file":"b.sh","summary":"meh"}]'

@test "put with detail → get_detail returns the array, get still returns the count (#2491)" {
	phase2_review_cache_put k1 2 abc1234 "$_detail2"
	run phase2_review_cache_get_detail k1
	[ "$status" -eq 0 ]
	[ "$output" = "$_detail2" ]
	# The count accessor's contract is unchanged — a bare integer.
	run phase2_review_cache_get k1
	[ "$status" -eq 0 ]
	[ "$output" = "2" ]
}

@test "legacy record with no findings_detail → get_detail empty, get unaffected (#2491)" {
	mkdir -p "$(dirname "$LEDGER")"
	printf '{"ts":"2026-01-01T00:00:00Z","content_hash":"legacy","sha":"old","findings":4}\n' >"$LEDGER"
	run phase2_review_cache_get_detail legacy
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run phase2_review_cache_get legacy
	[ "$output" = "4" ]
}

@test "get_detail on an unknown key → empty, rc 0 (#2491)" {
	phase2_review_cache_put k1 1 abc1234 "$_detail2"
	run phase2_review_cache_get_detail nosuchkey
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "malformed detail still writes the COUNT, detail degrades to [] (#2491)" {
	run phase2_review_cache_put k2 7 def5678 "{not an array}"
	[ "$status" -eq 0 ]
	[[ $output == *"findings_detail is not a single JSON array"* ]] # named, never silent
	run phase2_review_cache_get k2
	[ "$output" = "7" ] # the count — the thing cache-hit decisions run on — survived
	run phase2_review_cache_get_detail k2
	[ "$output" = "[]" ]
}

@test "non-array JSON detail (bare object) is rejected → [] (#2491)" {
	phase2_review_cache_put k3 1 aaa1111 '{"severity":"major"}' 2>/dev/null
	run phase2_review_cache_get_detail k3
	[ "$output" = "[]" ]
}

@test "multi-value detail payload is rejected → [] (slurp guard) (#2491)" {
	# `[1] [2]` is two top-level JSON values; without -s this would smuggle a
	# second line into a JSONL ledger every reader parses with jq -rs.
	phase2_review_cache_put k4 1 bbb2222 '[1] [2]' 2>/dev/null
	run phase2_review_cache_get_detail k4
	[ "$output" = "[]" ]
}

@test "omitted detail arg writes [] and is backward compatible (#2491)" {
	phase2_review_cache_put k5 3 ccc3333
	run phase2_review_cache_get k5
	[ "$output" = "3" ]
	run phase2_review_cache_get_detail k5
	[ "$output" = "[]" ]
}

@test "multi-line detail is compacted — JSONL one-object-per-line invariant holds (#2491)" {
	# A pretty-printed blob must not become N ledger lines: cache_prune's line
	# filter and every `jq -rs` reader depend on one object per line.
	local pretty
	pretty=$(printf '%s' "$_detail2" | jq .)
	phase2_review_cache_put k6 2 ddd4444 "$pretty"
	[ "$(wc -l <"$LEDGER" | tr -d ' ')" = "1" ]
	[ "$(jq -s length "$LEDGER")" = "1" ]
	run phase2_review_cache_get_detail k6
	[ "$output" = "$_detail2" ]
}

@test "latest-wins applies to detail as well as count (#2491)" {
	phase2_review_cache_put k7 2 eee5555 "$_detail2"
	phase2_review_cache_put k7 0 fff6666 '[]'
	run phase2_review_cache_get k7
	[ "$output" = "0" ]
	run phase2_review_cache_get_detail k7
	[ "$output" = "[]" ]
}

@test "get_detail on a corrupt ledger → empty + breadcrumb, never a crash (#2491)" {
	mkdir -p "$(dirname "$LEDGER")"
	printf 'not json {{{\n' >"$LEDGER"
	run phase2_review_cache_get_detail anykey
	[ "$status" -eq 0 ]
	[[ $output == *"jq read failed"* ]]
}
