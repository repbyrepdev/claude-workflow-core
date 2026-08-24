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
# Usage: _approval-gate.sh --pr <num> --head <sha> --owner-name <owner/name>
#
# Exit codes:
#   0 — gate satisfied (APPROVED record at head, possibly after nudge),
#       or gate disabled by policy (absent file / require:false), or
#       audited APPROVAL_GATE_SKIP.
#   2 — refused: no record and not verifiably converged; nudge timed out;
#       policy/tooling unusable (fail-closed).
#
# Test seams (bats): APPROVAL_GATE_POLICY (policy file path),
# APPROVAL_GATE_FINDINGS_BIN (convergence checker), and
# APPROVAL_GATE_POLL_SECONDS (nudge poll interval, default 10) —
# production callers set none of them.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })

PR=""
HEAD_SHA=""
OWNER_NAME=""
while [ $# -gt 0 ]; do
	case "$1" in
	--pr)
		PR="${2:-}"
		shift 2
		;;
	--head)
		HEAD_SHA="${2:-}"
		shift 2
		;;
	--owner-name)
		OWNER_NAME="${2:-}"
		shift 2
		;;
	*)
		echo "approval-gate: unknown arg: $1" >&2
		exit 2
		;;
	esac
done
if [ -z "$PR" ] || ! [[ $PR =~ ^[0-9]+$ ]] || [ -z "$HEAD_SHA" ] || [ -z "$OWNER_NAME" ] || [[ $OWNER_NAME != */* ]]; then
	echo "Usage: $0 --pr <num> --head <sha> --owner-name <owner/name>" >&2
	exit 2
fi

POLICY="${APPROVAL_GATE_POLICY:-$REPO_ROOT/.github/approval-policy.yml}"

# Policy absent = policy not adopted: gate off, but LOUDLY — a deleted
# policy file must not read as a passing gate without a trace.
if [ ! -f "$POLICY" ]; then
	echo "approval-gate: ⚠ no policy file at $POLICY — approving-review gate DISABLED (adopt via #2567)" >&2
	exit 0
fi

# Strict-format parse (contract documented in the policy file header).
# Fail CLOSED on an unparseable adopted policy: a present-but-broken file
# means someone intended a policy and the gate cannot know what it says.
require=$(sed -n 's/^require_approving_review:[[:space:]]*//p' "$POLICY" | head -1)
case "$require" in
false)
	echo "approval-gate: policy sets require_approving_review: false — gate disabled"
	exit 0
	;;
true) ;;
*)
	echo "approval-gate: ERROR — require_approving_review is '$require' (want true|false) in $POLICY; refusing (fail-closed)" >&2
	exit 2
	;;
esac

# approvers: the two-space-indented `- login` block under the key.
APPROVERS=$(awk '/^approvers:/{grab=1; next} grab && /^  - /{sub(/^  - /,""); print; next} grab{exit}' "$POLICY")
if [ -z "$APPROVERS" ]; then
	echo "approval-gate: ERROR — no approvers parsed from $POLICY; refusing (fail-closed)" >&2
	exit 2
fi
NUDGE_COMMENT=$(sed -n 's/^nudge_comment:[[:space:]]*//p' "$POLICY" | head -1 | sed 's/^"\(.*\)"$/\1/')
NUDGE_TIMEOUT=$(sed -n 's/^nudge_timeout_seconds:[[:space:]]*//p' "$POLICY" | head -1)
[ -n "$NUDGE_COMMENT" ] || NUDGE_COMMENT="@coderabbitai approve"
if ! [[ ${NUDGE_TIMEOUT:-180} =~ ^[0-9]+$ ]]; then
	echo "approval-gate: ERROR — nudge_timeout_seconds is '$NUDGE_TIMEOUT' (want integer) in $POLICY; refusing (fail-closed)" >&2
	exit 2
fi
NUDGE_TIMEOUT="${NUDGE_TIMEOUT:-180}"
POLL="${APPROVAL_GATE_POLL_SECONDS:-10}"
# A non-positive poll interval + nonzero timeout would spin forever
# (waited never advances). Positive integer or fail closed.
if ! [[ $POLL =~ ^[0-9]+$ ]] || [ "$POLL" -lt 1 ]; then
	echo "approval-gate: ERROR — poll interval '$POLL' (want positive integer); refusing (fail-closed)" >&2
	exit 2
fi

# Audited escape — same posture as the other pipeline gates: the skip
# spends ONLY after the audit row is durably written (fail-closed).
if [ "${APPROVAL_GATE_SKIP:-0}" = "1" ]; then
	_ag_skip_lib="$SCRIPT_DIR/../../_lib/pipeline-skip.sh"
	_ag_logged=0
	if [ -f "$_ag_skip_lib" ]; then
		# shellcheck source=../../_lib/pipeline-skip.sh
		if source "$_ag_skip_lib" 2>/dev/null && command -v pipeline_skip_log >/dev/null 2>&1; then
			if pipeline_skip_log "approval-gate"; then
				_ag_logged=1
			fi
		fi
	fi
	if [ "$_ag_logged" != "1" ]; then
		echo "approval-gate: ERROR — APPROVAL_GATE_SKIP=1 but the skip could not be audit-logged (lib: $_ag_skip_lib); refusing (fail-closed)" >&2
		exit 2
	fi
	echo "approval-gate: ⚠ SKIPPED via APPROVAL_GATE_SKIP=1 (audit-logged) — merging WITHOUT an approving bot review" >&2
	exit 0
fi

# jq array of approver logins, for exact user.login matching.
APPROVERS_JSON=$(printf '%s\n' "$APPROVERS" | jq -R . | jq -cs .)

# Does any policy approver's LATEST review read APPROVED at the final
# head? Latest-per-reviewer is the axis (GitHub's own semantics): an
# APPROVED superseded by a later CHANGES_REQUESTED must not pass, and a
# stale APPROVED on an earlier commit must not cover a new head.
_approved_at_head() {
	local reviews rc=0
	reviews=$(gh api "repos/$OWNER_NAME/pulls/$PR/reviews" --paginate 2>&1) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "approval-gate: ERROR — reviews query failed (rc=$rc): $reviews" >&2
		return 2
	fi
	local ok
	ok=$(printf '%s' "$reviews" | jq -r --argjson bots "$APPROVERS_JSON" --arg head "$HEAD_SHA" '
		[.[] | select(.user.login as $l | $bots | index($l))]
		| group_by(.user.login)
		| map(sort_by(.submitted_at) | last)
		| any(.state == "APPROVED" and .commit_id == $head)') || {
		echo "approval-gate: ERROR — reviews payload unparseable" >&2
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
#   (a) zero findings across all four _pr-cr-findings.sh buckets, and
#   (b) the final head sha appears in CodeRabbit's own output (summary
#       "between <sha> and <sha>" edit, or any review record pinned to
#       the head) — the CodeRabbit CHECK alone is fail-open ("Review
#       rate limited" still flips it green), so it is deliberately NOT
#       accepted as the witness.
FINDINGS_BIN="${APPROVAL_GATE_FINDINGS_BIN:-}"
if [ -z "$FINDINGS_BIN" ]; then
	for cand in "$REPO_ROOT/hooks/_pr-cr-findings.sh" "$REPO_ROOT/.claude/hooks/_pr-cr-findings.sh"; do
		if [ -x "$cand" ]; then
			FINDINGS_BIN="$cand"
			break
		fi
	done
fi
if [ -z "$FINDINGS_BIN" ] || [ ! -x "$FINDINGS_BIN" ]; then
	echo "approval-gate: ERROR — no APPROVED bot review at head and _pr-cr-findings.sh not found/executable (looked under $REPO_ROOT); cannot verify convergence, refusing (fail-closed)" >&2
	exit 2
fi

if ! "$FINDINGS_BIN" "$PR"; then
	echo "approval-gate: REFUSING — no APPROVED bot review at final head $HEAD_SHA and CR findings are NOT clean (see counts above)." >&2
	echo "  Address the findings; do NOT nudge an approval onto a findings-bearing head." >&2
	exit 2
fi

_head_witness() {
	local bodies rc=0
	# CR review bodies + commit pins from the reviews payload, plus CR
	# issue comments (the walkthrough/summary lives there and is edited
	# in place with the reviewed range).
	bodies=$(
		{
			gh api "repos/$OWNER_NAME/pulls/$PR/reviews" --paginate --jq '.[] | select(.user.login as $l | '"$APPROVERS_JSON"' | index($l)) | "\(.commit_id) \(.body)"'
			gh api "repos/$OWNER_NAME/issues/$PR/comments" --paginate --jq '.[] | select(.user.login as $l | '"$APPROVERS_JSON"' | index($l)) | .body'
		} 2>&1
	) || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "approval-gate: ERROR — head-witness query failed (rc=$rc)" >&2
		return 2
	fi
	printf '%s' "$bodies" | grep -qF "$HEAD_SHA"
}

_hw_rc=0
_head_witness || _hw_rc=$?
if [ "$_hw_rc" -ne 0 ]; then
	echo "approval-gate: REFUSING — CR findings are clean but the final head $HEAD_SHA appears NOWHERE in CodeRabbit's reviews/comments: the final head is not verifiably reviewed." >&2
	echo "  Wait for CR-in-CI to review the head (its summary shows the reviewed range), then re-run. NOT nudging — '@coderabbitai approve' on an unreviewed head would launder it." >&2
	exit 2
fi

echo "approval-gate: converged-but-unrecorded (findings clean + head $HEAD_SHA reviewed) — posting nudge and waiting for the APPROVED record (timeout ${NUDGE_TIMEOUT}s)"
if ! gh pr comment "$PR" --body "$NUDGE_COMMENT"; then
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
		exit 2 # mid-poll query failure — fail closed rather than spin blind
	fi
	if [ "$waited" -ge "$NUDGE_TIMEOUT" ]; then
		echo "approval-gate: REFUSING — nudge posted but no APPROVED record within ${NUDGE_TIMEOUT}s. Check the PR (bot may be rate-limited); re-run when the record lands." >&2
		exit 2
	fi
	sleep "$POLL"
	waited=$((waited + POLL))
done
