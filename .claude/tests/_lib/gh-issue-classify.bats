#!/usr/bin/env bats
# covers: _lib/gh-issue-classify.sh
#
# #2416 r2 — SSOT classifier that distinguishes a genuine "issue does not exist"
# gh error from a transient (auth/network/DNS) failure, shared by issue-before-
# code + meta-bootstrap so the rule cannot drift. The headline regression: a
# naive `grep "Could not resolve"` also matches the DNS-host transport error
# ("Could not resolve host: api.github.com") → a network blip would FALSE-DENY
# branch creation. These tests pin: real GraphQL not-found → rc0 (deny-worthy);
# DNS-host / proxy / connection errors → rc1 (transient); repository-resolution
# errors → rc1; missing/empty errfile → rc1.

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/gh-issue-classify.sh"
	[ -f "$LIB" ]
	TEST_TMP=$(mktemp -d -t ghic.XXXXXX) || return 1
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */ghic.* ]] && rm -rf "$TEST_TMP"
	return 0
}

# Write $2 to a temp errfile and run gh_issue_view_missing on it; echoes nothing,
# rc is the classification.
_classify() {
	printf '%s\n' "$2" >"$TEST_TMP/err.txt"
	run bash -c '. "$1"; gh_issue_view_missing "$2"' _ "$LIB" "$TEST_TMP/err.txt"
}

@test "real GraphQL missing-issue message → rc 0 (deny-worthy)" {
	_classify _ "GraphQL: Could not resolve to an issue or pull request with the number of 999999999. (repository.issue)"
	[ "$status" -eq 0 ]
}

@test "older capitalized 'Could not resolve to an Issue' → rc 0" {
	_classify _ "GraphQL: Could not resolve to an Issue with the number of 5"
	[ "$status" -eq 0 ]
}

@test "bare 'not found' (HTTP 404) → rc 0" {
	_classify _ "HTTP 404: Not Found (https://api.github.com/...)"
	[ "$status" -eq 0 ]
}

@test "DNS-host transport error → rc 1 (transient, NOT false not-found)" {
	_classify _ "fatal: unable to access: Could not resolve host: api.github.com"
	[ "$status" -eq 1 ]
}

@test "proxy-resolution error → rc 1 (transient)" {
	_classify _ "Could not resolve proxy: corp-proxy.internal"
	[ "$status" -eq 1 ]
}

@test "connection error → rc 1 (transient)" {
	_classify _ "error connecting to api.github.com port 443: Connection refused"
	[ "$status" -eq 1 ]
}

@test "not-a-git-repository context → rc 1 (non-issue error, no false 'not found')" {
	_classify _ "fatal: not a git repository (or any of the parent directories): .git"
	[ "$status" -eq 1 ]
}

@test "HTTP 403 forbidden (permission) → rc 1 (no issue-not-found signal)" {
	_classify _ "HTTP 403: Forbidden (https://api.github.com/repos/x/y/issues/5)"
	[ "$status" -eq 1 ]
}

@test "repository-resolution error → rc 1 (not an issue not-found)" {
	_classify _ "GraphQL: Could not resolve to a Repository with the name 'x/y'"
	[ "$status" -eq 1 ]
}

@test "missing errfile arg → rc 1" {
	run bash -c '. "$1"; gh_issue_view_missing ""' _ "$LIB"
	[ "$status" -eq 1 ]
}

@test "nonexistent errfile path → rc 1" {
	run bash -c '. "$1"; gh_issue_view_missing "$2"' _ "$LIB" "$TEST_TMP/does-not-exist"
	[ "$status" -eq 1 ]
}

@test "empty errfile → rc 1 (cannot prove not-found)" {
	: >"$TEST_TMP/empty.txt"
	run bash -c '. "$1"; gh_issue_view_missing "$2"' _ "$LIB" "$TEST_TMP/empty.txt"
	[ "$status" -eq 1 ]
}
