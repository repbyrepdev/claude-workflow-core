#!/bin/bash
set -euo pipefail
# v4.20 (#519): github-issue-creation skill wrapper.
# Creates a GitHub issue from a template, applies area/priority labels,
# attaches active milestone, optionally links as sub-issue to a parent,
# runs ai-triage + project-board-sync during cap-deferral, and verifies.
#
# v4.28-W3-CD (#746): when no --body-file is supplied, the wrapper auto-
# drafts the issue body via Copilot free-tier from the template schema.
# Mirrors the pattern from #743 (git-commit) + #745 (github-pr-creation).
# Fail-closed rc=4 when the drafted body violates the template's
# required sections.
#
# Opt-out:
#   --no-copilot               (per-invocation flag)
#   COPILOT_DRAFT_OFF=1        (env var, useful for trusted-edit flows)
#   --body-file <path>         (explicit body takes precedence over draft)
#
# Usage:
#   .claude/skills/github-issue-creation/run.sh --template <bug|feature|task> \
#     --title "<title>" --body-file <path> [--label "<label>"]... \
#     [--milestone <title>] [--parent <issue-num>] [--assignee @me]
#   .claude/skills/github-issue-creation/run.sh --template task \
#     --title "<title>" --parent N    # auto-draft body via Copilot
#
# Exit codes:
#   0 — issue created
#   2 — arg / validation error
#   3 — Copilot-default attempted but unavailable + no fallback body
#   4 — Copilot-drafted body failed required-section preflight
#       (.github/ISSUE_TEMPLATE/<template>.yml SSOT)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_lib/skill-common.sh
source "$SCRIPT_DIR/../_lib/skill-common.sh"
# Export SKILL_WRAPPER=1 once near top so ALL guarded calls (the early
# git rev-parse below, sourced helpers, gh issue create) consistently
# satisfy skill-bypass-guard. Prior code only exported on the Copilot
# path, leaving early git operations unguarded.
export SKILL_WRAPPER=1
# Capture caller's cwd before cd-to-repo-root so relative --body-file
# paths resolve against the operator's invocation dir (not REPO_ROOT).
ORIG_CWD=$(pwd)
# Resolve REPO_ROOT from caller's repo (not script's) — required for
# bats fixtures + general consistency with git-commit / github-pr-creation
# wrappers.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "error: not in a git repo" >&2
	exit 2
}
cd "$REPO_ROOT" || {
	echo "error: cannot cd to repo root '$REPO_ROOT'" >&2
	exit 2
}

TEMPLATE=""
TITLE=""
BODY_FILE=""
MILESTONE=""
MILESTONE_EXPLICIT=0
PARENT=""
ASSIGNEE=""
LABELS=()
NO_COPILOT=0
BODY_FROM_COPILOT=0

while [ $# -gt 0 ]; do
	case "$1" in
	--template)
		[ $# -ge 2 ] || {
			echo "error: --template requires a value" >&2
			exit 2
		}
		TEMPLATE="$2"
		shift 2
		;;
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
		# Absolutize relative paths against caller's ORIG_CWD.
		case "$2" in
		/*) BODY_FILE="$2" ;;
		*) BODY_FILE="$ORIG_CWD/$2" ;;
		esac
		shift 2
		;;
	--no-copilot)
		NO_COPILOT=1
		shift
		;;
	--milestone)
		[ $# -ge 2 ] || {
			echo "error: --milestone requires a value" >&2
			exit 2
		}
		MILESTONE="$2"
		MILESTONE_EXPLICIT=1
		shift 2
		;;
	--parent)
		[ $# -ge 2 ] || {
			echo "error: --parent requires a value" >&2
			exit 2
		}
		PARENT="$2"
		shift 2
		;;
	--assignee)
		[ $# -ge 2 ] || {
			echo "error: --assignee requires a value" >&2
			exit 2
		}
		ASSIGNEE="$2"
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
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ -z "$TEMPLATE" ] || [ -z "$TITLE" ]; then
	echo "Usage: $0 --template <bug|feature|task|epic> --title <title> [--body-file <path>] [--no-copilot] [--label ...] [--milestone ...] [--parent ...] [--assignee ...]" >&2
	echo "Note: --parent is REQUIRED for bug/feature/task; epics have no parent." >&2
	echo "Note: --body-file is optional — Copilot-default auto-drafts when omitted (v4.28-W3-CD #746)." >&2
	exit 2
fi

if [ "${COPILOT_DRAFT_OFF:-0}" = "1" ]; then
	NO_COPILOT=1
fi

# v4.28-W2 (#646): mechanical enforcement — sub-issue templates (bug,
# feature, task) MUST link to a parent epic. Without this, sub-issues
# orphan into Backlog with no epic-progress correlation. Past misses
# (#526 board-field skip class) followed the same shape: optional
# polish step, skipped under pressure. Make it not optional.
case "$TEMPLATE" in
bug | feature | task)
	if [ -z "$PARENT" ]; then
		echo "error: --parent <issue-num> is required for --template $TEMPLATE." >&2
		echo "Sub-issues must link to their parent epic. If this is genuinely standalone (no epic exists yet), file an epic first via --template epic." >&2
		exit 2
	fi
	if ! [[ "$PARENT" =~ ^[0-9]+$ ]]; then
		echo "error: --parent must be a numeric issue number (got: $PARENT)" >&2
		exit 2
	fi
	;;
epic)
	if [ -n "$PARENT" ]; then
		echo "error: --parent is not valid for --template epic — epics are top-level, not sub-issues." >&2
		exit 2
	fi
	;;
esac

# TEMPLATE is used for caller-intent validation + body-shape guidance,
# NOT passed to gh. `gh issue create --template X --body-file Y` errors
# ("cannot use both"); we use --body-file so caller supplies the rendered
# body whose shape should follow the named template's structure. Server-
# side, ai-triage.yml applies type-label-from-template-frontmatter only
# when the issue was opened via the template picker, which this wrapper
# isn't — caller or ai-triage must add the type label explicitly.
case "$TEMPLATE" in
bug | feature | task | epic) ;;
*)
	echo "--template must be one of: bug, feature, task, epic (got: $TEMPLATE)" >&2
	exit 2
	;;
esac

# Body resolution precedence:
#   1. --body-file (explicit override)
#   2. Copilot-draft DEFAULT (when no body-file + not opted out)
#   3. Refuse rc=2 when Copilot opt-out + no fallback
#   4. Refuse rc=3 when Copilot unavailable + not opted out
if [ -n "$BODY_FILE" ]; then
	if [ ! -f "$BODY_FILE" ]; then
		echo "--body-file not found: $BODY_FILE" >&2
		exit 2
	fi
elif [ "$NO_COPILOT" = "1" ]; then
	echo "error: no --body-file provided + --no-copilot/COPILOT_DRAFT_OFF=1 set" >&2
	echo "  hint: pass --body-file <path>, or remove --no-copilot to use Copilot-default" >&2
	exit 2
else
	COPILOT_HELPER="$REPO_ROOT/.claude/scripts/copilot/try-free.sh"
	if [ ! -x "$COPILOT_HELPER" ]; then
		echo "error: Copilot-draft default unavailable — $COPILOT_HELPER missing/non-executable" >&2
		echo "  hint: pass --body-file, or set COPILOT_DRAFT_OFF=1 + provide one" >&2
		exit 3
	fi
	TPL_FILE="$REPO_ROOT/.github/ISSUE_TEMPLATE/${TEMPLATE}.yml"
	if [ -f "$TPL_FILE" ]; then
		TPL_TEXT=$(cat "$TPL_FILE") || {
			echo "error: cannot read $TPL_FILE (rc=$?)" >&2
			exit 2
		}
	else
		TPL_TEXT="(template ${TEMPLATE}.yml unavailable)"
	fi
	echo "drafting issue body via Copilot free-tier (template=$TEMPLATE)…" >&2
	DRAFT_DIR=$(mktemp -d -t issue-body.XXXXXX) || {
		echo "error: mktemp -d failed (disk full? /tmp permissions?)" >&2
		exit 3
	}
	trap 'rm -rf "${DRAFT_DIR:-}"' EXIT
	BODY_TMP="$DRAFT_DIR/body"
	ERR_TMP="$DRAFT_DIR/err"
	COPILOT_RC=0
	"$COPILOT_HELPER" "Draft a GitHub issue body for the '$TEMPLATE' template. Title: $TITLE. The body MUST mirror this template's required-section structure exactly (use '## Section' or '**Section:**' headers): $TPL_TEXT. Output the body only (no preamble, no trailing notes). Required area label values are: monitoring, infrastructure, security, performance — pick the most relevant in the Area section." \
		>"$BODY_TMP" 2>"$ERR_TMP" || COPILOT_RC=$?
	grep_rc=0
	grep -q '[^[:space:]]' "$BODY_TMP" || grep_rc=$?
	if [ "$grep_rc" -gt 1 ]; then
		echo "error: cannot read draft body (grep rc=$grep_rc) — disk fault?" >&2
		exit 3
	fi
	if [ "$COPILOT_RC" -ne 0 ] || [ "$grep_rc" -eq 1 ]; then
		echo "error: Copilot draft returned empty/whitespace (rc=$COPILOT_RC) — auth/network/quota issue?" >&2
		if [ -s "$ERR_TMP" ]; then
			echo "  helper stderr:" >&2
			while IFS= read -r line; do echo "    $line" >&2; done <"$ERR_TMP"
		fi
		echo "  hint: pass --body-file, or set COPILOT_DRAFT_OFF=1 + provide one" >&2
		exit 3
	fi
	BODY_FILE="$BODY_TMP"
	BODY_FROM_COPILOT=1
fi

# v4.23-P (#562): require body to contain the template's declared
# required sections (per .github/ISSUE_TEMPLATE/*.yml validations.required).
# Prevents format breaches like this session's #521 (sub-issues listed
# as prose bullets, missing Acceptance/Rollout/Rollback sections).
#
# Section header detection is flexible — matches `## Header` or
# `**Header:**` / `**Header**` forms. Case-sensitive on the keyword.
#
# Required BODY-SECTION headers per template (derived from
# .github/ISSUE_TEMPLATE/*.yml validations.required text-fields). The
# `parent` field added in v4.28-W2 (#646) is required at the wrapper-arg
# level (--parent flag, validated above), NOT in the rendered body — so
# it does not appear in this list. Body-shape contract:
#   epic:    Area, Goal, Scope, Sub-issues, Acceptance criteria, Rollout plan, Rollback plan
#   task:    Area, What needs to be done (the "Description" required-textarea)
#   bug:     Area, What's happening?
#   feature: Area, What do you want?
_required_sections_for_template() {
	case "$1" in
	epic) echo "Area|Goal|Scope|Sub-issues|Acceptance criteria|Rollout plan|Rollback plan" ;;
	task) echo "Area|What needs to be done" ;;
	bug) echo "Area|What's happening?" ;;
	feature) echo "Area|What do you want?" ;;
	esac
}

REQUIRED=$(_required_sections_for_template "$TEMPLATE")
if [ -n "$REQUIRED" ]; then
	missing=""
	IFS='|' read -ra _sections <<<"$REQUIRED"
	for section in "${_sections[@]}"; do
		# Match `## Section`, `**Section:**`, or `**Section?**` at line start.
		# `What needs to be done?` has a trailing `?` in the canonical form;
		# escape the regex special char.
		# Section name must be followed by end-of-line or non-word separator to
		# prevent prefix matches (e.g., "## Area details" matching "Area").
		esc_section=$(printf '%s' "$section" | sed 's/[][\\.*^$(){}?+|]/\\&/g')
		# Section name must be followed by EOL or literal ':' to prevent
		# prefix false-positives ("## Area details" matching "Area").
		if ! grep -qE "^(##[[:space:]]+${esc_section}(\?)?($|:)|\*\*${esc_section}(\?)?:?\*\*)" "$BODY_FILE"; then
			missing="${missing}
  - ${section}"
		fi
	done
	if [ -n "$missing" ]; then
		# Copilot-drafted bodies fail-closed at rc=4 (don't create an
		# issue with a bad body). Operator-supplied bodies stay rc=2.
		if [ "$BODY_FROM_COPILOT" = "1" ]; then
			echo "error: Copilot-drafted issue body failed required-section preflight — refusing to create." >&2
			echo "missing section(s):$missing" >&2
			echo "  hint: re-run + Copilot will redraft, or pass --body-file with a fixed body." >&2
			exit 4
		fi
		echo "error: $TEMPLATE body missing required section(s):$missing" >&2
		echo "" >&2
		echo ".github/ISSUE_TEMPLATE/${TEMPLATE}.yml requires: $(_required_sections_for_template "$TEMPLATE" | tr '|' ',')" >&2
		echo "Use '## Header' or '**Header:**' form. See the template YAML for canonical schema." >&2
		exit 2
	fi
fi

# Auto-resolve milestone from active branch's version prefix if not given.
# Loud-fail on resolution errors: "no version on branch" is fine, but
# "version present, resolution failed" is hidden silent-failure we don't want.
if [ -z "$MILESTONE" ] && [ "$MILESTONE_EXPLICIT" -eq 0 ]; then
	ver=$(skc_extract_version_prefix)
	if [ -n "$ver" ]; then
		if ! MILESTONE=$(skc_match_milestone "$ver" 2>&1); then
			echo "milestone auto-resolve failed for prefix '$ver':" >&2
			echo "$MILESTONE" >&2
			echo "Re-run with explicit --milestone <title> or accept the (none) by passing --milestone ''." >&2
			exit 2
		fi
	fi
fi

# Show plan for approval.
echo "=== Creating issue ==="
echo "  Template: $TEMPLATE"
echo "  Title:    $TITLE"
echo "  Body:     $BODY_FILE"
echo "  Labels:   ${LABELS[*]:-(none)}"
echo "  Milestone: ${MILESTONE:-(none)}"
echo "  Parent:    ${PARENT:-(none)}"
echo "  Assignee:  ${ASSIGNEE:-(none)}"
echo ""
skc_approve_or_exit "Create this issue?"

# Build gh args array.
GH_ARGS=(issue create --title "$TITLE" --body-file "$BODY_FILE")
for l in "${LABELS[@]+"${LABELS[@]}"}"; do GH_ARGS+=(--label "$l"); done
[ -n "$MILESTONE" ] && GH_ARGS+=(--milestone "$MILESTONE")

# Create — set SKILL_WRAPPER=1 so skill-bypass-guard allows the call.
URL=$(SKILL_WRAPPER=1 gh "${GH_ARGS[@]}")
NEW_NUM=$(printf '%s' "$URL" | grep -oE '[0-9]+$')
if ! [[ "$NEW_NUM" =~ ^[0-9]+$ ]]; then
	echo "Failed to parse issue number from: $URL" >&2
	exit 2
fi
echo "✓ Created issue #$NEW_NUM ($URL)"

# Optional: link to parent via GraphQL.
if [ -n "$PARENT" ]; then
	echo "Linking #$NEW_NUM as sub-issue of #$PARENT..."
	skc_graphql_add_sub_issue "$NEW_NUM" "$PARENT"
	echo "✓ Linked as sub-issue"
fi

# Optional: self-assign + fire Status=In Progress board transition.
BOARD_SYNC="$REPO_ROOT/.claude/local-backups/project-board-sync.sh"
if [ -n "$ASSIGNEE" ]; then
	SKILL_WRAPPER=1 gh issue edit "$NEW_NUM" --add-assignee "$ASSIGNEE" >/dev/null
	if [ -x "$BOARD_SYNC" ]; then
		# Surface failures — silent-swallow here re-introduces #526.
		if ! "$BOARD_SYNC" --on-assign "$NEW_NUM" 2>&1; then
			echo "⚠ project-board-sync --on-assign #$NEW_NUM failed — board Status not updated." >&2
			echo "  Re-run manually: $BOARD_SYNC --on-assign $NEW_NUM" >&2
		fi
	fi
fi

# Cap-deferral: run ai-triage + project-board-sync if workflows are disabled.
# ai-triage.sh prints a classification prompt for Claude to read — the wrapper
# surfaces it (doesn't just print a reminder). After Claude applies labels,
# run project-board-sync.sh to dual-write to the board.
#
# Phase 1 r1 silent-failure-hunter (#646): the prior `! "$DETECT" >/dev/null
# 2>&1` discarded both stdout AND stderr — if DETECT errored for an
# unrelated reason (gh auth missing, network failure), the wrapper would
# branch into cap-deferral logic blindly. Capture stderr + show on non-
# zero so the operator knows whether cap-deferral fired because the cap
# is real or because DETECT itself broke.
DETECT="$REPO_ROOT/.claude/hooks/detect-actions-cap.sh"
DETECT_STDERR=""
DETECT_RC=0
if [ -x "$DETECT" ]; then
	DETECT_STDERR=$("$DETECT" 2>&1 >/dev/null) || DETECT_RC=$?
	if [ "$DETECT_RC" -ne 0 ] && [ -n "$DETECT_STDERR" ]; then
		# Non-zero rc with stderr usually means DETECT ran and reported
		# cap=active (its contract). But surface the stderr to operator
		# so they can spot the rare "DETECT itself broke" case.
		echo "ℹ detect-actions-cap.sh stderr (cap-active or detect-error):" >&2
		printf '%s\n' "$DETECT_STDERR" >&2
	fi
fi
if [ -x "$DETECT" ] && [ "$DETECT_RC" -ne 0 ]; then
	AI_TRIAGE="$REPO_ROOT/.claude/local-backups/ai-triage.sh"
	if [ -x "$AI_TRIAGE" ]; then
		# v4.30 #810/#844: prefer --apply-act (run actual ai-triage.yml
		# via act → exact parity with cloud-side CI) when Docker daemon
		# is running. ai-triage.sh internally falls back to
		# --apply-heuristic if act/docker/keychain unavailable, so a
		# single call here covers all paths. We only choose --apply-act
		# vs --apply-cli vs --apply-heuristic at the SKILL level based on
		# what's likely fastest+highest-fidelity.
		#
		# v4.30 #809: --apply-cli (claude -p with workflow prompt) was
		# the prior default. --apply-act supersedes when Docker is
		# available because it runs the EXACT workflow definition (no
		# prompt approximation drift). Latency: ~30-60s for act vs
		# ~3-5s for cli/heuristic — acceptable for issue creation
		# (non-interactive cap-deferral flow).
		# v4.30 #868 CR-CLI r1: docker alone isn't enough — `--apply-act`
		# also requires the `act` binary AND macOS Keychain access. On
		# a Docker-capable Linux box without `act` installed, picking
		# --apply-act here would skip the CLI path and fall straight to
		# heuristic (worst-of-both). Check all 3 prerequisites.
		if docker info >/dev/null 2>&1 &&
			command -v act >/dev/null 2>&1 &&
			[ "$(uname -s)" = "Darwin" ]; then
			echo "=== Cap-deferral: running ai-triage --apply-act (Docker + act + macOS Keychain available) ==="
			TRIAGE_MODE="--apply-act"
		else
			echo "=== Cap-deferral: running ai-triage --apply-cli (act/docker/keychain unavailable, fallback to claude CLI) ==="
			TRIAGE_MODE="--apply-cli"
		fi
		"$AI_TRIAGE" "$TRIAGE_MODE" "$NEW_NUM" || {
			echo "⚠ ai-triage.sh failed on #$NEW_NUM — apply labels + run board-sync manually." >&2
		}
		if [ -x "$BOARD_SYNC" ]; then
			echo "=== Cap-deferral: running project-board-sync ==="
			if ! "$BOARD_SYNC" "$NEW_NUM" 2>&1; then
				echo "⚠ project-board-sync.sh failed on #$NEW_NUM — re-run manually: $BOARD_SYNC $NEW_NUM" >&2
			fi
		fi
	fi
fi

# Verify.
SKILL_WRAPPER=1 gh issue view "$NEW_NUM" --json number,title,labels,milestone \
	--jq '"#\(.number) \(.title) | labels=\(.labels | map(.name)) | milestone=\(.milestone.title // "none")"'
printf '%s\n' "$NEW_NUM"
