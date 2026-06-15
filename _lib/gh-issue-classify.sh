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
# legitimate branch creation (silent-failure-hunter, #2416 r1). We anchor on the
# issue-scoped phrasing ("could not resolve to an issue|pull request") plus a
# literal "not found", which excludes the bare "could not resolve host/proxy"
# transport error and the "could not resolve to a Repository" permission error.
#
#   gh_issue_view_missing <errfile>
#     rc 0 = the error means the issue genuinely does not exist (deny-worthy)
#     rc 1 = not a not-found signal (transient/auth/network → caller fails open)
#   Missing/empty errfile → rc 1 (cannot prove not-found → treat as transient).

gh_issue_view_missing() {
	local errfile="${1:-}"
	[ -n "$errfile" ] && [ -f "$errfile" ] || return 1
	grep -qiE 'not found|could not resolve to an (issue|pull request)' "$errfile"
}
