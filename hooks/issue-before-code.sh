#!/bin/bash
set -u
# event: PreToolUse
# matcher: Bash
# v4.24-L (#577) · #2416 — PreToolUse Bash: refuses branch-creation
# (`git checkout -b <name>` / `git switch -c <name>`) for ALL work-branch
# types unless the name follows the canonical convention AND embeds a linked
# issue that exists and is assigned to the current user.
#
# The convention is the SSOT in _lib/branch-convention.sh — the SAME definition
# the PR-time verify (scripts/meta-bootstrap.sh feature-branch) uses. There is
# NO inline branch regex here, so the creation-time gate and the PR-time verify
# can never drift (#2416). Before #2416 this gate was feat/-only, which let a
# mis-named `chore/labels/2289-...` branch slip past creation and only fail at
# PR time.
#
# Decision (per branch_convention_validate):
#   scratch   (no <type>/ prefix)            → allow (casual local branches)
#   valid     (<type>/vX.Y.Z/<issue>-<slug>) → require issue exists + @me-assigned
#   malformed (claims <type>/ but no match)  → DENY with convention guidance
#
# Issue resolution: branch_convention_extract_issue (path-segment NNN, or an
# explicit #NNN). `gh issue view NNN` must succeed (issue exists) and list @me
# as an assignee. Transient gh failures (auth/network/5xx) fail-open; only a
# genuine "not found" denies. Prevents the "coding without a tracking issue"
# class of slip-ups flagged in #201 + memory feedback_batch_related_subissues.
#
# Emergency bypass: inline `ISSUE_BEFORE_CODE_SKIP=1 git checkout -b …`
# sentinel in the command string (PreToolUse hooks don't see the env).
# Logged to .claude/logs/issue-before-code-skip.jsonl for audit.
#
# Registered via ~/.claude/settings.json hooks.PreToolUse matcher=Bash.

PAYLOAD=$(cat 2>/dev/null || echo "{}")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$CMD" ] && exit 0

# Cheap pre-filter (no lib sourcing on the hot path — this hook fires on every
# Bash command): is this a branch-creation command at all? Anchored match
# tolerates a leading `VAR=val ` env prefix. Covers every create verb —
# `checkout -b`/`-B` (force) and `switch -c`/`-C`/`--create` — so a malformed
# force-create (`git checkout -B chore/labels/2289-x`) can't slip the gate.
# Type-agnostic — the precise convention check happens only after the SSOT loads.
if [[ ! $CMD =~ ^([[:space:]]*[A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+(checkout[[:space:]]+-[bB]|switch[[:space:]]+(-[cC]|--create))[[:space:]]+[^[:space:]] ]]; then
	exit 0
fi

# v4.24-Q (#604) — shared sentinel + deny libs. Resolve via the hook's own
# install dir (not `git rev-parse`) so the hook works when invoked from an
# unrelated cwd (test harness tmpdir, arbitrary git repo under the session).
HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"
LIB_SENTINEL="${HOOK_DIR}/../_lib/hook-inline-sentinel.sh"
LIB_CONVENTION="${HOOK_DIR}/../_lib/branch-convention.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi
if [ -f "$LIB_SENTINEL" ]; then
	# shellcheck source=../_lib/hook-inline-sentinel.sh
	source "$LIB_SENTINEL"
else
	hook_inline_sentinel_check() { return 1; }
fi
# The branch-convention SSOT. If it's somehow missing (packaging error), fail-
# open rather than block legit work — the PR-time verify still catches drift.
if [ -f "$LIB_CONVENTION" ]; then
	# shellcheck source=../_lib/branch-convention.sh
	source "$LIB_CONVENTION"
else
	echo "issue-before-code: missing $LIB_CONVENTION — skipping convention check" >&2
	exit 0
fi
# Shared gh-error classifier SSOT (#2416 r2) — distinguishes a genuine missing
# issue from a transient gh failure (a naive "Could not resolve" grep also
# matches the DNS-host transport error → false-deny). Inline fallback mirrors
# the lib if it is somehow absent.
LIB_CLASSIFY="${HOOK_DIR}/../_lib/gh-issue-classify.sh"
if [ -f "$LIB_CLASSIFY" ]; then
	# shellcheck source=../_lib/gh-issue-classify.sh
	source "$LIB_CLASSIFY"
else
	# Classifier SSOT missing (packaging error) — degrade SAFELY: never report a
	# definite not-found, so the hook fails open (skips the not-found deny) rather
	# than carry an inline copy of the pattern that could drift from the SSOT.
	gh_issue_view_missing() { return 1; }
fi

# Inline-sentinel bypass.
if hook_inline_sentinel_check "ISSUE_BEFORE_CODE_SKIP" "$CMD" "issue-before-code"; then
	exit 0
fi

# Extract the branch NAME: the first token after the create verb, up to
# whitespace or a shell separator. Type-agnostic (the convention check
# classifies it next).
# SYNC: the create-verb set here MUST stay in lockstep with the pre-filter
# regex above (the `(checkout -[bB]|switch -[cC]|switch --create)` shape). If a
# new create verb/flag is supported, update BOTH this grep and the pre-filter,
# or a command the pre-filter admits could fail extraction (and fail-open).
BRANCH=$(printf '%s' "$CMD" | grep -oE '(checkout[[:space:]]+-[bB]|switch[[:space:]]+-[cC]|switch[[:space:]]+--create)[[:space:]]+[^[:space:];&|]+' | head -1 | sed -E 's/^(checkout|switch)[[:space:]]+(-[bBcC]|--create)[[:space:]]+//')
if [ -z "$BRANCH" ]; then
	# Pre-filter matched but extraction failed (weird spacing) — fail-open
	# rather than block a legit command.
	exit 0
fi

# Classify against the SSOT convention. This hook has `set -u` only (no set -e),
# so the bare call's non-zero rc does not abort; `case $?` reads it directly.
branch_convention_validate "$BRANCH"
case $? in
0) : ;;      # valid work branch — fall through to issue existence + assignment
1) exit 0 ;; # scratch name (no <type>/ prefix) — allowed, no issue lineage
2)
	hook_deny "issue-before-code" \
		"branch '$BRANCH' is not per convention. Expected: $(branch_convention_expected). Rename it, or bypass: ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON=\"...\" <cmd>"
	;;
esac

# Valid convention branch → resolve the embedded issue number via the SSOT.
ISSUE_NUM=$(branch_convention_extract_issue "$BRANCH")
if [ -z "$ISSUE_NUM" ]; then
	# Defensive: a valid branch always embeds an issue number; if extraction
	# somehow returns empty, fail-open rather than block.
	exit 0
fi

# Verify the issue EXISTS and is assigned to the current user. gh absent =
# can't verify; fail-open.
if ! command -v gh >/dev/null 2>&1; then
	exit 0
fi

# One gh call proves existence (success) + fetches the assignee list; the @me
# comparison needs the `gh api user` call below. Capture rc + stderr separately
# (this hook has set -u only, no pipefail) so the shared classifier can
# distinguish a genuine "not found" (deny) from transient auth/network (skip).
gh_err=$(mktemp)
gh_rc=0
gh_out=$(gh issue view "$ISSUE_NUM" --json assignees 2>"$gh_err") || gh_rc=$?
if [ "$gh_rc" -ne 0 ]; then
	if gh_issue_view_missing "$gh_err"; then
		# Issue genuinely doesn't exist — the branch references a phantom issue.
		err_head=$(head -c 200 "$gh_err")
		rm -f "$gh_err"
		hook_deny "issue-before-code" \
			"branch '$BRANCH' references issue #$ISSUE_NUM but it does not exist on GitHub ($err_head). File the issue first (github-issue-creation skill) or bypass: ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON=\"...\" <cmd>"
	fi
	# Transient backend error — don't block on it.
	echo "issue-before-code: gh issue view #$ISSUE_NUM failed (rc=$gh_rc) — skipping verification ($(head -c 200 "$gh_err"))" >&2
	rm -f "$gh_err"
	exit 0
fi
rm -f "$gh_err"

# Resolve current login for the assignee comparison.
gh_err=$(mktemp)
gh_rc=0
ME=$(gh api user --jq .login 2>"$gh_err") || gh_rc=$?
if [ "$gh_rc" -ne 0 ]; then
	echo "issue-before-code: gh api user failed (rc=$gh_rc) — skipping assignee verification ($(head -c 200 "$gh_err"))" >&2
	rm -f "$gh_err"
	exit 0
fi
rm -f "$gh_err"
if [ -z "$ME" ]; then
	echo "issue-before-code: gh api user returned empty login — skipping assignee verification" >&2
	exit 0
fi

# Parse assignees (guard jq so a schema/truncation glitch can't trip set -u).
jq_err=$(mktemp)
jq_rc=0
ASSIGNED=$(printf '%s' "$gh_out" | jq -r --arg me "$ME" '[.assignees[].login] | any(. == $me)' 2>"$jq_err") || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
	echo "issue-before-code: jq failed parsing assignees (rc=$jq_rc) — skipping verification ($(head -c 200 "$jq_err"))" >&2
	rm -f "$jq_err"
	exit 0
fi
rm -f "$jq_err"

if [ "$ASSIGNED" != "true" ]; then
	hook_deny "issue-before-code" \
		"#$ISSUE_NUM (resolved from '$BRANCH') is NOT assigned to $ME. Run .claude/scripts/board/assign-self.sh $ISSUE_NUM first OR bypass: ISSUE_BEFORE_CODE_SKIP=1 ISSUE_BEFORE_CODE_SKIP_REASON=\"...\" <cmd>"
fi

exit 0
