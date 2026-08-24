#!/bin/bash
set -euo pipefail
# v0.34.160 (#2567): approving-review merge gate.
#
# Refuses the merge unless a policy-listed bot (CodeRabbit / Copilot) has
# an APPROVED review record ON the final HEAD. CodeRabbit's record
# behavior is inconsistent (evidence in .github/approval-policy.yml): it
# sometimes converges — zero unresolved threads, final HEAD reviewed
# clean — without ever posting the APPROVED record, or leaves a stale
# CHANGES_REQUESTED standing. When convergence is VERIFIED, this gate
# posts the policy nudge (`@coderabbitai approve`) and waits for the
# real record; the weirdness becomes a nudge, not a bypass. When
# convergence is NOT verified, it refuses WITHOUT nudging — commanding
# an approval onto an unreviewed or findings-bearing head would launder
# the exact state the gate exists to block.
#
# The policy is read from the repo's DEFAULT BRANCH via the GitHub
# contents API — NOT the working tree, and deliberately not a PR's
# base ref (a release-branch PR still answers to the default branch's
# policy). A PR branch must not be able to neuter its own merge gate by
# editing the policy file on that branch (Phase 1 security finding,
# 2026-08-24).
#
# Usage: _approval-gate.sh --pr <num> --head <sha40> --owner-name <owner/name>
#
# Exit codes:
#   0 — gate satisfied (APPROVED record at head, possibly after nudge),
#       or gate disabled by policy (no policy on the default branch /
#       require:false), or audited APPROVAL_GATE_SKIP.
#   2 — refused: no record and not verifiably converged; nudge timed out;
#       policy/tooling/query unusable (fail-closed).
#
# Test seams (bats only — production callers set none of these):
# APPROVAL_GATE_POLICY (local policy file, bypasses the default-branch
# read), APPROVAL_GATE_FINDINGS_BIN (convergence checker), and
# APPROVAL_GATE_POLL_SECONDS (nudge poll interval, default 10).

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Repo root for helper/lib resolution only — the POLICY deliberately does
# not come from here (see header). Fallback: plugin root is two levels up
# from skills/github-pr-merge/ (consumer: .claude/skills/<name>/ → .claude/).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../.." && pwd; })

usage() {
	echo "Usage: $0 --pr <num> --head <40-hex sha> --owner-name <owner/name>" >&2
	exit 2
}

PR=""
HEAD_SHA=""
OWNER_NAME=""
while [ $# -gt 0 ]; do
	case "$1" in
	--pr)
		[ $# -ge 2 ] || usage
		PR="$2"
		shift 2
		;;
	--head)
		[ $# -ge 2 ] || usage
		HEAD_SHA="$2"
		shift 2
		;;
	--owner-name)
		[ $# -ge 2 ] || usage
		OWNER_NAME="$2"
		shift 2
		;;
	*)
		echo "approval-gate: unknown arg: $1" >&2
		usage
		;;
	esac
done
# HEAD_SHA must be a full 40-hex sha: it is compared against commit_id
# and grepped as a witness needle — a short/degenerate value ("null"
# from a failed jq upstream) would false-match inside prose. The refusal
# echoes the received values so a caller's data bug (jq null, empty
# slug) is diagnosable and not misread as a policy refusal.
if [ -z "$PR" ] || ! [[ $PR =~ ^[0-9]+$ ]] || ! [[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || [ -z "$OWNER_NAME" ] || [[ $OWNER_NAME != */* ]]; then
	echo "approval-gate: bad args — got --pr '$PR' --head '$HEAD_SHA' --owner-name '$OWNER_NAME'" >&2
	usage
fi

# Scratch dir for query payloads/stderr (payloads and diagnostics are
# kept SEPARATE — merging stderr into a payload corrupts the parse).
AG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/approval-gate.XXXXXX") || {
	echo "approval-gate: ERROR — mktemp failed; refusing (fail-closed)" >&2
	exit 2
}
trap 'rm -rf "$AG_TMP"' EXIT

# ---- Policy acquisition (default branch, not working tree) -----------
POLICY="${APPROVAL_GATE_POLICY:-}"
if [ -z "$POLICY" ]; then
	if ! default_branch=$(gh api "repos/$OWNER_NAME" --jq '.default_branch' 2>"$AG_TMP/err"); then
		echo "approval-gate: ERROR — cannot resolve default branch for $OWNER_NAME: $(cat "$AG_TMP/err")" >&2
		echo "  Refusing (fail-closed) — the policy must be read from the default branch." >&2
		exit 2
	fi
	if content=$(gh api "repos/$OWNER_NAME/contents/.github/approval-policy.yml?ref=$default_branch" --jq '.content' 2>"$AG_TMP/err"); then
		if ! printf '%s' "$content" | base64 --decode >"$AG_TMP/policy.yml" 2>"$AG_TMP/err"; then
			echo "approval-gate: ERROR — policy content on $default_branch is not decodable ($(cat "$AG_TMP/err")); refusing (fail-closed)" >&2
			exit 2
		fi
		POLICY="$AG_TMP/policy.yml"
	elif grep -qF "Not Found (HTTP 404)" "$AG_TMP/err"; then
		# gh's CANONICAL missing-resource string, matched exactly: this is
		# the gate's only fail-open branch, and a loose "not found" prose
		# match was proxy-spoofable (r2 critical — an intermediary's "404
		# page not found" body would silently disable the gate). The
		# ref-miss shape ("No commit found for the ref …") stays fail-
		# closed, as does every other error text.
		echo "approval-gate: ⚠ no .github/approval-policy.yml on $OWNER_NAME@$default_branch — approving-review gate DISABLED (adopt via #2567)" >&2
		exit 0
	else
		echo "approval-gate: ERROR — policy fetch from $default_branch failed: $(cat "$AG_TMP/err")" >&2
		echo "  Refusing (fail-closed) — cannot distinguish 'not adopted' from an outage." >&2
		exit 2
	fi
elif [ ! -f "$POLICY" ]; then
	# Test-seam path pointing nowhere = the not-adopted shape, kept loud.
	echo "approval-gate: ⚠ no policy file at $POLICY — approving-review gate DISABLED (adopt via #2567)" >&2
	exit 0
fi

# ---- Policy parse (single-pass awk per key: first match wins, no
# SIGPIPE, duplicates ignored deliberately; contract in the policy
# header). CRLF policies are accepted (trailing \r stripped — a consumer
# repo with core.autocrlf would otherwise fail-close on an invisible
# character). Fail CLOSED on an unparseable adopted policy. ------------
_policy_scalar() {
	awk -v k="$1" 'index($0, k ":") == 1 { sub("^" k ":[ \t]*", ""); sub(/\r$/, ""); print; exit }' "$POLICY"
}

require=$(_policy_scalar require_approving_review)
case "$require" in
false)
	echo "approval-gate: policy sets require_approving_review: false — gate disabled"
	exit 0
	;;
true) ;;
*)
	echo "approval-gate: ERROR — require_approving_review is '$require' (want true|false) in the default-branch policy; refusing (fail-closed)" >&2
	exit 2
	;;
esac

# approvers block: `  - login` lines; blank and full-line-comment lines
# INSIDE the block are skipped (not list-terminating); anything else
# ends the block.
APPROVERS=$(awk '
	/^approvers:/ { grab = 1; next }
	grab && /^  - / { sub(/^  - /, ""); sub(/\r$/, ""); print; next }
	grab && (/^[ \t]*#/ || /^[ \t\r]*$/) { next }
	grab { exit }' "$POLICY")
if [ -z "$APPROVERS" ]; then
	echo "approval-gate: ERROR — no approvers parsed from the default-branch policy; refusing (fail-closed)" >&2
	exit 2
fi
NUDGE_COMMENT=$(_policy_scalar nudge_comment | sed 's/^"\(.*\)"$/\1/')
if [ -z "$NUDGE_COMMENT" ]; then
	# The built-in default addresses CodeRabbit, so it is only meaningful
	# when coderabbitai[bot] is a policy approver. For a policy without it
	# (e.g. copilot-only), leave NUDGE_COMMENT empty: the APPROVED fast
	# path still works, and the NUDGE site refuses-before-posting instead
	# of leaving a no-op public comment and timing out (r2 finding).
	if grep -qxF "coderabbitai[bot]" <<<"$APPROVERS"; then
		NUDGE_COMMENT="@coderabbitai approve"
		echo "approval-gate: NOTE — nudge_comment absent from policy; using built-in default '$NUDGE_COMMENT'"
	fi
fi
NUDGE_TIMEOUT=$(_policy_scalar nudge_timeout_seconds)
[ -n "$NUDGE_TIMEOUT" ] || NUDGE_TIMEOUT=180
if ! [[ $NUDGE_TIMEOUT =~ ^[0-9]+$ ]]; then
	echo "approval-gate: ERROR — nudge_timeout_seconds is '$NUDGE_TIMEOUT' (want integer) in the default-branch policy; refusing (fail-closed)" >&2
	exit 2
fi
POLL="${APPROVAL_GATE_POLL_SECONDS:-10}"
# A non-positive poll interval + nonzero timeout would spin forever
# (waited never advances). Positive integer or fail closed.
if ! [[ $POLL =~ ^[0-9]+$ ]] || [ "$POLL" -lt 1 ]; then
	echo "approval-gate: ERROR — poll interval '$POLL' (want positive integer); refusing (fail-closed)" >&2
	exit 2
fi

# ---- Audited escape — fail-closed like the phase2 round-cap override
# (NOT like the pre-push gate, which warns and proceeds): the skip
# spends ONLY after the audit row is durably written. -----------------
if [ "${APPROVAL_GATE_SKIP:-0}" = "1" ]; then
	_ag_skip_lib="$SCRIPT_DIR/../../_lib/pipeline-skip.sh"
	_ag_logged=0
	# shellcheck source=../../_lib/pipeline-skip.sh
	if [ -f "$_ag_skip_lib" ] && source "$_ag_skip_lib" 2>"$AG_TMP/err" &&
		command -v pipeline_skip_log >/dev/null 2>&1 && pipeline_skip_log "approval-gate"; then
		_ag_logged=1
	fi
	if [ "$_ag_logged" != "1" ]; then
		echo "approval-gate: ERROR — APPROVAL_GATE_SKIP=1 but the skip could not be audit-logged (lib: $_ag_skip_lib); refusing (fail-closed)" >&2
		if [ -s "$AG_TMP/err" ]; then
			echo "  lib source stderr: $(cat "$AG_TMP/err")" >&2
		fi
		exit 2
	fi
	echo "approval-gate: ⚠ SKIPPED via APPROVAL_GATE_SKIP=1 (audit-logged) — merging WITHOUT an approving bot review" >&2
	exit 0
fi

# jq array of approver logins, for exact user.login matching.
APPROVERS_JSON=$(printf '%s\n' "$APPROVERS" | jq -R . | jq -cs .)

# Fetches the reviews payload into $AG_TMP/reviews.json (shared with the
# witness — one round-trip per attempt) and answers: does any policy
# approver's LATEST decisive review read APPROVED at the final head?
# "Decisive" = APPROVED/CHANGES_REQUESTED/DISMISSED — COMMENTED is
# ignored, matching GitHub's own review-decision semantics (CodeRabbit
# posts COMMENTED records for every thread-reply batch; those must not
# displace a genuine approval). Latest-per-reviewer is the axis: an
# APPROVED superseded by a later CHANGES_REQUESTED must not pass, and a
# stale APPROVED on an earlier commit must not cover a new head.
# jq -s + add normalizes BOTH payload shapes gh emits (one array for a
# single page — the common case; concatenated arrays across --paginate
# pages — gh only merges them under --slurp).
_approved_at_head() {
	local rc=0
	gh api "repos/$OWNER_NAME/pulls/$PR/reviews" --paginate >"$AG_TMP/reviews.json" 2>"$AG_TMP/err" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "approval-gate: ERROR — reviews query failed (rc=$rc): $(cat "$AG_TMP/err")" >&2
		return 2
	fi
	local ok
	ok=$(jq -rs --argjson bots "$APPROVERS_JSON" --arg head "$HEAD_SHA" '
		add // []
		| [.[] | select(.user.login as $l | $bots | index($l))
			| select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")]
		| group_by(.user.login)
		| map(sort_by(.submitted_at) | last)
		| any(.state == "APPROVED" and .commit_id == $head)' "$AG_TMP/reviews.json" 2>"$AG_TMP/err") || {
		echo "approval-gate: ERROR — reviews payload unparseable: $(cat "$AG_TMP/err")" >&2
		echo "  Payload head: $(head -c 300 "$AG_TMP/reviews.json")" >&2
		return 2
	}
	[ "$ok" = "true" ]
}

_ah_rc=0
_approved_at_head || _ah_rc=$?
if [ "$_ah_rc" -eq 0 ]; then
	echo "approval-gate: ✓ APPROVED bot review at final head $HEAD_SHA"
	exit 0
elif [ "$_ah_rc" -eq 2 ]; then
	exit 2 # query failure — cannot verify, fail closed (reason already printed)
fi

# No record. Nudge ONLY if convergence is verified two ways:
#   (a) zero findings across all four _pr-cr-findings.sh buckets
#       (NOTE: that helper re-resolves the PR's LIVE head itself — a
#       push racing this gate makes (a) evaluate a newer head than the
#       pinned one; the record/witness legs still pin $HEAD_SHA, so the
#       drift is refusal-side only), and
#   (b) a positive review signal for the pinned head — see _head_witness.
# The CodeRabbit CHECK alone is fail-open ("Review rate limited" still
# flips it green), so it is deliberately NOT accepted as the witness.
FINDINGS_BIN="${APPROVAL_GATE_FINDINGS_BIN:-}"
if [ -z "$FINDINGS_BIN" ]; then
	# Plugin-source layout first, consumer layout second. NOTE:
	# hooks/pre-merge-cr-comments-gate.sh resolves the same helper in the
	# REVERSE order (consumer override wins there); here the plugin copy
	# wins because this wrapper ships with the plugin and its contract is
	# pinned to the plugin's helper version.
	for cand in "$REPO_ROOT/hooks/_pr-cr-findings.sh" "$REPO_ROOT/.claude/hooks/_pr-cr-findings.sh"; do
		if [ -x "$cand" ]; then
			FINDINGS_BIN="$cand"
			break
		fi
	done
fi
if [ ! -x "$FINDINGS_BIN" ]; then
	echo "approval-gate: ERROR — no APPROVED bot review at head and _pr-cr-findings.sh not found/executable (looked under $REPO_ROOT); cannot verify convergence, refusing (fail-closed)" >&2
	exit 2
fi

if ! "$FINDINGS_BIN" "$PR"; then
	echo "approval-gate: REFUSING — no APPROVED bot review at final head $HEAD_SHA and CR findings are NOT verified clean (findings present, or the findings query itself failed — see output above)." >&2
	echo "  If findings are listed: address them — do NOT nudge an approval onto a findings-bearing head. If the query failed: re-run." >&2
	exit 2
fi

# CodeRabbit stamps its rate-limit notice with an HTML comment
# CONTAINING this substring — the EXACT needle both witness legs
# exclude on (do not paste the full <!-- --> comment here: contains()
# would then require the whole thing verbatim). The notice quotes the head
# sha while announcing the review did NOT run (Phase 1 critical
# finding): matching it would nudge-approve an unreviewed head, the
# exact laundering the witness exists to prevent. Single point of
# drift: if CodeRabbit rewords the marker, the notice becomes a false
# witness again — keep in sync with their auto-generated comment.
RATE_LIMIT_MARKER="rate limited by coderabbit.ai"

# Positive review signal for the pinned head, two accepted forms — BOTH
# exclude rate-limit bodies (r2: the structural leg initially didn't,
# reopening the r1 critical through the leg that runs first):
#   1. STRUCTURED: a policy-bot review record whose commit_id == head,
#      from the payload _approved_at_head fetched. Any decisive-or-
#      COMMENTED state counts as "reviewed" — including a findings-clean
#      CHANGES_REQUESTED at head, which is exactly the stale-verdict
#      shape the nudge exists to remediate (all four findings buckets
#      already read clean by this point).
#   2. TEXT: the head sha inside a policy-bot comment body.
_head_witness() {
	local pinned
	pinned=$(jq -rs --argjson bots "$APPROVERS_JSON" --arg head "$HEAD_SHA" --arg marker "$RATE_LIMIT_MARKER" '
		add // [] | [.[] | select(.user.login as $l | $bots | index($l))
			| select(.commit_id == $head)
			| select((.body // "") | contains($marker) | not)] | length' \
		"$AG_TMP/reviews.json" 2>"$AG_TMP/err") || {
		echo "approval-gate: ERROR — witness parse of reviews payload failed: $(cat "$AG_TMP/err")" >&2
		return 2
	}
	if ! [[ $pinned =~ ^[0-9]+$ ]]; then
		echo "approval-gate: ERROR — structured-witness count is '$pinned' (jq contract break); refusing (fail-closed)" >&2
		return 2
	fi
	if [ "$pinned" -gt 0 ]; then
		return 0
	fi
	local rc=0
	gh api "repos/$OWNER_NAME/issues/$PR/comments" --paginate >"$AG_TMP/comments.json" 2>"$AG_TMP/err" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "approval-gate: ERROR — comments query failed (rc=$rc): $(cat "$AG_TMP/err")" >&2
		return 2
	fi
	# .body // "" — a null body (deleted/edited-away) must not error the
	# whole parse and permanently block on a "re-run when the API
	# recovers" that will never come (r2); it just contributes nothing.
	jq -rs --argjson bots "$APPROVERS_JSON" --arg marker "$RATE_LIMIT_MARKER" '
		add // [] | .[] | select(.user.login as $l | $bots | index($l))
		| (.body // "") | select(contains($marker) | not)' \
		"$AG_TMP/comments.json" >"$AG_TMP/witness-bodies.txt" 2>"$AG_TMP/err" || {
		echo "approval-gate: ERROR — witness parse of comments payload failed: $(cat "$AG_TMP/err")" >&2
		return 2
	}
	grep -qF "$HEAD_SHA" "$AG_TMP/witness-bodies.txt"
}

_hw_rc=0
_head_witness || _hw_rc=$?
if [ "$_hw_rc" -eq 2 ]; then
	echo "approval-gate: REFUSING — witness query failed; cannot verify the final head was reviewed (fail-closed). No nudge was posted; re-run when the API recovers." >&2
	exit 2
elif [ "$_hw_rc" -ne 0 ]; then
	echo "approval-gate: REFUSING — CR findings are clean but the final head $HEAD_SHA appears in NO policy-bot review record or non-rate-limited comment: the final head is not verifiably reviewed." >&2
	echo "  Wait for CR-in-CI to review the head (its summary shows the reviewed range), then re-run. NOT nudging — '@coderabbitai approve' on an unreviewed head would launder it." >&2
	exit 2
fi

# Empty NUDGE_COMMENT = policy without coderabbitai[bot] and without an
# explicit nudge_comment: nothing meaningful to post — refuse BEFORE the
# public write instead of leaving a no-op comment and timing out.
if [ -z "$NUDGE_COMMENT" ]; then
	echo "approval-gate: REFUSING — converged-but-unrecorded, but the policy has no usable nudge_comment and no EXACT coderabbitai[bot] approver line (the built-in default's target; check for whitespace/padding in the policy). Set nudge_comment in the policy, or wait for an approver record." >&2
	exit 2
fi
echo "approval-gate: converged-but-unrecorded (findings clean + head $HEAD_SHA reviewed) — posting nudge and waiting for the APPROVED record (timeout ${NUDGE_TIMEOUT}s)"
if ! gh pr comment "$PR" -R "$OWNER_NAME" --body "$NUDGE_COMMENT"; then
	echo "approval-gate: ERROR — failed to post nudge comment; refusing" >&2
	exit 2
fi
waited=0
while :; do
	_ah_rc=0
	_approved_at_head || _ah_rc=$?
	if [ "$_ah_rc" -eq 0 ]; then
		echo "approval-gate: ✓ APPROVED record landed at head $HEAD_SHA (after ${waited}s)"
		exit 0
	elif [ "$_ah_rc" -eq 2 ]; then
		echo "approval-gate: REFUSING — mid-poll query failure (fail-closed). NOTE: the nudge WAS already posted; the record may land on its own — re-run to pick it up." >&2
		exit 2
	fi
	if [ "$waited" -ge "$NUDGE_TIMEOUT" ]; then
		echo "approval-gate: REFUSING — nudge posted but no APPROVED record within ${NUDGE_TIMEOUT}s. Check the PR (bot may be rate-limited); re-run when the record lands." >&2
		exit 2
	fi
	sleep "$POLL"
	waited=$((waited + POLL))
done
