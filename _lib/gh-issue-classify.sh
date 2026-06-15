#!/bin/bash
set -u
# _lib/gh-issue-classify.sh — SSOT for distinguishing a genuine "issue does not
# exist" gh failure from a transient (auth/network/rate-limit) one. Shared by
# EVERY enforcer that resolves a branch's issue (the issue-before-code creation
# gate + the meta-bootstrap PR-time verify) so the classification cannot drift
# between them (#2416 r2). NO inline copy of this rule in any consumer.
#
# Why a dedicated classifier: GitHub's GraphQL emits
#   "Could not resolve to an issue or pull request with the number of N"
# for a missing issue, whereas the transport layer emits
#   "Could not resolve host: api.github.com"
# for a DNS / network outage. A naive `grep "Could not resolve"` matches BOTH —
# so a network blip would be mis-read as "issue not found" and FALSE-DENY
# legitimate branch creation (silent-failure-hunter, #2416 r1). BOTH alternations
# are issue-anchored: the GraphQL "could not resolve to an issue|pull request"
# AND an "issue ... not found" phrasing. A bare "not found" is deliberately NOT
# matched — it would catch "Repository not found" (a repo/permission error, not a
# missing issue) and re-introduce the false-deny class (#2416 r4). Excludes the
# bare "could not resolve host/proxy" transport error too.
#
#   gh_issue_view_missing <errfile>
#     rc 0 = the error means the issue genuinely does not exist (deny-worthy)
#     rc 1 = not a not-found signal (transient/auth/network/repo → caller fails open)
#   Missing/empty errfile → rc 1 (cannot prove not-found → treat as transient).

gh_issue_view_missing() {
	local errfile="${1:-}"
	[ -n "$errfile" ] && [ -f "$errfile" ] || return 1
	# Normalize to the documented 0/1 contract: grep returns 2 on a read error,
	# which must collapse to rc 1 (cannot prove not-found → caller fails open).
	# 2>/dev/null: the function is rc-only — never leak grep's own stderr (e.g.
	# "Permission denied" on an unreadable errfile) to the caller's output.
	grep -qiE 'could not resolve to an (issue|pull request)|\bissue\b[^.]*\bnot found\b' "$errfile" 2>/dev/null && return 0
	return 1
}
