#!/usr/bin/env bats
# covers: skills/github-pr-merge/_approval-gate.sh skills/github-pr-merge/run.sh
# shellcheck disable=SC2030,SC2031  # bats runs each @test in a subshell
# #2567 approving-review merge gate. The refuse branches are the security
# value: the gate must never nudge `@coderabbitai approve` onto a head
# that has findings or that CR has not verifiably reviewed — including
# CodeRabbit's rate-limit notice, which QUOTES the head sha while
# announcing the review did NOT run (Phase 1 critical finding) — and the
# audited skip must fail closed when the audit row cannot be written.

bats_require_minimum_version 1.5.0

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	GATE="${REPO_ROOT}/skills/github-pr-merge/_approval-gate.sh"
	RUNSH="${REPO_ROOT}/skills/github-pr-merge/run.sh"
	TEST_TMP=$(mktemp -d -t gh-pr-merge-approval.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	export GH_ARGS_LOG="$TEST_TMP/gh-args.log"
	export HEAD_SHA="aaaa000011112222333344445555666677778888"
	# Every test overrides the production seams explicitly.
	export APPROVAL_GATE_POLICY="$TEST_TMP/approval-policy.yml"
	export APPROVAL_GATE_FINDINGS_BIN="$TEST_TMP/findings.sh"
	export APPROVAL_GATE_POLL_SECONDS=1
	_write_policy 1
	_write_findings 0
}

teardown() {
	cd "${TMPDIR:-/tmp}" 2>/dev/null || cd "$HOME" || return 0
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */gh-pr-merge-approval.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# assert_output_contains / assert_output_lacks and WHY they exist:
# .claude/tests/assert.bash (#2631 — a bare [[ ]] cannot fail on bash 3.2).
load ../assert

# Policy fixture. $1 = nudge_timeout_seconds, $2 = require value
# (default true). Regenerated whole per test — no in-place sed (BSD/GNU
# portability).
_write_policy() {
	cat >"$TEST_TMP/approval-policy.yml" <<EOF
require_approving_review: ${2:-true}
approvers:
  - coderabbitai[bot]
  - copilot-pull-request-reviewer[bot]
nudge_comment: "@coderabbitai approve"
nudge_timeout_seconds: $1
EOF
}

# Convergence-checker stub. $1 = exit code.
_write_findings() {
	printf '#!/bin/bash\nexit %s\n' "$1" >"$TEST_TMP/findings.sh"
	chmod +x "$TEST_TMP/findings.sh"
}

_shim_bin_setup() {
	mkdir -p "$TEST_TMP/bin"
	export PATH="$TEST_TMP/bin:$PATH"
	export NUDGE_MARKER="$TEST_TMP/nudge-posted"
}

# gh shim for driving the GATE directly. Reviews payload comes from
# FAKE_REVIEWS_FILE; after a nudge (`pr comment`) is posted, subsequent
# reviews calls serve FAKE_REVIEWS_AFTER_FILE when set (the record
# "landing"). Comments from FAKE_COMMENTS_FILE. The default-branch
# policy read is served by the contents arms:
# FAKE_CONTENTS_MODE=404|proxy404|err|ok, with FAKE_REMOTE_POLICY_FILE
# for ok. FAKE_COMMENT_FAIL=1 makes the nudge post fail. Unknown calls
# are LOUD failures.
_install_gh_shim() {
	_shim_bin_setup
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
log() { printf '%s\n' "$*" >>"$GH_ARGS_LOG"; }
jqarg() {
	local prev="" a
	for a in "$@"; do
		[ "$prev" = "--jq" ] && {
			printf '%s' "$a"
			return 0
		}
		prev="$a"
	done
	return 1
}
if [ "$1 $2" = "pr comment" ]; then
	log "$@"
	if [ "${FAKE_COMMENT_FAIL:-0}" = "1" ]; then
		echo "gh: comment post failed" >&2
		exit 1
	fi
	touch "$NUDGE_MARKER"
	exit 0
fi
case "$*" in
*"/contents/"*)
	log "contents-query"
	case "${FAKE_CONTENTS_MODE:-ok}" in
	404)
		echo "gh: Not Found (HTTP 404)" >&2
		exit 1
		;;
	proxy404)
		# An intermediary's 404 body relayed by gh — must NOT read as
		# "not adopted" (that was the r2 critical fail-open).
		echo "gh: 404 page not found" >&2
		exit 1
		;;
	err)
		echo "gh: boom (HTTP 500)" >&2
		exit 1
		;;
	*)
		# Realistic contents-API shape (CR-in-CI r1): a JSON body with
		# base64 `content`, run through the caller's --jq — so the
		# gate's real .content extraction AND decode are exercised,
		# not shim-shortcut around.
		body=$(printf '{"content":"%s"}' "$(base64 <"$FAKE_REMOTE_POLICY_FILE" | tr -d '\n')")
		if q=$(jqarg "$@"); then
			printf '%s\n' "$body" | jq -r "$q"
		else
			printf '%s\n' "$body"
		fi
		;;
	esac
	;;
*" --jq .default_branch"*)
	echo "main"
	;;
*"/pulls/"*"/reviews"*)
	log "reviews-query"
	if [ -f "$NUDGE_MARKER" ] && [ -n "${FAKE_REVIEWS_AFTER_FILE:-}" ]; then
		exec cat "$FAKE_REVIEWS_AFTER_FILE"
	fi
	exec cat "$FAKE_REVIEWS_FILE"
	;;
*"/issues/"*"/comments"*)
	log "comments-query"
	exec cat "${FAKE_COMMENTS_FILE:-/dev/null}"
	;;
*)
	log "UNEXPECTED gh: $*"
	echo "gh-shim: UNEXPECTED: $*" >&2
	exit 1
	;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
}

# gh shim for driving run.sh end-to-end. Implements --jq with real jq so
# run.sh's own queries (stranded-threads graphql, owner slug,
# mergeCommit) behave. FAKE_STATE is served raw and PRE-SHAPED (the
# post-jq object run.sh expects) — its arm does not apply --jq. The
# gate's queries hit the same reviews/comments fixtures as the unit shim
# (no FAKE_REVIEWS_AFTER_FILE nudge-landing switch here). Unmatched
# calls FAIL LOUDLY — an rc-0 "{}" catch-all let the wiring tests pass
# while exercising nothing (r2 finding).
_install_runsh_gh_shim() {
	_shim_bin_setup
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
log() { printf '%s\n' "$*" >>"$GH_ARGS_LOG"; }
jqarg() {
	local prev="" a
	for a in "$@"; do
		[ "$prev" = "--jq" ] && {
			printf '%s' "$a"
			return 0
		}
		prev="$a"
	done
	return 1
}
emit() { # $1 = raw JSON; applies --jq when present
	local q
	if q=$(jqarg "${ORIG_ARGS[@]}"); then
		printf '%s\n' "$1" | jq -r "$q"
	else
		printf '%s\n' "$1"
	fi
}
ORIG_ARGS=("$@")
log "$@"
if [ "$1 $2" = "pr comment" ]; then
	touch "$NUDGE_MARKER"
	exit 0
fi
if [ "$1 $2" = "pr merge" ]; then
	if [ "${FAKE_MERGE_FAIL:-0}" = "1" ]; then
		echo "GraphQL: Head branch was modified. Review and try the merge again." >&2
		exit 1
	fi
	echo "MERGE-FIRED"
	exit 0
fi
case "$*" in
*statusCheckRollup*) printf '%s\n' "$FAKE_STATE" ;;
*nameWithOwner*) emit '{"nameWithOwner":"testowner/testrepo"}' ;;
*"/pulls/"*"/reviews"*) cat "$FAKE_REVIEWS_FILE" ;;
*"/issues/"*"/comments"*) cat "${FAKE_COMMENTS_FILE:-/dev/null}" ;;
*graphql*) emit '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
*mergeCommit*) emit '{"mergeCommit":{"oid":"cafecafe0000111122223333444455556666cafe"}}' ;;
*deleteBranchOnMerge*) emit '{"deleteBranchOnMerge":false}' ;;
*)
	log "UNEXPECTED gh: $*"
	echo "gh-shim: UNEXPECTED: $*" >&2
	exit 1
	;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$HEAD_SHA"'","checks":[]}'
}

# Reviews fixture setter — JSON stays visible at each call site.
_reviews() {
	printf '%s' "$1" >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
}

_reviews_approved_at_head() {
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""}]'
}

_reviews_stale_cr() { # CHANGES_REQUESTED on an older commit, nothing at head
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"oldold1111","submitted_at":"2026-08-24T15:00:00Z","body":""}]'
}

_comments_with_head_witness() {
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"Reviewing files that changed between oldold1111 and %s."}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
}

_reviews_after_approved_at_head() {
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:31:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews-after.json"
	export FAKE_REVIEWS_AFTER_FILE="$TEST_TMP/reviews-after.json"
}

_comments_without_witness() {
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"Reviewing files between oldold1111 and beefbeef2222."}]' >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
}

_run_gate() {
	run "$GATE" --pr 99 --head "$HEAD_SHA" --owner-name testowner/testrepo
}

# ---------- policy acquisition ----------

@test "seam policy path pointing nowhere fails CLOSED (one env var must not disable the gate)" {
	_install_gh_shim
	rm -f "$APPROVAL_GATE_POLICY"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"does not exist"* ]] || return 1
	[ ! -f "$GH_ARGS_LOG" ]
}

@test "default-branch policy: fetched and honored (require:false)" {
	_install_gh_shim
	unset APPROVAL_GATE_POLICY
	_write_policy 1 false
	export FAKE_REMOTE_POLICY_FILE="$TEST_TMP/approval-policy.yml" FAKE_CONTENTS_MODE=ok
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"gate disabled"* ]] || return 1
	grep -q "contents-query" "$GH_ARGS_LOG"
}

@test "default-branch policy 404: not adopted, gate disabled loudly" {
	_install_gh_shim
	unset APPROVAL_GATE_POLICY
	export FAKE_CONTENTS_MODE=404
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"DISABLED"* ]]
}

@test "default-branch policy fetch error (non-404) fails CLOSED" {
	_install_gh_shim
	unset APPROVAL_GATE_POLICY
	export FAKE_CONTENTS_MODE=err
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"policy fetch"*"failed"* ]]
}

@test "the repo's REAL policy file parses through the real parser" {
	_install_gh_shim
	export APPROVAL_GATE_POLICY="$REPO_ROOT/.github/approval-policy.yml"
	_reviews_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"APPROVED bot review at final head"* ]]
}

# ---------- policy parse ----------

@test "require_approving_review: false disables the gate" {
	_install_gh_shim
	_write_policy 1 false
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"gate disabled"* ]]
}

@test "present-but-broken policy fails CLOSED (garbage require value)" {
	_install_gh_shim
	_write_policy 1 yes-ish
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"fail-closed"* ]]
}

@test "empty approvers list fails CLOSED" {
	_install_gh_shim
	grep -v '^  - ' "$APPROVAL_GATE_POLICY" >"$TEST_TMP/p2" && mv "$TEST_TMP/p2" "$APPROVAL_GATE_POLICY"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"no approvers"* ]]
}

@test "full-line comment INSIDE the approvers block does not truncate the list" {
	_install_gh_shim
	cat >"$APPROVAL_GATE_POLICY" <<EOF
require_approving_review: true
approvers:
  - coderabbitai[bot]
  # copilot below survives this comment
  - copilot-pull-request-reviewer[bot]
nudge_timeout_seconds: 1
EOF
	_reviews '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""}]'
	_run_gate
	[ "$status" -eq 0 ]
}

@test "garbage nudge_timeout_seconds fails CLOSED" {
	_install_gh_shim
	_write_policy notanumber
	_reviews_stale_cr
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"want integer"* ]]
}

@test "non-positive poll interval fails CLOSED" {
	_install_gh_shim
	_reviews_stale_cr
	APPROVAL_GATE_POLL_SECONDS=0 _run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"poll interval"* ]]
}

@test "missing option value exits 2 with usage, not a silent rc 1" {
	run "$GATE" --pr
	[ "$status" -eq 2 ]
	[[ $output == *"Usage:"* ]]
}

# ---------- the APPROVED-record predicate ----------

@test "APPROVED at head passes with NO nudge posted" {
	_install_gh_shim
	_reviews_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"APPROVED bot review at final head"* ]] || return 1
	run ! grep -q "pr comment" "$GH_ARGS_LOG"
}

@test "copilot APPROVED at head passes too (second policy login)" {
	_install_gh_shim
	_reviews '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""}]'
	_run_gate
	[ "$status" -eq 0 ]
}

@test "human APPROVED at head does NOT satisfy the bot policy" {
	_install_gh_shim
	_reviews '[{"user":{"login":"somehuman"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""}]'
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]]
}

@test "a later COMMENTED record does NOT displace an APPROVED at head" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":"thread replies"}]'
	_run_gate
	[ "$status" -eq 0 ]
	run ! grep -q "pr comment" "$GH_ARGS_LOG"
}

@test "latest-per-bot ordering: APPROVED superseded by CHANGES_REQUESTED does not pass" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""}]'
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "ordering is by submitted_at, not array position (reverse-chronological payload)" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:00:00Z","body":""}]'
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
}

@test "stale APPROVED on a non-head commit does not cover the head" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"oldold1111","submitted_at":"2026-08-24T15:00:00Z","body":""}]'
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]]
}

@test "multi-page concatenated reviews payload: APPROVED on page 2 is found" {
	_install_gh_shim
	printf '[{"user":{"login":"somehuman"},"state":"COMMENTED","commit_id":"x","submitted_at":"2026-08-24T14:00:00Z","body":""}]\n[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:00:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "the record IS the gate: APPROVED at head passes even with findings-bin failing" {
	_install_gh_shim
	_reviews_approved_at_head
	_write_findings 1
	_run_gate
	[ "$status" -eq 0 ]
}

# ---------- laundering guards ----------

@test "LAUNDERING GUARD: findings present -> refuse, nudge NEVER posted" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_with_head_witness
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "LAUNDERING GUARD: head unreviewed (no witness) -> refuse, nudge NEVER posted" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_without_witness
	_write_findings 0
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"not verifiably reviewed"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "LAUNDERING GUARD: rate-limit notice quoting the head sha is NOT a witness" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n> ## Review limit reached\\n> Reviewing files that changed from the base of the PR and between oldold1111 and %s."}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"not verifiably reviewed"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

# ---------- convergence + nudge ----------

@test "converged-but-unrecorded: nudge posted with -R, record lands, gate passes" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_with_head_witness
	_write_findings 0
	_write_policy 5
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"oldold1111","submitted_at":"2026-08-24T15:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:31:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews-after.json"
	export FAKE_REVIEWS_AFTER_FILE="$TEST_TMP/reviews-after.json"
	_run_gate
	[ "$status" -eq 0 ]
	grep -q "pr comment 99 -R testowner/testrepo --body @coderabbitai approve" "$GH_ARGS_LOG"
	[[ $output == *"APPROVED record landed"* ]]
}

@test "structured witness: a bot record pinned to head (any state) permits the nudge" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:30:00Z","body":"thread replies"}]'
	_comments_without_witness
	_write_findings 0
	_write_policy 5
	_reviews_after_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	grep -q "pr comment" "$GH_ARGS_LOG"
}

@test "nudge timeout without a record refuses" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_with_head_witness
	_write_findings 0
	_write_policy 1
	# no FAKE_REVIEWS_AFTER_FILE: the record never lands
	_run_gate
	[ "$status" -eq 2 ]
	[ -f "$NUDGE_MARKER" ]
	[[ $output == *"no APPROVED record within"* ]]
}

# ---------- fail-closed tooling paths ----------

@test "findings bin missing fails CLOSED (cannot verify convergence)" {
	_install_gh_shim
	_reviews_stale_cr
	export APPROVAL_GATE_FINDINGS_BIN="$TEST_TMP/nonexistent.sh"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"cannot verify convergence"* ]]
}

@test "reviews query failure fails CLOSED" {
	_install_gh_shim
	export FAKE_REVIEWS_FILE="$TEST_TMP/nonexistent.json"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"reviews query failed"* ]]
}

@test "rc-0 garbage reviews payload fails CLOSED as unparseable" {
	_install_gh_shim
	printf 'not json at all' >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"unparseable"* ]]
}

# ---------- audited skip ----------

@test "APPROVAL_GATE_SKIP with a writable audit log passes and writes the row" {
	_install_gh_shim
	_reviews_stale_cr
	export SKIP_LOG="$TEST_TMP/skips.jsonl" PIPELINE_GATE_SKIP_REASON="bats skip-success fixture"
	APPROVAL_GATE_SKIP=1 _run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"SKIPPED via APPROVAL_GATE_SKIP=1"* ]] || return 1
	grep -q "approval-gate" "$TEST_TMP/skips.jsonl"
	[ ! -f "$GH_ARGS_LOG" ]
}

@test "APPROVAL_GATE_SKIP with an unwritable audit fails CLOSED" {
	_install_gh_shim
	_reviews_stale_cr
	export SKIP_LOG="$TEST_TMP" # a directory — append must fail
	APPROVAL_GATE_SKIP=1 _run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"could not be audit-logged"* ]]
}

# ---------- run.sh wiring ----------

@test "run.sh wiring: gate refusal blocks the merge for the RIGHT reason" {
	_install_runsh_gh_shim
	_reviews_stale_cr
	_write_findings 1
	run "$RUNSH" --pr 99 --yes
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]] || return 1
	[[ $output == *"approval gate refused"* ]] || return 1
	grep -q "/pulls/99/reviews" "$GH_ARGS_LOG"
	run ! grep -q "pr merge" "$GH_ARGS_LOG"
}

@test "run.sh wiring: --auto path runs the gate before arming" {
	_install_runsh_gh_shim
	_reviews_stale_cr
	_write_findings 1
	run "$RUNSH" --pr 99 --auto --yes
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]] || return 1
	[[ $output == *"not arming auto-merge"* ]] || return 1
	run ! grep -q "pr merge" "$GH_ARGS_LOG"
}

@test "run.sh wiring: passing gate reaches the merge, pinned to the verified head" {
	_install_runsh_gh_shim
	_reviews_approved_at_head
	# Sandbox repo as cwd: run.sh's post-merge steps (fetch/checkout/pull)
	# must not touch the real working tree.
	git init -q -b main "$TEST_TMP/sandbox"
	cd "$TEST_TMP/sandbox"
	git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
	git remote add origin "$TEST_TMP/sandbox"
	git fetch -q origin
	git branch -q --set-upstream-to=origin/main main
	run "$RUNSH" --pr 99 --yes
	[ "$status" -eq 0 ]
	[[ $output == *"MERGE-FIRED"* ]] || return 1
	grep -q "pr merge 99 --squash --match-head-commit $HEAD_SHA --delete-branch" "$GH_ARGS_LOG"
}

@test "run.sh: degenerate headRefOid (null) is named as a wrapper data bug, not a policy refusal" {
	_install_runsh_gh_shim
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":null,"checks":[]}'
	run "$RUNSH" --pr 99 --yes
	[ "$status" -eq 2 ]
	[[ $output == *"gh payload drift"* ]] || return 1
	[[ $output != *"approval gate refused"* ]]
}

# ---------- round-2 hardening pins ----------

@test "proxy-shaped 404 prose does NOT disable the gate (fail-closed, r2 critical)" {
	_install_gh_shim
	unset APPROVAL_GATE_POLICY
	export FAKE_CONTENTS_MODE=proxy404
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"policy fetch"*"failed"* ]] || return 1
	[[ $output != *"DISABLED"* ]]
}

@test "STRUCTURAL leg: a review record at head carrying the rate-limit notice is NOT a witness" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:30:00Z","body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\n> ## Review limit reached"}]'
	_comments_without_witness
	_write_findings 0
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"not verifiably reviewed"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "DISMISSED displaces an earlier APPROVED at head (decisive-state ordering)" {
	_install_gh_shim
	_reviews '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"DISMISSED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":""}]'
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]]
}

@test "a null comment body does not error the witness; a later valid witness still counts" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	_write_policy 5
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":null},{"user":{"login":"coderabbitai[bot]"},"body":"Reviewing files between oldold1111 and %s."}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
	_reviews_after_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	[ -f "$NUDGE_MARKER" ]
}

@test "copilot-only policy without nudge_comment refuses BEFORE posting anything" {
	_install_gh_shim
	cat >"$APPROVAL_GATE_POLICY" <<EOF
require_approving_review: true
approvers:
  - copilot-pull-request-reviewer[bot]
nudge_timeout_seconds: 1
EOF
	_reviews '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"COMMENTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T15:30:00Z","body":"looked at it"}]'
	_comments_without_witness
	_write_findings 0
	_run_gate
	[ "$status" -eq 2 ]
	# The gate's message gained the word "usable" at some point ("no usable
	# nudge_comment"), which broke this substring. Nothing noticed, because a
	# mid-test `[[ ]]` cannot fail on bash 3.2. Assert the current wording,
	# and assert the REFUSAL itself so a future reword breaks only one line.
	assert_output_contains "REFUSING"
	assert_output_contains "nudge_comment"
	[ ! -f "$NUDGE_MARKER" ]
}

@test "nudge-post failure refuses instead of polling" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_with_head_witness
	_write_findings 0
	export FAKE_COMMENT_FAIL=1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"failed to post nudge comment"* ]]
}

@test "comments-query failure is a distinct fail-closed refusal, no NOWHERE claim" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	export FAKE_COMMENTS_FILE="$TEST_TMP/nonexistent-comments.json"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"witness query failed"* ]] || return 1
	[[ $output == *"No nudge was posted"* ]] || return 1
	[[ $output != *"not verifiably reviewed"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "CRLF policy file is accepted (consumer core.autocrlf)" {
	_install_gh_shim
	printf 'require_approving_review: true\r\napprovers:\r\n  - coderabbitai[bot]\r\nnudge_timeout_seconds: 1\r\n' >"$APPROVAL_GATE_POLICY"
	_reviews_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
}

@test "run.sh: immediate-merge failure is framed as the designed TOCTOU refusal, rc 2" {
	_install_runsh_gh_shim
	_reviews_approved_at_head
	export FAKE_MERGE_FAIL=1
	run "$RUNSH" --pr 99 --yes
	[ "$status" -eq 2 ]
	[[ $output == *"re-run this skill to re-gate"* ]] || return 1
	[[ $output != *"✓ Merged"* ]]
}

@test "run.sh: e2e marker cleanup — pinned-head marker removed, other markers survive" {
	_install_runsh_gh_shim
	_reviews_approved_at_head
	git init -q -b main "$TEST_TMP/sandbox"
	cd "$TEST_TMP/sandbox"
	git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
	git remote add origin "$TEST_TMP/sandbox"
	git fetch -q origin
	git branch -q --set-upstream-to=origin/main main
	mkdir -p .claude/.session-state/ship-cycle
	touch ".claude/.session-state/ship-cycle/$HEAD_SHA.phase1-directive.txt"
	touch ".claude/.session-state/ship-cycle/beadbead000011112222333344445555666bead0.phase1-directive.txt"
	run "$RUNSH" --pr 99 --yes
	[ "$status" -eq 0 ]
	[[ $output == *"cleaned phase1-directive marker for $HEAD_SHA"* ]] || return 1
	[ ! -f ".claude/.session-state/ship-cycle/$HEAD_SHA.phase1-directive.txt" ]
	[ -f ".claude/.session-state/ship-cycle/beadbead000011112222333344445555666bead0.phase1-directive.txt" ]
}

@test "bundled findings helper resolves via SCRIPT_DIR when the seam is unset" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_without_witness
	unset APPROVAL_GATE_FINDINGS_BIN
	# The REAL hooks/_pr-cr-findings.sh runs, hermetic via its own
	# CR_TEST_MODE fixtures (empty defaults = all four buckets clean).
	export CR_TEST_MODE=1 CR_TEST_HEAD="$HEAD_SHA"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output != *"not executable"* ]] || return 1
	[[ $output == *"not verifiably reviewed"* ]]
}

@test "policy decode path: CRLF policy survives the real content extraction + decode" {
	_install_gh_shim
	unset APPROVAL_GATE_POLICY
	printf 'require_approving_review: true\r\napprovers:\r\n  - coderabbitai[bot]\r\nnudge_timeout_seconds: 1\r\n' >"$TEST_TMP/remote-policy.yml"
	export FAKE_REMOTE_POLICY_FILE="$TEST_TMP/remote-policy.yml" FAKE_CONTENTS_MODE=ok
	_reviews_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	grep -q "contents-query" "$GH_ARGS_LOG"
}

@test "#2571: the REAL policy accepts the claude-review backup approver (github-actions[bot]) at head" {
	_install_gh_shim
	export APPROVAL_GATE_POLICY="$REPO_ROOT/.github/approval-policy.yml"
	_reviews '[{"user":{"login":"github-actions[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-24T16:00:00Z","body":"backup review clean"}]'
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"APPROVED bot review at final head"* ]]
}

@test "#2571 negative: github-actions[bot] APPROVED on a STALE commit does not cover the head" {
	_install_gh_shim
	export APPROVAL_GATE_POLICY="$REPO_ROOT/.github/approval-policy.yml"
	_reviews '[{"user":{"login":"github-actions[bot]"},"state":"APPROVED","commit_id":"oldold1111","submitted_at":"2026-08-24T16:00:00Z","body":"stale backup review"}]'
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT verified clean"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "LIVE SHAPE (#2600): a delimited rate-limit BLOCK inside the summary does not destroy the witness around it" {
	# CR edits its summary in place; a past rate-limit episode leaves a
	# start/end-delimited block INSIDE the body whose walkthrough carries
	# the genuine reviewed range. Whole-body exclusion refused a fully
	# reviewed head (the gate's first production refusal) — the strip is
	# block-scoped now.
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	_write_policy 5
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n> Review limit reached\\n<!-- end of auto-generated comment: rate limited by coderabbit.ai -->\\n<!-- walkthrough_start -->\\nReviewing files that changed between oldold1111 and %s.\\n"}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
	_reviews_after_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	grep -q "pr comment" "$GH_ARGS_LOG"
}

@test "a body that is ONLY a delimited rate-limit block (nothing else) is still not a witness" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\n> Review limit reached - next window pending for %s\\n<!-- end of auto-generated comment: rate limited by coderabbit.ai -->\\n"}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"not verifiably reviewed"* ]] || return 1
	[ ! -f "$NUDGE_MARKER" ]
}

@test "MALFORMED delimiters: end-before-start with the sha after the unmatched start is NOT a witness (CI r2)" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- end of auto-generated comment: rate limited by coderabbit.ai -->\\nnoise\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\nsha smuggled: %s"}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
	_run_gate
	[ "$status" -eq 2 ]
	[ ! -f "$NUDGE_MARKER" ]
}

@test "MALFORMED delimiters: a trailing unmatched start after a valid block is NOT a witness (CI r2)" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 0
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\nblock\\n<!-- end of auto-generated comment: rate limited by coderabbit.ai -->\\n<!-- This is an auto-generated comment: rate limited by coderabbit.ai -->\\nsha smuggled: %s"}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
	_run_gate
	[ "$status" -eq 2 ]
	[ ! -f "$NUDGE_MARKER" ]
}

# ---------- a standing CHANGES_REQUESTED from ANOTHER approver ----------

@test "a SECOND approver's standing CHANGES_REQUESTED refuses, despite an APPROVED at head" {
	# The exact shape of PR #2638, where this gate printed "✓ APPROVED" and
	# `gh pr merge` then refused with "the base branch policy prohibits the
	# merge". The predicate asked "did ANY approver approve at head", which
	# is not what GitHub asks: a standing CHANGES_REQUESTED from ANY
	# approver blocks, and one approver's APPROVED does not override
	# another's request.
	#
	# Reporting green on a PR that cannot merge is the worst failure a merge
	# gate has — it sends the operator to debug `gh` when the answer was in
	# the review list all along.
	_install_gh_shim
	_reviews '[
		{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T14:55:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:33:00Z","body":""}
	]'
	_run_gate
	[ "$status" -ne 0 ]
	assert_output_contains "STANDING CHANGES_REQUESTED"
	assert_output_contains "coderabbitai[bot]"
	# It must name the COMMIT, so the operator can tell a stale request from
	# a current one without another query.
	assert_output_contains "b6ca909a"
	# And it must NOT have claimed approval first.
	assert_output_lacks "✓ APPROVED bot review"
}

@test "a later COMMENTED review does not clear a standing CHANGES_REQUESTED" {
	# CodeRabbit posts a COMMENTED record for every thread-reply batch. Those
	# are correctly ignored when looking for an approval — but they must not
	# be mistaken for the request being withdrawn either. GitHub keeps it in
	# force until the SAME reviewer approves or it is dismissed.
	_install_gh_shim
	_reviews '[
		{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T14:55:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:33:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"COMMENTED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T15:01:00Z","body":"reply batch"}
	]'
	_run_gate
	[ "$status" -ne 0 ]
	assert_output_contains "STANDING CHANGES_REQUESTED"
}

@test "the refusal points at the PROCESS fix, not at dismissing the review" {
	# The tempting unblock is `gh api ... /dismissals`, which is a bypass:
	# it clears the signal without clearing the cause. CodeRabbit runs with
	# request_changes_workflow: true, so it withdraws its own request by
	# posting APPROVED on a clean re-review. The refusal has to say that,
	# because a gate that refuses without naming the remedy gets bypassed.
	_install_gh_shim
	_reviews '[
		{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T14:55:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:33:00Z","body":""}
	]'
	_run_gate
	[ "$status" -ne 0 ]
	assert_output_contains "request_changes_workflow"
	assert_output_contains "thread-reply.sh"
	# And it must warn that the thread count is a DIFFERENT signal — reading
	# zero there is what made this look mergeable.
	assert_output_contains "THREADS"
}

@test "a DISMISSED review is not treated as standing" {
	# Dismissal is the other legitimate way the request goes away. Once
	# dismissed it must not keep refusing, or the gate would be unpassable
	# after a human has resolved it out-of-band.
	_install_gh_shim
	_reviews '[
		{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T14:55:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:33:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"DISMISSED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:40:00Z","body":""}
	]'
	_run_gate
	[ "$status" -eq 0 ]
	assert_output_contains "APPROVED bot review at final head"
}

@test "the approver's OWN later APPROVED clears its earlier request" {
	# The process path: CR re-reviews at the new head, finds nothing, and
	# posts APPROVED. That is what should unblock a real PR, and the gate
	# must recognise it without any dismissal.
	_install_gh_shim
	_reviews '[
		{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:33:00Z","body":""},
		{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T15:20:00Z","body":""}
	]'
	_run_gate
	[ "$status" -eq 0 ]
	assert_output_contains "APPROVED bot review at final head"
}

@test "a NON-approver's CHANGES_REQUESTED does not refuse" {
	# The policy names which reviewers are decisive. A drive-by request from
	# somebody outside that list is not what GitHub gates on here, and
	# refusing on it would make the gate stricter than the branch rule —
	# unpassable for a reason the operator cannot act on through this skill.
	_install_gh_shim
	_reviews '[
		{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"'"$HEAD_SHA"'","submitted_at":"2026-08-28T15:20:00Z","body":""},
		{"user":{"login":"some-human"},"state":"CHANGES_REQUESTED","commit_id":"b6ca909a","submitted_at":"2026-08-28T14:33:00Z","body":""}
	]'
	_run_gate
	[ "$status" -eq 0 ]
	assert_output_contains "APPROVED bot review at final head"
}
