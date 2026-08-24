#!/usr/bin/env bats
# covers: skills/github-pr-merge/_approval-gate.sh
# covers: skills/github-pr-merge/run.sh
# shellcheck disable=SC2030,SC2031  # bats runs each @test in a subshell
# #2567 approving-review merge gate. The refuse branches are the security
# value: the gate must never nudge `@coderabbitai approve` onto a head
# that has findings or that CR has not verifiably reviewed (that would
# LAUNDER the exact state the gate exists to block), and the audited
# skip must fail closed when the audit row cannot be written.

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

# Policy fixture. $1 = nudge_timeout_seconds.
_write_policy() {
	cat >"$TEST_TMP/approval-policy.yml" <<EOF
require_approving_review: true
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

# gh shim: dispatches on subcommand. Reviews payload comes from
# FAKE_REVIEWS_FILE; after a nudge (`pr comment`) is posted, subsequent
# reviews calls serve FAKE_REVIEWS_AFTER_FILE when set (the record
# "landing"). Issue comments come from FAKE_COMMENTS_FILE.
_install_gh_shim() {
	mkdir -p "$TEST_TMP/bin"
	cat >"$TEST_TMP/bin/gh" <<'SHIM'
#!/bin/bash
log() { printf '%s\n' "$*" >>"$GH_ARGS_LOG"; }
case "$1 $2" in
"pr comment")
	log "$@"
	touch "$NUDGE_MARKER"
	exit 0
	;;
"api repos"*) : ;; # fall through below on full-arg match
esac
case "$*" in
*"/pulls/"*"/reviews"*)
	log "reviews-query"
	if [ -f "$NUDGE_MARKER" ] && [ -n "${FAKE_REVIEWS_AFTER_FILE:-}" ]; then
		src="$FAKE_REVIEWS_AFTER_FILE"
	else
		src="$FAKE_REVIEWS_FILE"
	fi
	# The gate calls this bare (JSON out) and once with --jq (witness
	# bodies). Implement --jq with the real jq against the fixture.
	for a in "$@"; do
		case "$prev" in --jq) exec jq -r "$a" "$src" ;; esac
		prev="$a"
	done
	exec cat "$src"
	;;
*"/issues/"*"/comments"*)
	for a in "$@"; do
		case "$prev" in --jq) exec jq -r "$a" "${FAKE_COMMENTS_FILE:-/dev/null}" ;; esac
		prev="$a"
	done
	exec cat "${FAKE_COMMENTS_FILE:-/dev/null}"
	;;
*)
	log "UNEXPECTED gh: $*"
	exit 1
	;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
	export NUDGE_MARKER="$TEST_TMP/nudge-posted"
}

# Reviews fixtures. Logins/fields mirror the real reviews API.
_reviews_approved_at_head() {
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:00:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
}

_reviews_stale_cr() { # CHANGES_REQUESTED on an older commit, nothing at head
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"oldold1111","submitted_at":"2026-08-24T15:00:00Z","body":""}]' >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
}

_comments_with_head_witness() {
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"Reviewing files that changed between oldold1111 and %s."}]' "$HEAD_SHA" >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
}

_comments_without_witness() {
	printf '[{"user":{"login":"coderabbitai[bot]"},"body":"Reviewing files between oldold1111 and beefbeef2222."}]' >"$TEST_TMP/comments.json"
	export FAKE_COMMENTS_FILE="$TEST_TMP/comments.json"
}

_run_gate() {
	run "$GATE" --pr 99 --head "$HEAD_SHA" --owner-name testowner/testrepo
}

@test "no policy file: gate disabled loudly, rc 0, no gh calls" {
	_install_gh_shim
	rm -f "$APPROVAL_GATE_POLICY"
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"DISABLED"* ]]
	[ ! -f "$GH_ARGS_LOG" ]
}

@test "require_approving_review: false disables the gate" {
	_install_gh_shim
	sed -i '' 's/^require_approving_review: true/require_approving_review: false/' "$APPROVAL_GATE_POLICY"
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"gate disabled"* ]]
}

@test "present-but-broken policy fails CLOSED (garbage require value)" {
	_install_gh_shim
	sed -i '' 's/^require_approving_review: true/require_approving_review: yes-ish/' "$APPROVAL_GATE_POLICY"
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

@test "APPROVED at head passes with NO nudge posted" {
	_install_gh_shim
	_reviews_approved_at_head
	_run_gate
	[ "$status" -eq 0 ]
	[[ $output == *"APPROVED bot review at final head"* ]]
	run ! grep -q "pr comment" "$GH_ARGS_LOG"
}

@test "copilot APPROVED at head passes too (second policy login)" {
	_install_gh_shim
	printf '[{"user":{"login":"copilot-pull-request-reviewer[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:00:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
	_run_gate
	[ "$status" -eq 0 ]
}

@test "human APPROVED at head does NOT satisfy the bot policy" {
	_install_gh_shim
	printf '[{"user":{"login":"somehuman"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:00:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
}

@test "latest-per-bot ordering: APPROVED superseded by CHANGES_REQUESTED does not pass" {
	_install_gh_shim
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T15:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"%s","submitted_at":"2026-08-24T16:00:00Z","body":""}]' "$HEAD_SHA" "$HEAD_SHA" >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
}

@test "stale APPROVED on a non-head commit does not cover the head" {
	_install_gh_shim
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"oldold1111","submitted_at":"2026-08-24T15:00:00Z","body":""}]' >"$TEST_TMP/reviews.json"
	export FAKE_REVIEWS_FILE="$TEST_TMP/reviews.json"
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
}

@test "LAUNDERING GUARD: findings present -> refuse, nudge NEVER posted" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_with_head_witness
	_write_findings 1
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOT clean"* ]]
	[ ! -f "$NUDGE_MARKER" ]
}

@test "LAUNDERING GUARD: head unreviewed (no witness) -> refuse, nudge NEVER posted" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_without_witness
	_write_findings 0
	_run_gate
	[ "$status" -eq 2 ]
	[[ $output == *"NOWHERE"* ]]
	[ ! -f "$NUDGE_MARKER" ]
}

@test "converged-but-unrecorded: nudge posted, record lands, gate passes" {
	_install_gh_shim
	_reviews_stale_cr
	_comments_with_head_witness
	_write_findings 0
	_write_policy 5
	printf '[{"user":{"login":"coderabbitai[bot]"},"state":"CHANGES_REQUESTED","commit_id":"oldold1111","submitted_at":"2026-08-24T15:00:00Z","body":""},{"user":{"login":"coderabbitai[bot]"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-24T16:31:00Z","body":""}]' "$HEAD_SHA" >"$TEST_TMP/reviews-after.json"
	export FAKE_REVIEWS_AFTER_FILE="$TEST_TMP/reviews-after.json"
	_run_gate
	[ "$status" -eq 0 ]
	grep -q "pr comment 99 --body @coderabbitai approve" "$GH_ARGS_LOG"
	[[ $output == *"APPROVED record landed"* ]]
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
	[[ $output == *"reviews query failed"* ]] || [[ $output == *"unparseable"* ]]
}

@test "APPROVAL_GATE_SKIP without a writable audit fails CLOSED" {
	_install_gh_shim
	_reviews_stale_cr
	# Force pipeline_skip_log to fail: point the gate at a REPO_ROOT-like
	# tree without the lib by running from a bare temp git repo.
	mkdir -p "$TEST_TMP/bare" && cd "$TEST_TMP/bare" && git init -q .
	cp "$GATE" gate.sh && mkdir -p .github && cp "$APPROVAL_GATE_POLICY" .github/approval-policy.yml
	unset APPROVAL_GATE_POLICY
	APPROVAL_GATE_SKIP=1 run ./gate.sh --pr 99 --head "$HEAD_SHA" --owner-name o/r
	[ "$status" -eq 2 ]
	[[ $output == *"could not be audit-logged"* ]]
}

@test "run.sh wiring: gate refusal blocks the merge (no gh pr merge fired)" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 1
	# Full-state shim additions for run.sh's own queries.
	cat >"$TEST_TMP/bin/gh" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >>"$GH_ARGS_LOG"
case "\$*" in
*statusCheckRollup*) printf '%s\n' "\$FAKE_STATE" ;;
*"/pulls/"*"/reviews"*) cat "$TEST_TMP/reviews.json" ;;
*graphql*) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' ;;
"pr merge"*) echo "MERGE-FIRED" ;;
*) echo "{}" ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$HEAD_SHA"'","checks":[]}'
	SKC_ASSUME_YES=1 run "$RUNSH" --pr 99
	[ "$status" -eq 2 ]
	[[ $output == *"approval gate refused"* ]]
	run ! grep -q "pr merge" "$GH_ARGS_LOG"
}

@test "run.sh wiring: --auto path also runs the gate before arming" {
	_install_gh_shim
	_reviews_stale_cr
	_write_findings 1
	cat >"$TEST_TMP/bin/gh" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >>"$GH_ARGS_LOG"
case "\$*" in
*statusCheckRollup*) printf '%s\n' "\$FAKE_STATE" ;;
*"/pulls/"*"/reviews"*) cat "$TEST_TMP/reviews.json" ;;
"pr merge"*) echo "MERGE-FIRED" ;;
*) echo "{}" ;;
esac
SHIM
	chmod +x "$TEST_TMP/bin/gh"
	export FAKE_STATE='{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","head":"'"$HEAD_SHA"'","checks":[]}'
	SKC_ASSUME_YES=1 run "$RUNSH" --pr 99 --auto
	[ "$status" -eq 2 ]
	[[ $output == *"not arming auto-merge"* ]]
	run ! grep -q "pr merge" "$GH_ARGS_LOG"
}
