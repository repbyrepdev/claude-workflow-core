#!/usr/bin/env bats
# covers: _lib/repo-guard.sh
#
# #223 conditional-SSOT-hook guard. repo_guard_require lets a single
# plugin-shipped hook SELF-SKIP outside its target repo(s). These tests lock:
#   - matching repo (via origin basename) → continue (rc 0);
#   - non-matching repo → signals skip (rc 1);
#   - multi-slug → matches any one of the given slugs;
#   - no-origin → falls back to git toplevel dir basename;
#   - not-in-git → falls back to $PWD basename;
#   - case-insensitive + .git-suffix + owner/ prefix tolerance;
#   - zero-slug programming error → rc 2;
#   - defensive under set -u (no crash / no hard-error).
#
# Each test builds a synthetic repo dir under a mktemp -d sandbox and sources
# the lib fresh, so detection runs against the fixture, not the real repo.

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/repo-guard.sh"
	[ -f "$LIB" ]
	TEST_TMP=$(mktemp -d -t rgd.XXXXXX) || return 1
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */rgd.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# Helper: make a git repo at $TEST_TMP/<dirname> with optional origin url.
_mkrepo() {
	local dirname="$1" url="${2:-}"
	local d="$TEST_TMP/$dirname"
	mkdir -p "$d"
	git -C "$d" init -q .
	[ -n "$url" ] && git -C "$d" remote add origin "$url"
	printf '%s' "$d"
}

@test "matching repo (origin ssh url + .git) → continue (rc 0)" {
	d=$(_mkrepo media-server "git@github.com:acme/media-server.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_require media-server' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
}

@test "non-matching repo → signals skip (rc 1)" {
	d=$(_mkrepo media-server "git@github.com:acme/media-server.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_require pricing-team-toolkit' _ "$LIB" "$d"
	[ "$status" -eq 1 ]
}

@test "multi-slug → matches any one of the given slugs (rc 0)" {
	d=$(_mkrepo homelab "git@github.com:x/homelab.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_require media-server homelab pricing-team-toolkit' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
}

@test "multi-slug with NO match → skip (rc 1)" {
	d=$(_mkrepo some-other-repo "git@github.com:x/some-other-repo.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_require media-server homelab' _ "$LIB" "$d"
	[ "$status" -eq 1 ]
}

@test "no-origin → falls back to git toplevel dir basename" {
	d=$(_mkrepo pricing-team-toolkit "")
	# Detected slug should be the toplevel dir basename.
	run bash -c '. "$1"; cd "$2"; repo_guard_current_repo' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
	[ "$output" = "pricing-team-toolkit" ]
	# And require against that basename should match.
	run bash -c '. "$1"; cd "$2"; repo_guard_require pricing-team-toolkit' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
}

@test 'not-in-git → falls back to $PWD basename' {
	d="$TEST_TMP/coalesce-thing"
	mkdir -p "$d" # deliberately NOT a git repo
	run bash -c '. "$1"; cd "$2"; repo_guard_current_repo' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
	[ "$output" = "coalesce-thing" ]
	run bash -c '. "$1"; cd "$2"; repo_guard_require coalesce-thing' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
}

@test "case-insensitive + owner-prefixed slug tolerance" {
	d=$(_mkrepo Media-Server "https://github.com/Acme/Media-Server.git")
	# detected slug is lowercased
	run bash -c '. "$1"; cd "$2"; repo_guard_current_repo' _ "$LIB" "$d"
	[ "$output" = "media-server" ]
	# UPPERCASE slug matches
	run bash -c '. "$1"; cd "$2"; repo_guard_require MEDIA-SERVER' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
	# owner-qualified slug matches
	run bash -c '. "$1"; cd "$2"; repo_guard_require acme/media-server' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
	# owner-qualified + .git slug matches
	run bash -c '. "$1"; cd "$2"; repo_guard_require Acme/Media-Server.git' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
}

@test "origin basename WINS over toplevel dir basename" {
	# Working dir is named 'relocated-clone' but origin says media-server.
	d=$(_mkrepo relocated-clone "git@github.com:acme/media-server.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_current_repo' _ "$LIB" "$d"
	[ "$output" = "media-server" ]
	# Requiring the dir name should NOT match (origin is authoritative).
	run bash -c '. "$1"; cd "$2"; repo_guard_require relocated-clone' _ "$LIB" "$d"
	[ "$status" -eq 1 ]
	run bash -c '. "$1"; cd "$2"; repo_guard_require media-server' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
}

@test "zero slugs → rc 2 (programming error, signalled)" {
	d=$(_mkrepo media-server "git@github.com:acme/media-server.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_require' _ "$LIB" "$d"
	[ "$status" -eq 2 ]
	[[ $output == *"at least one repo-slug"* ]]
}

@test "defensive under set -euo pipefail (no crash, clean skip)" {
	d=$(_mkrepo media-server "git@github.com:acme/media-server.git")
	# Source under strict mode and require a NON-matching repo: must return 1
	# cleanly, NOT abort the strict-mode caller.
	run bash -c 'set -euo pipefail; . "$1"; cd "$2"; repo_guard_require not-this-repo || echo "skipped-cleanly"' _ "$LIB" "$d"
	[ "$status" -eq 0 ]
	[ "$output" = "skipped-cleanly" ]
}

@test "scp-style host:owner/repo url resolves to repo basename" {
	d=$(_mkrepo whatever "git@github.com:acme/pricing-team-toolkit.git")
	run bash -c '. "$1"; cd "$2"; repo_guard_current_repo' _ "$LIB" "$d"
	[ "$output" = "pricing-team-toolkit" ]
}
