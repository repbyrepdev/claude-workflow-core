#!/bin/bash
set -euo pipefail
# v4.28-W5 (#712): cr-plan skill wrapper.
# Drives CodeRabbit Issue Planner → epic + sub-issues automation.
#
# Subcommands:
#   trigger <issue-num>    Apply plan-me label + post @coderabbitai plan comment.
#   parse <issue-num>      Read CR plan comment, extract Implementation Steps
#                          (or older Phases form), invoke github-epic-creation
#                          skill to create epic+subs with GraphQL sub-issue
#                          linkage. (#788: dual-heading support after dogfood
#                          showed CR emits Implementation Steps, not Phases.)
#
# Why a separate skill: CR Issue Planner generates plans (AI, posts as
# comment) but does NOT create sub-issues or link them. Our existing
# github-epic-creation skill creates parent + N subs + links via
# `addSubIssue` GraphQL mutation. cr-plan parse stitches them together.
#
# Required env:
#   APPROVE=1              (parse subcommand only — non-interactive guard,
#                          mirrors github-issue-creation skill)
#
# Required tools:
#   gh (authed), jq, .claude/skills/github-epic-creation/run.sh

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# v0.6.7 (#15): REPO_ROOT via git rev-parse (consumer or plugin-cache OK).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# EPIC_SKILL: prefer consumer copy, fall back to sibling in plugin cache.
# Both layouts colocate this skill under <root>/skills/github-epic-creation/.
if [ -n "${EPIC_SKILL:-}" ]; then
	: # env override (bats stub) wins
elif [ -x "$REPO_ROOT/.claude/skills/github-epic-creation/run.sh" ]; then
	EPIC_SKILL="$REPO_ROOT/.claude/skills/github-epic-creation/run.sh"
elif [ -x "$SCRIPT_DIR/../github-epic-creation/run.sh" ]; then
	EPIC_SKILL="$SCRIPT_DIR/../github-epic-creation/run.sh"
else
	echo "cr-plan: github-epic-creation/run.sh not found (consumer .claude/ or plugin sibling)" >&2
	exit 2
fi

# SKILL_WRAPPER=1 lets nested gh/git calls pass skill-bypass-guard.sh.
export SKILL_WRAPPER=1

usage() {
	cat <<'EOF'
Usage:
  cr-plan trigger <issue-num>
  cr-plan parse <issue-num>

Subcommands:
  trigger    Apply plan-me label + post @coderabbitai plan when needed.
             Safe to retry: skips the comment if plan-me is already
             present (label add is naturally idempotent).
  parse      Read CR plan comment from issue, extract Implementation
             Steps (or older Phases) section, create epic + sub-issues
             via github-epic-creation skill.
             Requires APPROVE=1 (non-interactive guard).

Env:
  APPROVE=1  Required for `parse` (mirrors github-issue-creation).
EOF
}

cmd="${1:-}"
issue="${2:-}"

if [ "$cmd" = "--help" ] || [ "$cmd" = "-h" ]; then
	usage
	exit 0
fi

if [ -z "$cmd" ] || [ -z "$issue" ] || ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
	usage >&2
	exit 2
fi

command -v gh >/dev/null 2>&1 || {
	echo "cr-plan: ERROR: gh CLI not on PATH" >&2
	exit 2
}
command -v jq >/dev/null 2>&1 || {
	echo "cr-plan: ERROR: jq not on PATH" >&2
	exit 2
}

issue_err=$(mktemp -t cr-plan-issue-err.XXXXXX) || {
	echo "cr-plan: ERROR: mktemp failed while preparing gh stderr capture" >&2
	exit 2
}
# Single combined EXIT trap covers both issue_err (set now) and tmpdir
# (set later in parse path, empty otherwise). Both cleanups must run on
# every exit path so a subsequent trap below would replace this one and
# leak issue_err — instead, both targets share this trap from the start.
tmpdir=""
trap '[ -n "${tmpdir:-}" ] && rm -rf "${tmpdir}"; rm -f "${issue_err:-}"' EXIT
issue_json=$(gh issue view "$issue" --json number,labels,title 2>"$issue_err") || {
	echo "cr-plan: ERROR: cannot resolve issue #$issue (doesn't exist or auth issue):" >&2
	cat "$issue_err" >&2
	exit 2
}

case "$cmd" in
trigger)
	# Skip only on operator opt-out (no-plan). plan-me being already present is
	# the common ai-triage auto-applied path — still apply the label idempotently,
	# but ONLY post the @coderabbitai plan comment when plan-me was newly added
	# (retry-safety: re-running trigger on already-planned issues would otherwise
	# spam duplicate planner runs).
	if echo "$issue_json" | jq -e '.labels[] | select(.name == "no-plan")' >/dev/null 2>&1; then
		echo "cr-plan: issue #$issue has no-plan label — operator opted out, skipping" >&2
		exit 2
	fi
	had_plan_me=0
	if echo "$issue_json" | jq -e '.labels[] | select(.name == "plan-me")' >/dev/null 2>&1; then
		had_plan_me=1
	fi
	# Idempotent label add — gh issue edit --add-label is a no-op if already present.
	gh issue edit "$issue" --add-label "plan-me" >/dev/null || {
		echo "cr-plan: ERROR: gh issue edit --add-label plan-me failed for #$issue" >&2
		exit 2
	}
	comment_status="skipped (plan-me already present; CR planner already triggered)"
	if [ "$had_plan_me" -eq 0 ]; then
		gh issue comment "$issue" --body "@coderabbitai plan" >/dev/null || {
			echo "cr-plan: ERROR: gh issue comment failed for #$issue" >&2
			exit 2
		}
		comment_status="@coderabbitai plan posted"
	fi
	cat <<EOF
✓ cr-plan trigger applied to issue #$issue
  - Label: plan-me added (or already present)
  - Comment: $comment_status

CR will post a structured plan comment in 5-10 min. When ready:
  - Review plan: gh issue view $issue --comments
  - Auto-create epic+subs: APPROVE=1 .claude/skills/cr-plan/run.sh parse $issue
EOF
	;;
parse)
	if [ "${APPROVE:-0}" != "1" ]; then
		echo "cr-plan: parse refuses without APPROVE=1 (non-interactive guard)" >&2
		echo "  Re-run: APPROVE=1 cr-plan parse $issue" >&2
		exit 2
	fi
	if ! echo "$issue_json" | jq -e '.labels[] | select(.name == "plan-me")' >/dev/null 2>&1; then
		echo "cr-plan: ERROR: issue #$issue lacks plan-me label" >&2
		echo "  Run: cr-plan trigger $issue first" >&2
		exit 2
	fi
	if [ ! -x "$EPIC_SKILL" ]; then
		echo "cr-plan: ERROR: github-epic-creation skill missing/not executable: $EPIC_SKILL" >&2
		exit 2
	fi
	# Anchored regex prevents impostor logins (e.g. "not-coderabbit-user") from
	# matching. Accepts: coderabbit, coderabbitai, coderabbit[bot], coderabbitai[bot].
	# NOTE: jq filter intentionally does NOT pre-filter on the plan-section
	# heading (`## Phases` OR `## Implementation Steps`) — that would make
	# the downstream shell validation + diagnostic dump (lines below)
	# unreachable. Filter ONLY by author; let shell validate the section
	# AND emit the full body for troubleshooting if the format drifts.
	# Guard the gh call with stderr capture (same pattern as the issue_json fetch).
	comments_err=$(mktemp -t cr-plan-comments-err.XXXXXX) || {
		echo "cr-plan: ERROR: mktemp failed while preparing comments stderr capture" >&2
		exit 2
	}
	# Extend the combined EXIT trap to also clean up $comments_err.
	# shellcheck disable=SC2064
	trap '[ -n "${tmpdir:-}" ] && rm -rf "${tmpdir}"; rm -f "${issue_err:-}" "${comments_err:-}"' EXIT
	plan_body=$(gh issue view "$issue" --json comments --jq \
		'[.comments[] | select(.author.login | test("^coderabbit(ai)?(\\[bot\\])?$"))] | last.body // empty' \
		2>"$comments_err") || {
		echo "cr-plan: ERROR: failed to fetch CR comments for #$issue:" >&2
		cat "$comments_err" >&2
		exit 2
	}
	if [ -z "$plan_body" ] || [ "$plan_body" = "null" ]; then
		echo "cr-plan: ERROR: no CR comment found on issue #$issue" >&2
		echo "  Did you run: cr-plan trigger $issue ?" >&2
		echo "  Wait 5-10 min for CR to post the plan." >&2
		exit 2
	fi
	issue_title=$(echo "$issue_json" | jq -r '.title')
	# Accept both '## Phases' and '## Implementation Steps' as the section
	# heading. Discovered via 2026-05-11 dogfood on #781: CR's actual plan
	# format uses 'Implementation Steps'. Keep both for forward-compat.
	if ! echo "$plan_body" | grep -qE '^## (Phases|Implementation Steps)[[:space:]]*$'; then
		echo "cr-plan: ERROR: plan comment on issue #$issue doesn't have a '## Phases' or '## Implementation Steps' section" >&2
		echo "  CR plan structure differs from expected. Full plan body follows:" >&2
		echo "" >&2
		echo "$plan_body" | head -200 >&2
		echo "" >&2
		echo "  Action: copy phase headings manually + invoke github-epic-creation skill directly." >&2
		exit 2
	fi
	# Extract Phases section: enter on FIRST `## Phases` OR `## Implementation
	# Steps`, exit on the next level-1 OR level-2 heading. `### Phase N: …`
	# sub-headings inside the section are kept (level-3 doesn't match the exit
	# patterns). The `done` flag prevents re-entry on duplicate section headings
	# (CR plan comments often embed the raw plan in a metadata chunk at the
	# bottom, producing a second '## Implementation Steps' that would otherwise
	# cause duplicate phase extraction). `next` after entry skips the entry line.
	phases_section=$(echo "$plan_body" | awk '
		/^## (Phases|Implementation Steps)[[:space:]]*$/ && !done { in_phases=1; done=1; next }
		in_phases && /^# / { in_phases=0 }
		in_phases && /^## / { in_phases=0 }
		in_phases { print }
	')
	if [ -z "$phases_section" ]; then
		echo "cr-plan: ERROR: '## Phases' / '## Implementation Steps' section was empty on issue #$issue" >&2
		exit 2
	fi
	# Primary: `### Phase N: …` / `**Phase N: …**` form. `|| true` keeps
	# pipefail/set-e from aborting on the no-match case so the fallback runs.
	# raw_count below detects oversized plans; truncation to PHASE_MAX is
	# applied unconditionally and warns when the raw count exceeds it.
	PHASE_MAX="${PHASE_MAX:-10}"
	phase_titles_raw=$({ echo "$phases_section" | grep -oE '^(###+|[*]{2})[[:space:]]*Phase[[:space:]]+[0-9]+:?[[:space:]]*[^*#]+' |
		sed -E 's/^[#*[:space:]]+Phase[[:space:]]+[0-9]+:?[[:space:]]*//' |
		sed -E 's/[*[:space:]]+$//'; } || true)
	if [ -z "$phase_titles_raw" ]; then
		# Fallback: `1. Foo\n2. Bar` numbered-list form.
		phase_titles_raw=$({ echo "$phases_section" | grep -oE '^[0-9]+\.[[:space:]]+[^[:space:]].*' |
			sed -E 's/^[0-9]+\.[[:space:]]+//'; } || true)
	fi
	if [ -z "$phase_titles_raw" ]; then
		echo "cr-plan: ERROR: couldn't extract phase titles from Phases / Implementation Steps section on #$issue" >&2
		echo "  Section content (first 50 lines):" >&2
		echo "$phases_section" | head -50 >&2
		echo "" >&2
		echo "  Action: copy phase headings manually + invoke github-epic-creation skill directly." >&2
		exit 2
	fi
	raw_count=$(echo "$phase_titles_raw" | wc -l | tr -d ' ')
	phase_titles=$(echo "$phase_titles_raw" | head -n "$PHASE_MAX")
	if [ "$raw_count" -gt "$PHASE_MAX" ]; then
		echo "cr-plan: WARN: CR plan has $raw_count phase(s); truncated to first $PHASE_MAX." >&2
		echo "  Manually split the epic into multiple sets if needed (phases ${PHASE_MAX}+ dropped)." >&2
	fi
	echo "cr-plan: parsed $(echo "$phase_titles" | wc -l | tr -d ' ') phase(s) from CR plan on #$issue:"
	echo "$phase_titles" | sed 's/^/  - /'
	echo ""
	tmpdir=$(mktemp -d -t cr-plan.XXXXXX) || {
		echo "cr-plan: ERROR: mktemp -d failed (TMPDIR unwritable?)" >&2
		exit 2
	}
	# tmpdir cleanup is handled by the combined EXIT trap set near the top
	# (which also removes $issue_err); no separate trap here would only
	# overwrite that trap and leak issue_err.
	epic_body_file="$tmpdir/epic-body.md"
	# Epic body must satisfy .github/ISSUE_TEMPLATE/epic.yml (7 required
	# sections: Area, Goal, Scope, Sub-issues, Acceptance criteria,
	# Rollout plan, Rollback plan). Sections are populated with concrete
	# context derived from the source issue + CR plan; operator can edit
	# post-creation to refine wording.
	cat >"$epic_body_file" <<EOF
Epic auto-created from CodeRabbit plan on issue #$issue.

## Area

area:infrastructure (default; operator: adjust if scope spans different area — not auto-inherited from source issue #$issue because per-phase scope can diverge from the parent's area label)

## Goal

Implement the CodeRabbit plan for #$issue by decomposing the work into linked sub-issues. See parent issue + CR plan comment for the WHY and acceptance specifics.

## Scope

In-scope: each phase below becomes a tracked sub-issue with its own implementation + tests.
Out of scope: anything not enumerated in the CR plan's phases (file follow-up issues if discovered mid-implementation).

## Sub-issues

(GitHub renders the sub-issue checklist + progress bar from the addSubIssue GraphQL linkage that github-epic-creation establishes; no body-side checklist is generated by this skill — \`gh issue view\` will show the sub-issues panel automatically)

## Acceptance criteria

- Each sub-issue completes its phase per the CR plan + lands a merged PR
- This epic auto-closes when all sub-issues close (via auto-close-parent.yml)
- Source issue #$issue closes when the implementation lands

## Rollout plan

Sequential per phase order — phase N+1 depends on phase N. Each sub-issue follows the standard ship-pr-cycle (branch → build → test → CR review → merge).

## Rollback plan

Each phase merges as an independent commit. \`git revert <sha>\` per phase. The CR plan + this epic body remain as the design record.

## Phases (from CR plan)

$phases_section

---

Original issue: #$issue
CR plan comment: \`gh issue view $issue --comments\`
EOF
	# v4.30 (#779 PR1): pass --parent $issue so the created epic is linked
	# AS A SUB-ISSUE of the source issue. Without this, the source-issue →
	# epic edge is text-only ("auto-created from CodeRabbit plan on issue
	# #$issue") and auto-close-parent.sh can't cascade source closure when
	# the epic closes — see #807 + #785/#781 retrofit precedent.
	skill_args=(--title "EPIC: $issue_title (#$issue)" --body-file "$epic_body_file" --parent "$issue")
	idx=0
	while IFS= read -r ptitle; do
		[ -z "$ptitle" ] && continue
		idx=$((idx + 1))
		# Index prefix prevents silent overwrite when two phases share the first
		# 40 normalized chars (head -c truncation) and would collide on filename.
		sub_slug=$(echo "$ptitle" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g;s/^-|-$//g' | head -c 40)
		sub_body_file="$tmpdir/sub-$(printf '%02d' "$idx")-${sub_slug}.md"
		# Sub-issue body covers Area + Description + Context. The task
		# template requires Parent epic; github-epic-creation establishes
		# the parent linkage via the addSubIssue GraphQL mutation, so the
		# body-side `## Parent epic` section is satisfied by that linkage
		# (gh issue view shows the parent regardless of body markdown).
		cat >"$sub_body_file" <<SUBEOF
Sub-issue auto-created from CodeRabbit plan on epic for #$issue.

## Area

area:infrastructure (default; operator: adjust if scope differs — not auto-inherited from source issue #$issue because per-phase scope can diverge from the parent's area label)

## Description

Phase: **$ptitle**

Implements this phase of the CodeRabbit plan for #$issue. See parent epic + CR plan comment (\`gh issue view $issue --comments\`) for the WHY and acceptance specifics.

## Context

Auto-generated by \`cr-plan parse $issue\`. Refer to parent epic for sequencing + the CR plan for implementation details.
SUBEOF
		skill_args+=(--sub-title "$ptitle" --sub-body-file "$sub_body_file")
	done <<<"$phase_titles"
	echo "cr-plan: invoking github-epic-creation skill..."
	APPROVE=1 "$EPIC_SKILL" "${skill_args[@]}"
	;;
*)
	echo "cr-plan: ERROR: unknown subcommand '$cmd'" >&2
	usage >&2
	exit 2
	;;
esac
