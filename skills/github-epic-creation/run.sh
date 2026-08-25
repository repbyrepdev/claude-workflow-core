#!/bin/bash
set -euo pipefail
# v4.20 (#519): github-epic-creation skill wrapper.
# Creates a parent epic + N sub-issues, links via GraphQL addSubIssue.
# Sets SKILL_WRAPPER=1 so skill-bypass-guard allows the gh calls.
#
# v4.28-W3-CD (#747): when no --body-file is supplied, the wrapper auto-
# drafts the parent epic body via Copilot free-tier. When a sub omits
# --sub-body-file, that sub's body is also Copilot-drafted. The atomic
# guarantee is preserved: ALL bodies (parent + N subs) draft + preflight
# BEFORE any gh issue create runs. If ANY draft fails preflight, refuse
# rc=4 — no orphan epic on github.com.
#
# Opt-out:
#   --no-copilot               (per-invocation flag; applies to all bodies)
#   COPILOT_DRAFT_OFF=1        (env var, useful for trusted-edit flows)
#   --body-file / --sub-body-file (explicit body wins over draft per-slot)
#
# Usage:
#   .claude/skills/github-epic-creation/run.sh \
#     --title "v4.X EPIC: ..." [--body-file /tmp/epic-body.md] \
#     --sub-title "title-1" [--sub-body-file /tmp/body-1.md] \
#     --sub-title "title-2" [--sub-body-file /tmp/body-2.md] \
#     [--milestone vX.Y] [--label <label>]... [--no-copilot]
#
# Sub flags pair POSITIONALLY: each --sub-title is followed by an
# OPTIONAL --sub-body-file. When omitted, that slot Copilot-drafts.
# (Counts may differ; the parser tracks slots independently.)
#
# Exit codes:
#   0 — epic + subs created
#   2 — arg / validation error
#   3 — Copilot-default attempted but unavailable / draft empty
#   4 — Any draft (parent or sub) failed required-section preflight
#       (.github/ISSUE_TEMPLATE/epic.yml SSOT for parent;
#        sub bodies require non-empty + Area section minimum)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_lib/skill-common.sh
source "$SCRIPT_DIR/../_lib/skill-common.sh"
# Export SKILL_WRAPPER=1 once near top so all guarded calls (early
# git rev-parse, sourced helpers, gh issue create, GraphQL) consistently
# satisfy skill-bypass-guard.
export SKILL_WRAPPER=1
# Capture caller's cwd before cd-to-repo-root for relative --body-file
# / --sub-body-file resolution.
ORIG_CWD=$(pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "error: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT" || {
	echo "error: cannot cd to repo root '$REPO_ROOT'" >&2
	exit 2
}

TITLE=""
BODY_FILE=""
MILESTONE=""
LABELS=()
STAMP_LABEL=""
SUB_TITLES=()
SUB_BODIES=()
NO_COPILOT=0
BODY_FROM_COPILOT=0
SUB_BODY_FROM_COPILOT=()
# v4.30 (#779 PR1): when --parent N is set, the created epic is linked
# as a sub-issue of #N via addSubIssue GraphQL mutation. Closes the
# CR-Planner cascade gap where source-issue → epic linkage was text-
# only, leaving the source orphaned when the epic auto-closed.
OUTER_PARENT=""

# Absolutize a path against ORIG_CWD if relative.
_absolutize() {
	case "$1" in
	/*) printf '%s' "$1" ;;
	*) printf '%s' "$ORIG_CWD/$1" ;;
	esac
}

while [ $# -gt 0 ]; do
	case "$1" in
	--title)
		[ $# -ge 2 ] || {
			echo "error: --title requires a value" >&2
			exit 2
		}
		TITLE="$2"
		shift 2
		;;
	--body-file)
		[ $# -ge 2 ] || {
			echo "error: --body-file requires a value" >&2
			exit 2
		}
		BODY_FILE=$(_absolutize "$2")
		shift 2
		;;
	--milestone)
		[ $# -ge 2 ] || {
			echo "error: --milestone requires a value" >&2
			exit 2
		}
		MILESTONE="$2"
		shift 2
		;;
	--label)
		[ $# -ge 2 ] || {
			echo "error: --label requires a value" >&2
			exit 2
		}
		LABELS+=("$2")
		shift 2
		;;
	--stamp-label)
		# (2026-08-25 board explosion, upstream trim): a label applied to
		# the EPIC AND every sub-issue — unlike --label, which subs do not
		# inherit for area labels (CR pass 3). cr-plan passes
		# `auto:cr-plan` so ai-triage's existing "skip any auto:* label"
		# rule mechanically excludes scaffolding from plan-me labeling
		# (and CR from spending a plan comment on it) BEFORE the parser
		# guards would refuse it anyway. Created if missing, pre-use.
		[ $# -ge 2 ] || {
			echo "error: --stamp-label requires a value" >&2
			exit 2
		}
		STAMP_LABEL="$2"
		shift 2
		;;
	# Sub-issues: each --sub-title creates a new slot; the optional
	# --sub-body-file that follows fills that slot's body. When
	# --sub-body-file is omitted between two --sub-title flags, the
	# first slot's body is Copilot-drafted.
	--sub-title)
		[ $# -ge 2 ] || {
			echo "error: --sub-title requires a value" >&2
			exit 2
		}
		SUB_TITLES+=("$2")
		# Pre-fill the corresponding SUB_BODIES slot with empty string
		# (Copilot-draft sentinel); --sub-body-file will overwrite if present.
		SUB_BODIES+=("")
		SUB_BODY_FROM_COPILOT+=(0)
		shift 2
		;;
	--sub-body-file)
		[ $# -ge 2 ] || {
			echo "error: --sub-body-file requires a value" >&2
			exit 2
		}
		# Fill the LAST sub slot. Refuse if no --sub-title preceded.
		if [ ${#SUB_TITLES[@]} -eq 0 ]; then
			echo "error: --sub-body-file requires a preceding --sub-title" >&2
			exit 2
		fi
		last=$((${#SUB_BODIES[@]} - 1))
		SUB_BODIES[last]=$(_absolutize "$2")
		shift 2
		;;
	--no-copilot)
		NO_COPILOT=1
		shift
		;;
	--parent)
		[ $# -ge 2 ] || {
			echo "error: --parent requires a value" >&2
			exit 2
		}
		OUTER_PARENT="$2"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	--yes | --approve)
		# #2544: non-interactive approval WITHOUT an env-var prefix. See
		# skc_approve_or_exit in ../_lib/skill-common.sh.
		# shellcheck disable=SC2034 # read by skc_approve_or_exit (sourced lib)
		SKC_ASSUME_YES=1
		shift
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ "${COPILOT_DRAFT_OFF:-0}" = "1" ]; then
	NO_COPILOT=1
fi

if [ -z "$TITLE" ]; then
	echo "Usage: $0 --title <title> [--body-file <path>] [--sub-title ... [--sub-body-file ...]]... [--label ...] [--stamp-label <label>] [--milestone ...] [--parent <issue-num>] [--no-copilot]" >&2
	echo "Note: --body-file is optional — Copilot-default auto-drafts when omitted (v4.28-W3-CD #747)." >&2
	echo "Note: --parent N links the created epic AS A SUB-ISSUE of #N via addSubIssue (v4.30 #779 PR1)." >&2
	exit 2
fi

# Validate --parent value early so we fail BEFORE creating the epic.
if [ -n "$OUTER_PARENT" ]; then
	# v4.30 #779 PR1 CR-in-CI r3 minor: reject zero (issue numbers start at 1).
	if ! [[ $OUTER_PARENT =~ ^[1-9][0-9]*$ ]]; then
		echo "error: --parent requires a positive issue number (got: $OUTER_PARENT)" >&2
		exit 2
	fi
	# Verify the parent issue exists + is open. Fail-loud on API error;
	# don't silently degrade to "linkage skipped" — silent skip is exactly
	# the cascade-gap class this flag exists to close.
	# v4.30 #779 PR1 Phase 2 r3 CR-CLI major: split stdout/stderr capture
	# so gh warnings (deprecation, auth notices) don't corrupt the state
	# comparison. Pre-fix `parent_state=$(gh ... 2>&1)` merged stderr +
	# stdout; a warning would make `[ != OPEN ]` fail with confusing
	# parent_state="Warning: ...\nOPEN" — never matches OPEN.
	# v4.30 #779 PR1 Phase 2 r5 CR-CLI critical: NO inline trap here.
	# An earlier r4 trap was added but clobbered the DRAFT_DIR cleanup
	# trap set higher in the script (line ~218, NEED_COPILOT path). The
	# 2-line gap between mktemp + rm is a tiny leak window that we
	# accept rather than risk breaking DRAFT_DIR cleanup. Explicit
	# rm -f on both success + failure paths covers the normal cases.
	#
	# v4.30 #779 PR1 CR-in-CI r2 major: guard mktemp under set -e so
	# /tmp-full / permission errors surface a clear message instead of
	# the bash "command failed" raw abort.
	_pchk_err=$(mktemp -t ai-triage-pchk-err.XXXXXX) || {
		echo "error: mktemp failed (disk full? /tmp permissions?) — cannot verify --parent" >&2
		exit 2
	}
	parent_state=$(gh issue view "$OUTER_PARENT" --json state -q .state 2>"$_pchk_err") || {
		echo "error: --parent #$OUTER_PARENT lookup failed: $(cat "$_pchk_err")" >&2
		rm -f "$_pchk_err"
		exit 2
	}
	rm -f "$_pchk_err"
	if [ "$parent_state" != "OPEN" ]; then
		echo "error: --parent #$OUTER_PARENT is $parent_state (must be OPEN to link an epic under it)" >&2
		exit 2
	fi
fi

# Validate any explicit body-file paths exist BEFORE Copilot-drafting.
# Atomic guarantee: refuse upfront on bad paths instead of after
# spending Copilot calls on subs that won't be reached.
if [ -n "$BODY_FILE" ] && [ ! -f "$BODY_FILE" ]; then
	echo "--body-file not found: $BODY_FILE" >&2
	exit 2
fi
for i in "${!SUB_BODIES[@]}"; do
	sub_body="${SUB_BODIES[$i]}"
	if [ -n "$sub_body" ] && [ ! -f "$sub_body" ]; then
		echo "Sub body file not found: $sub_body (sub-title: ${SUB_TITLES[$i]})" >&2
		echo "Aborting BEFORE creating parent epic — atomic guarantee." >&2
		exit 2
	fi
done

# Identify slots that need Copilot-drafting. Guard array deref with
# count check — empty arrays under set -u trip "unbound variable".
NEED_COPILOT=0
[ -z "$BODY_FILE" ] && NEED_COPILOT=1
if [ "${#SUB_BODIES[@]}" -gt 0 ]; then
	for sb in "${SUB_BODIES[@]}"; do
		[ -z "$sb" ] && NEED_COPILOT=1
	done
fi

if [ "$NEED_COPILOT" = "1" ] && [ "$NO_COPILOT" = "1" ]; then
	echo "error: missing --body-file and/or --sub-body-file slot(s) + --no-copilot/COPILOT_DRAFT_OFF=1 set" >&2
	echo "  hint: pass --body-file + every --sub-body-file, or remove --no-copilot to use Copilot-default" >&2
	exit 2
fi

# Set up Copilot drafting if needed.
if [ "$NEED_COPILOT" = "1" ]; then
	COPILOT_HELPER="$REPO_ROOT/.claude/scripts/copilot/try-free.sh"
	if [ ! -x "$COPILOT_HELPER" ]; then
		echo "error: Copilot-draft default unavailable — $COPILOT_HELPER missing/non-executable" >&2
		echo "  hint: pass --body-file + every --sub-body-file, or set COPILOT_DRAFT_OFF=1 + provide all bodies" >&2
		exit 3
	fi
	EPIC_TPL="$REPO_ROOT/.github/ISSUE_TEMPLATE/epic.yml"
	if [ -f "$EPIC_TPL" ]; then
		EPIC_TPL_TEXT=$(cat "$EPIC_TPL") || {
			echo "error: cannot read $EPIC_TPL (rc=$?)" >&2
			exit 2
		}
	else
		EPIC_TPL_TEXT="(epic.yml unavailable)"
	fi
	# Single mktemp -d for ALL drafts (parent + per-sub) — one trap, one cleanup.
	DRAFT_DIR=$(mktemp -d -t epic-drafts.XXXXXX) || {
		echo "error: mktemp -d failed (disk full? /tmp permissions?)" >&2
		exit 3
	}
	trap 'rm -rf "${DRAFT_DIR:-}"' EXIT
fi

# Helper: draft one body via Copilot. Args: prompt-context, output-path.
# Surfaces helper stderr on rc!=0; exits 3 on Copilot failure.
_copilot_draft() {
	local prompt="$1" out_path="$2"
	local err_path="${out_path}.err"
	local rc=0
	"$COPILOT_HELPER" "$prompt" >"$out_path" 2>"$err_path" || rc=$?
	local grep_rc=0
	grep -q '[^[:space:]]' "$out_path" || grep_rc=$?
	if [ "$grep_rc" -gt 1 ]; then
		echo "error: cannot read draft body (grep rc=$grep_rc) — disk fault?" >&2
		exit 3
	fi
	if [ "$rc" -ne 0 ] || [ "$grep_rc" -eq 1 ]; then
		echo "error: Copilot draft returned empty/whitespace (rc=$rc) — auth/network/quota issue?" >&2
		if [ -s "$err_path" ]; then
			echo "  helper stderr:" >&2
			while IFS= read -r line; do echo "    $line" >&2; done <"$err_path"
		fi
		echo "  hint: pass --body-file + --sub-body-file, or set COPILOT_DRAFT_OFF=1 + provide bodies" >&2
		exit 3
	fi
}

# Draft parent body if needed.
if [ -z "$BODY_FILE" ]; then
	echo "drafting parent epic body via Copilot free-tier…" >&2
	parent_path="$DRAFT_DIR/parent"
	_copilot_draft "Draft a GitHub epic issue body. Title: $TITLE. Mirror this template's required-section structure exactly (use '## Section' or '**Section:**' headers): $EPIC_TPL_TEXT. Output the body only — no preamble. Required area label values: monitoring, infrastructure, security, performance — pick the most relevant in the Area section." "$parent_path"
	BODY_FILE="$parent_path"
	BODY_FROM_COPILOT=1
fi

# Draft sub bodies if needed.
for i in "${!SUB_BODIES[@]}"; do
	sb="${SUB_BODIES[$i]}"
	if [ -z "$sb" ]; then
		echo "drafting sub-$i body via Copilot free-tier…" >&2
		sub_path="$DRAFT_DIR/sub-$i"
		# Sub bodies are typically task/feature-shaped. Lighter prompt
		# than parent — caller's --sub-title carries the intent.
		_copilot_draft "Draft a GitHub task/feature sub-issue body for parent epic '$TITLE'. Sub title: ${SUB_TITLES[$i]}. Include '## Area' (one of: monitoring, infrastructure, security, performance) and '## What needs to be done' sections. Output the body only — no preamble." "$sub_path"
		SUB_BODIES[i]="$sub_path"
		SUB_BODY_FROM_COPILOT[i]=1
	fi
done

# ATOMIC preflight: validate ALL drafted bodies against required sections
# BEFORE any gh issue create. If ANY fails, refuse rc=4 — no orphan epic.
_required_epic_sections="Area|Goal|Scope|Sub-issues|Acceptance criteria|Rollout plan|Rollback plan"

_check_required_sections() {
	local body_file="$1" required="$2"
	local missing=""
	IFS='|' read -ra _sections <<<"$required"
	for section in "${_sections[@]}"; do
		esc=$(printf '%s' "$section" | sed 's/[][\\.*^$(){}?+|]/\\&/g')
		if ! grep -qE "^(##[[:space:]]+${esc}(\?)?($|:)|\*\*${esc}(\?)?:?\*\*)" "$body_file"; then
			missing="${missing}
  - ${section}"
		fi
	done
	printf '%s' "$missing"
}

# Parent body must have all 7 epic sections.
parent_missing=$(_check_required_sections "$BODY_FILE" "$_required_epic_sections")
if [ -n "$parent_missing" ]; then
	if [ "$BODY_FROM_COPILOT" = "1" ]; then
		echo "error: Copilot-drafted PARENT epic body failed required-section preflight — refusing to create." >&2
		echo "missing section(s):$parent_missing" >&2
		echo "  hint: re-run + Copilot will redraft, or pass --body-file with a fixed body." >&2
		exit 4
	fi
	echo "error: epic body missing required section(s):$parent_missing" >&2
	echo ".github/ISSUE_TEMPLATE/epic.yml requires: $(echo "$_required_epic_sections" | tr '|' ',')" >&2
	exit 2
fi

# Sub bodies must have at least an Area section (lighter than full
# bug/feature/task validation since sub-template isn't declared).
_required_sub_sections="Area"
for i in "${!SUB_BODIES[@]}"; do
	sub_missing=$(_check_required_sections "${SUB_BODIES[$i]}" "$_required_sub_sections")
	if [ -n "$sub_missing" ]; then
		if [ "${SUB_BODY_FROM_COPILOT[$i]}" = "1" ]; then
			echo "error: Copilot-drafted sub-$i body (${SUB_TITLES[$i]}) failed required-section preflight — refusing to create." >&2
			echo "missing section(s):$sub_missing" >&2
			echo "  hint: re-run + Copilot will redraft, or pass --sub-body-file for that sub." >&2
			exit 4
		fi
		echo "error: sub-$i body (${SUB_TITLES[$i]}) missing required section(s):$sub_missing" >&2
		exit 2
	fi
done

# Auto-resolve milestone. Loud-fail on resolution errors.
if [ -z "$MILESTONE" ]; then
	ver=$(skc_extract_version_prefix)
	if [ -n "$ver" ]; then
		if ! MILESTONE=$(skc_match_milestone "$ver" 2>&1); then
			echo "milestone auto-resolve failed for prefix '$ver':" >&2
			echo "$MILESTONE" >&2
			echo "Re-run with explicit --milestone <title>." >&2
			exit 2
		fi
	fi
fi

echo "=== Creating epic ==="
echo "  Title:    $TITLE"
echo "  Body:     $BODY_FILE"
echo "  Labels:   ${LABELS[*]:-(none)}"
echo "  Milestone: ${MILESTONE:-(none)}"
echo "  Subs:     ${#SUB_TITLES[@]}"
for i in "${!SUB_TITLES[@]}"; do
	echo "    - ${SUB_TITLES[$i]} ← ${SUB_BODIES[$i]}"
done
echo ""
skc_approve_or_exit "Create this epic + ${#SUB_TITLES[@]} sub-issues?"

# Build parent labels: `gh issue create --body-file` does NOT trigger
# template frontmatter label application (unlike `--template epic.yml` via
# the web UI), so we must explicitly add `epic` + `enhancement` unless the
# caller already passed them via --label. Sub-issues must NOT inherit the
# `epic` label (CR pass 3 finding) — only the parent gets it.
PARENT_LABELS=("${LABELS[@]:-}")
have_epic=0
have_enhancement=0
for l in "${PARENT_LABELS[@]}"; do
	[ "$l" = "epic" ] && have_epic=1
	[ "$l" = "enhancement" ] && have_enhancement=1
done
[ "$have_epic" = "0" ] && PARENT_LABELS+=("epic")
[ "$have_enhancement" = "0" ] && PARENT_LABELS+=("enhancement")
# --stamp-label: ensure the label EXISTS before first use (the missing-
# plan-parsed-label wholesale-relabel failure is the precedent — a create
# on an existing label is a harmless no-op), then stamp the parent; the
# sub loop below stamps each sub.
if [ -n "${STAMP_LABEL:-}" ]; then
	gh label create "$STAMP_LABEL" --color "ededed" \
		--description "cr-plan scaffolding — auto:* labels are never triaged plan-me" \
		2>/dev/null || true
	PARENT_LABELS+=("$STAMP_LABEL")
fi
GH_ARGS=(issue create --title "$TITLE" --body-file "$BODY_FILE")
for l in "${PARENT_LABELS[@]}"; do GH_ARGS+=(--label "$l"); done
[ -n "$MILESTONE" ] && GH_ARGS+=(--milestone "$MILESTONE")

PARENT_URL=$(gh "${GH_ARGS[@]}")
PARENT_NUM=$(printf '%s' "$PARENT_URL" | grep -oE '[0-9]+$')
if ! [[ $PARENT_NUM =~ ^[0-9]+$ ]]; then
	echo "Failed to parse parent issue number from: $PARENT_URL" >&2
	exit 2
fi
echo "✓ Created parent epic #$PARENT_NUM ($PARENT_URL)"

# v4.30 (#779 PR1): link the new epic as a sub-issue of --parent
# (the outer parent), so closure cascades source → epic → subs.
# Fail-loud — silent skip is exactly the cascade-gap class this flag
# closes.
#
# v4.30 #779 PR1 Phase 2 r1 CR fix: on addSubIssue failure, auto-close
# the orphan epic so operators don't have to manually clean up dangling
# unlinked epics. Close (not delete) is reversible — operator can
# `gh issue reopen` + relink if the failure was transient. Sub-issues
# haven't been created yet at this point (block runs BEFORE the sub-
# creation loop), so closing the parent leaves no orphan children.
if [ -n "$OUTER_PARENT" ]; then
	_link_ok=1
	if ! skc_graphql_add_sub_issue "$PARENT_NUM" "$OUTER_PARENT"; then
		# v4.30 #779 PR1 CR-in-CI r7 major: read-after-write verify before
		# auto-close. addSubIssue may have succeeded SERVER-SIDE but the
		# client got a transient error (network blip, rate limit on response
		# path). Auto-closing would WRONGLY close a correctly-linked epic.
		# Query the parent's sub-issue list — if PARENT_NUM is in it,
		# linkage IS in place; skip auto-close.
		# v4.30 #779 PR1 CR-in-CI r11 major: guard gh repo view under set -e.
		# Transient gh API/auth failure would hard-exit before the controlled
		# verify path runs, leaving operator with abrupt failure.
		_owner=$(gh repo view --json owner -q .owner.login 2>/dev/null || true)
		_name=$(gh repo view --json name -q .name 2>/dev/null || true)
		if [ -z "$_owner" ] || [ -z "$_name" ]; then
			echo "error: gh repo view failed — cannot run read-after-write verify" >&2
			echo "  Refusing to auto-close — manual verification required: gh issue view $OUTER_PARENT" >&2
			exit 2
		fi
		# v4.30 #779 PR1 CR-in-CI r8 major: capture verify stderr + rc
		# separately. If the verify ITSELF fails (network down, auth,
		# rate limit), treating that as "not linked" would auto-close a
		# possibly-correctly-linked epic. On verify failure: surface +
		# bail (don't auto-close); operator can manually confirm state.
		_verify_err=$(mktemp -t epic-verify-err.XXXXXX) || _verify_err=""
		_verify_rc=0
		# v4.30 #779 PR1 CR-in-CI r9 major: query the CHILD's parent field
		# instead of paginating parent.subIssues. The previous query used
		# `subIssues(first: 100)` which would silently miss links past
		# page 1 — for parents with >100 sub-issues, this falsely reports
		# "not linked" → wrongly auto-closes a correctly-linked epic.
		# Child→parent is a single field lookup, pagination-immune.
		if [ -n "$_verify_err" ]; then
			_verify_resp=$(gh api graphql -H "GraphQL-Features: sub_issues" \
				-f query="{ repository(owner: \"$_owner\", name: \"$_name\") { issue(number: $PARENT_NUM) { parent { number } } } }" \
				--jq ".data.repository.issue.parent.number // empty" \
				2>"$_verify_err") || _verify_rc=$?
		else
			_verify_resp=$(gh api graphql -H "GraphQL-Features: sub_issues" \
				-f query="{ repository(owner: \"$_owner\", name: \"$_name\") { issue(number: $PARENT_NUM) { parent { number } } } }" \
				--jq ".data.repository.issue.parent.number // empty" \
				2>/dev/null) || _verify_rc=$?
		fi
		if [ "$_verify_rc" -ne 0 ]; then
			echo "error: read-after-write verify FAILED (rc=$_verify_rc) — cannot determine linkage state" >&2
			[ -n "$_verify_err" ] && [ -s "$_verify_err" ] && head -c 500 "$_verify_err" >&2 && echo "" >&2
			echo "  Refusing to auto-close — manual verification required:" >&2
			echo "    gh issue view $OUTER_PARENT  # check if #$PARENT_NUM appears in sub-issues" >&2
			echo "    Either: gh issue close $PARENT_NUM (if NOT linked) OR retry addSubIssue (if NOT linked but want it)" >&2
			[ -n "$_verify_err" ] && rm -f "$_verify_err"
			exit 2
		fi
		[ -n "$_verify_err" ] && rm -f "$_verify_err"
		# r9: _verify_resp is the new epic's parent number (or empty if unparented).
		# Linkage succeeded iff child's parent == OUTER_PARENT.
		if [ "$_verify_resp" = "$OUTER_PARENT" ]; then
			echo "  ✓ read-after-write verify: addSubIssue actually succeeded server-side (#$PARENT_NUM linked under #$OUTER_PARENT)" >&2
			echo "  Skipping auto-close — the linkage IS in place." >&2
			# _link_ok stays 1 — fall through to normal "linked" echo below.
		else
			_link_ok=0
		fi
	fi
	if [ "$_link_ok" = "0" ]; then
		echo "error: failed to link epic #$PARENT_NUM under --parent #$OUTER_PARENT" >&2
		echo "  Read-after-write verify confirmed NO linkage server-side." >&2
		echo "  Auto-closing orphan epic #$PARENT_NUM (reversible via 'gh issue reopen')..." >&2
		# v4.30 #779 PR1 CR-in-CI r4 major: don't gate orphan cleanup on mktemp.
		# Failure of mktemp (e.g. /tmp full) degrades to no-stderr-capture but
		# the gh issue close still runs — fail-closed contract preserved.
		_close_err=$(mktemp -t ai-triage-close-err.XXXXXX) || _close_err=""
		if [ -n "$_close_err" ]; then
			if gh issue close "$PARENT_NUM" --comment "Auto-closed: addSubIssue mutation failed during creation; epic was unlinked from intended parent #$OUTER_PARENT. To recover: 'gh issue reopen $PARENT_NUM' + retry addSubIssue manually." >/dev/null 2>"$_close_err"; then
				echo "  ✓ orphan epic #$PARENT_NUM closed" >&2
			else
				echo "  ⚠ failed to auto-close orphan epic #$PARENT_NUM:" >&2
				head -c 500 "$_close_err" >&2
				echo "" >&2
				echo "  Manual cleanup required: gh issue close $PARENT_NUM" >&2
			fi
			rm -f "$_close_err"
		else
			echo "  WARN: mktemp failed; auto-close stderr will not be captured" >&2
			if gh issue close "$PARENT_NUM" --comment "Auto-closed: addSubIssue mutation failed during creation; epic was unlinked from intended parent #$OUTER_PARENT. To recover: 'gh issue reopen $PARENT_NUM' + retry addSubIssue manually." >/dev/null 2>/dev/null; then
				echo "  ✓ orphan epic #$PARENT_NUM closed" >&2
			else
				echo "  ⚠ failed to auto-close orphan epic #$PARENT_NUM (stderr lost — mktemp failed)" >&2
				echo "  Manual cleanup required: gh issue close $PARENT_NUM" >&2
			fi
		fi
		exit 2
	fi
	echo "  ↳ linked #$PARENT_NUM under outer parent #$OUTER_PARENT"
fi

# Create each sub.
SUB_NUMS=()
for i in "${!SUB_TITLES[@]}"; do
	sub_title="${SUB_TITLES[$i]}"
	sub_body="${SUB_BODIES[$i]}"
	SUB_ARGS=(issue create --title "$sub_title" --body-file "$sub_body")
	for l in "${LABELS[@]:-}"; do [ -n "$l" ] && SUB_ARGS+=(--label "$l"); done
	# Subs do NOT inherit --label (area labels, CR pass 3) but DO get the
	# stamp — the whole point is excluding every scaffolding issue from
	# plan-me triage, and the runaway recursion came through SUBS.
	[ -n "${STAMP_LABEL:-}" ] && SUB_ARGS+=(--label "$STAMP_LABEL")
	[ -n "$MILESTONE" ] && SUB_ARGS+=(--milestone "$MILESTONE")
	sub_url=$(gh "${SUB_ARGS[@]}")
	sub_num=$(printf '%s' "$sub_url" | grep -oE '[0-9]+$')
	if ! [[ $sub_num =~ ^[0-9]+$ ]]; then
		echo "Failed to parse sub-issue number from: $sub_url (title: $sub_title)" >&2
		echo "Parent #$PARENT_NUM left open; earlier subs may be unlinked." >&2
		exit 2
	fi
	echo "  ✓ Sub #$sub_num: $sub_title"
	skc_graphql_add_sub_issue "$sub_num" "$PARENT_NUM"
	echo "    ↳ linked to #$PARENT_NUM"
	SUB_NUMS+=("$sub_num")
done

# Verify parent's sub-issue count matches what we created.
expected=${#SUB_NUMS[@]}
owner_name=$(skc_repo_owner_name)
owner="${owner_name%/*}"
name="${owner_name#*/}"
if ! actual=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query="{ repository(owner: \"$owner\", name: \"$name\") { issue(number: $PARENT_NUM) { subIssues(first: 100) { totalCount } } } }" \
	--jq '.data.repository.issue.subIssues.totalCount' 2>&1); then
	echo "⚠ sub-issue verify query failed: $actual" >&2
	echo "  Parent #$PARENT_NUM has $expected sub-issues (assumed from creates above)." >&2
	echo "  Verify manually: gh issue view $PARENT_NUM" >&2
elif [ "$actual" != "$expected" ]; then
	echo "⚠ Expected $expected sub-issues linked, got $actual — check manually" >&2
else
	echo "✓ Verified $actual sub-issues linked to #$PARENT_NUM"
fi

printf '%s\n' "$PARENT_NUM"
