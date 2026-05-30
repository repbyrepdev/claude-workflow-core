#!/bin/bash
set -euo pipefail
# v4.20 (#519): github-pr-creation skill wrapper.
# Creates a PR with auto-resolved template body + labels + milestone.
# Sets SKILL_WRAPPER=1 so skill-bypass-guard allows gh pr create.
#
# v4.28-W3-CD (#745): when no --body-file supplied, the wrapper auto-drafts
# the PR body via Copilot free-tier (gpt-4.1 / gpt-5-mini / gpt-4o, 0×
# premium multiplier on Enterprise seats). Mirrors the pattern from #743
# (git-commit Copilot-default). Drafts go through pr-lint-check.sh as
# preflight; fail-closed rc=4 when the SSOT schema isn't satisfied.
#
# Opt-out:
#   --no-copilot               (per-invocation flag)
#   COPILOT_DRAFT_OFF=1        (env var, useful for trusted-edit flows)
#   --body-file <path>         (explicit body takes precedence over draft)
#
# Usage:
#   .claude/skills/github-pr-creation/run.sh --title "<title>" \
#     --body-file <path> [--label "<label>"]... [--milestone <title>] \
#     [--base <branch>] [--draft]
#   .claude/skills/github-pr-creation/run.sh --title "<title>"     # auto-draft
#   .claude/skills/github-pr-creation/run.sh --no-copilot --body-file ...
#
# Exit codes:
#   0 — PR created
#   2 — arg / validation error
#   3 — Copilot-default attempted but unavailable + no fallback body
#       (use --body-file or set COPILOT_DRAFT_OFF=1 + provide one)
#   4 — Copilot-drafted body failed pr-lint preflight (.github/pull_request_template.md
#       SSOT). Operator-supplied bodies stay warn-only.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../_lib/skill-common.sh
# Source library from SCRIPT_DIR (always relative to script — bundled with
# the skill itself, never relocates).
source "$SCRIPT_DIR/../_lib/skill-common.sh"
# Capture caller's cwd before cd-to-repo-root so relative --body-file
# paths resolve against the operator's invocation dir (not REPO_ROOT).
ORIG_CWD=$(pwd)
# Resolve REPO_ROOT from caller's repo (not script's) so fixtures can
# override .github/.claude paths during tests, and so the wrapper
# operates on whatever repo the operator invoked it from.
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
BASE="main"
DRAFT=0
LABELS=()
NO_COPILOT=0
BODY_FROM_COPILOT=0

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
		# Absolutize relative paths against caller's ORIG_CWD (we
		# already cd'd to REPO_ROOT above).
		case "$2" in
		/*) BODY_FILE="$2" ;;
		*) BODY_FILE="$ORIG_CWD/$2" ;;
		esac
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
	--base)
		[ $# -ge 2 ] || {
			echo "error: --base requires a value" >&2
			exit 2
		}
		BASE="$2"
		shift 2
		;;
	--draft)
		DRAFT=1
		shift
		;;
	--no-copilot)
		NO_COPILOT=1
		shift
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

# #122: feature-branch SSOT prereqs (branch name + issue exists + issue
# has priority:* + area:* labels) verified at PR-creation time. The
# delegate is `meta-bootstrap.sh --target feature-branch` — same rules
# the operator should have hit at branch-create time, re-fired here so
# a non-conventional branch can't reach GitHub. PR_BRANCH_VERIFY_SKIP=1
# bypasses + audit-logs (e.g., hotfix branches with non-standard names).
#
# Fail-closed when meta-bootstrap.sh is missing/non-exec: silently
# skipping would defeat the gate. Per feedback_build_infra_dont_skip:
# missing infra fails-closed and forces install.
if [ "${PR_BRANCH_VERIFY_SKIP:-0}" = "1" ]; then
	echo "warn: PR_BRANCH_VERIFY_SKIP=1 — feature-branch SSOT verify bypassed" >&2
	_skip_log="$REPO_ROOT/.claude/logs/dogfood-gate-skip.jsonl"
	mkdir -p "$(dirname "$_skip_log")" 2>/dev/null || true
	jq -nc --arg ts "$(date -u +%FT%TZ)" --arg env "PR_BRANCH_VERIFY_SKIP" \
		--arg wrapper "github-pr-creation" \
		'{ts:$ts, env:$env, wrapper:$wrapper}' >>"$_skip_log" 2>/dev/null || true
else
	if [ ! -x "$REPO_ROOT/scripts/meta-bootstrap.sh" ]; then
		echo "error: scripts/meta-bootstrap.sh missing/non-exec — cannot verify branch convention" >&2
		echo "  fix: install plugin meta-bootstrap, or set PR_BRANCH_VERIFY_SKIP=1 (audit-logged)" >&2
		exit 3
	fi
	_verify_err=$(mktemp -t feature-branch-verify-err.XXXXXX) || _verify_err=""
	if ! "$REPO_ROOT/scripts/meta-bootstrap.sh" --target feature-branch >/dev/null 2>"${_verify_err:-/dev/null}"; then
		echo "error: feature-branch SSOT verify failed — refusing to open PR" >&2
		if [ -n "$_verify_err" ] && [ -s "$_verify_err" ]; then
			echo "  details:" >&2
			head -20 "$_verify_err" | sed 's/^/    /' >&2
		fi
		echo "  override: PR_BRANCH_VERIFY_SKIP=1 (audit-logged)" >&2
		[ -n "$_verify_err" ] && rm -f "$_verify_err"
		exit 2
	fi
	[ -n "$_verify_err" ] && rm -f "$_verify_err"
fi

# v4.28-W3-C (#662): no-arg auto-fill for title (derive from latest
# commit subject) so `run.sh` matches SKILL.md's auto-flow promise.
if [ -z "$TITLE" ]; then
	commit_subject=$(git log -1 --format=%s 2>/dev/null || echo "")
	if [ -n "$commit_subject" ]; then
		TITLE="$commit_subject"
		echo "auto-filled --title from HEAD commit: $TITLE" >&2
	fi
fi

if [ -z "$TITLE" ]; then
	echo "Usage: $0 [--title <title>] [--body-file <path>] [--no-copilot] [--label ...] [--milestone ...] [--base main] [--draft]" >&2
	echo "  --title is auto-derived from HEAD commit subject when omitted." >&2
	echo "  --body-file is optional — Copilot-default auto-drafts when omitted (v4.28-W3-CD #745)." >&2
	exit 2
fi

if [ "${COPILOT_DRAFT_OFF:-0}" = "1" ]; then
	NO_COPILOT=1
fi

# Body resolution precedence:
#   1. --body-file (explicit override)
#   2. Copilot-draft DEFAULT (when no body-file + not opted out)
#   3. Refuse with rc=2 when Copilot opt-out + no fallback
#   4. Refuse with rc=3 when Copilot unavailable + not opted out
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
	# Copilot-draft path. Refuse on unavailability or empty output.
	COPILOT_HELPER="$REPO_ROOT/.claude/scripts/copilot/try-free.sh"
	if [ ! -x "$COPILOT_HELPER" ]; then
		echo "error: Copilot-draft default unavailable — $COPILOT_HELPER missing/non-executable" >&2
		echo "  hint: pass --body-file, or set COPILOT_DRAFT_OFF=1 + provide one" >&2
		exit 3
	fi
	# Validate BASE exists + isn't ambiguous. Use refs/heads/ prefix to
	# disambiguate when both branch + tag share the name. Quiet output
	# so the warning suppression lands cleanly.
	if ! git rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null 2>&1 &&
		! git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
		echo "error: base ref '$BASE' not found locally — run: git fetch origin $BASE" >&2
		echo "  hint: or pass a different --base, or pass --body-file directly" >&2
		exit 2
	fi
	PR_TEMPLATE="$REPO_ROOT/.github/pull_request_template.md"
	# Distinguish "template missing" (acceptable, fall back to
	# placeholder) from "template exists but unreadable" (loud-fail —
	# repo state corrupted). Without this split, EACCES/EIO get masked
	# and Copilot drafts against the literal "(unavailable)" string.
	if [ -f "$PR_TEMPLATE" ]; then
		TEMPLATE_TEXT=$(cat "$PR_TEMPLATE") || {
			echo "error: cannot read $PR_TEMPLATE (rc=$?)" >&2
			exit 2
		}
	else
		TEMPLATE_TEXT="(pull_request_template.md unavailable)"
	fi
	echo "drafting PR body via Copilot free-tier…" >&2
	# Single mktemp -d for body + stderr; one trap, one cleanup. Closes
	# the trap-window between successive mktemps + drops the manual
	# rm-on-second-failure dance.
	DRAFT_DIR=$(mktemp -d -t pr-body.XXXXXX) || {
		echo "error: mktemp -d failed (disk full? /tmp permissions?)" >&2
		exit 3
	}
	trap 'rm -rf "${DRAFT_DIR:-}"' EXIT
	BODY_TMP="$DRAFT_DIR/body"
	ERR_TMP="$DRAFT_DIR/err"
	# Capture diff to a file FIRST (separate from the helper pipeline)
	# so a diff failure is attributed to the BASE...HEAD spec, not to
	# the Copilot helper.
	DIFF_TMP="$DRAFT_DIR/diff"
	if ! git diff "$BASE...HEAD" >"$DIFF_TMP" 2>"$DRAFT_DIR/diff-err"; then
		diff_rc=$?
		echo "error: git diff '$BASE...HEAD' failed (rc=$diff_rc)" >&2
		if [ -s "$DRAFT_DIR/diff-err" ]; then
			echo "  git diff stderr:" >&2
			while IFS= read -r line; do echo "    $line" >&2; done <"$DRAFT_DIR/diff-err"
		fi
		echo "  hint: ensure --base is a valid ref relative to HEAD" >&2
		exit 2
	fi
	# SKILL_WRAPPER export so nested gh/git in try-free.sh satisfies
	# skill-bypass-guard.
	export SKILL_WRAPPER=1
	COPILOT_RC=0
	"$COPILOT_HELPER" "Draft a GitHub PR body for this diff: $(cat "$DIFF_TMP"). Mirror this template's section structure exactly: $TEMPLATE_TEXT. Output the full body only (no preamble, no trailing notes). Include 'Closes #<issue>' line at the bottom referencing the issue from the branch name (feat/vX.Y-Z/NNN-...). Required area label must match the change scope (monitoring|infrastructure|security|performance) — must stay in sync with .github/labels.yml SSOT." \
		>"$BODY_TMP" 2>"$ERR_TMP" || COPILOT_RC=$?
	# Distinguish grep rc=1 (legitimate empty/whitespace) from rc>1
	# (read error / IO fault) — without the explicit case the operator
	# loops on a misdiagnosed Copilot failure when the real cause is
	# disk fault.
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

# Auto-resolve milestone from current branch's version prefix. Loud-fail
# on resolution errors (ambiguity, gh failure) — silent-swallow of these
# is the bug that creates issues/PRs with no milestone attached.
#
# #121: when no milestone matches the version prefix, AUTO-CREATE one
# instead of refusing — the previous behavior forced operators to either
# pass --milestone explicitly OR pre-create via the GitHub UI mid-flow,
# both of which add friction the wrapper can eliminate.
# Override path: PR_MILESTONE_AUTO_CREATE_SKIP=1 keeps strict refuse
# behavior (polarity consistent with the other dogfood-gate SKIP envs).
if [ -z "$MILESTONE" ]; then
	ver=$(skc_extract_version_prefix)
	if [ -n "$ver" ]; then
		_milestone_err=$(mktemp -t milestone-err.XXXXXX)
		# Compose with any existing EXIT trap (e.g., Copilot DRAFT_DIR
		# cleanup) instead of clobbering it. Capture current trap body
		# (if any) and append our cleanup commands.
		_prev_trap=$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- '(.*)' EXIT$/\1/" | sed "s/'\\\\''/'/g")
		_new_trap="rm -f '$_milestone_err' \"\${_create_out:-}\""
		if [ -n "$_prev_trap" ] && [ "$_prev_trap" != "trap -- '' EXIT" ]; then
			_new_trap="${_prev_trap}; ${_new_trap}"
		fi
		# shellcheck disable=SC2064
		trap "$_new_trap" EXIT
		_milestone_rc=0
		MILESTONE=$(skc_match_milestone "$ver" 2>"$_milestone_err") || _milestone_rc=$?
		if [ "$_milestone_rc" -ne 0 ]; then
			# PR_MILESTONE_AUTO_CREATE_SKIP=1: audit-log + take the
			# strict refuse path. Without the log, the skip leaves no
			# trace (contract docs promise audit-log for all SKIP envs).
			if [ "${PR_MILESTONE_AUTO_CREATE_SKIP:-0}" = "1" ]; then
				echo "warn: PR_MILESTONE_AUTO_CREATE_SKIP=1 — milestone auto-create bypassed" >&2
				_skip_log="$REPO_ROOT/.claude/logs/dogfood-gate-skip.jsonl"
				mkdir -p "$(dirname "$_skip_log")" 2>/dev/null || true
				jq -nc --arg ts "$(date -u +%FT%TZ)" \
					--arg env "PR_MILESTONE_AUTO_CREATE_SKIP" \
					--arg wrapper "github-pr-creation" \
					--arg version "$ver" \
					'{ts:$ts, env:$env, wrapper:$wrapper, version:$version}' \
					>>"$_skip_log" 2>/dev/null || true
				echo "milestone auto-resolve failed for prefix '$ver':" >&2
				cat "$_milestone_err" >&2
				echo "Re-run with explicit --milestone <title>." >&2
				exit 2
			fi
			# Distinguish "no open milestone" (auto-creatable) from
			# "ambiguous match" or "gh failure" (not safe to auto-fix).
			if grep -q "no open milestone matches" "$_milestone_err"; then
				echo "milestone '$ver' missing — auto-creating (PR_MILESTONE_AUTO_CREATE_SKIP=1 to disable)" >&2
				_create_out=$(mktemp -t milestone-create.XXXXXX)
				_create_rc=0
				gh api "repos/:owner/:repo/milestones" -f title="$ver" \
					-f state="open" >"$_create_out" 2>>"$_milestone_err" || _create_rc=$?
				if [ "$_create_rc" -ne 0 ]; then
					# 422 already_exists = race (concurrent run created
					# the milestone). Re-resolve via skc_match_milestone
					# to confirm + obtain canonical title.
					if grep -qE "already_exists|already_taken" "$_milestone_err"; then
						echo "milestone race: another run created '$ver' — re-resolving" >&2
						_milestone_rc2=0
						MILESTONE=$(skc_match_milestone "$ver" 2>>"$_milestone_err") || _milestone_rc2=$?
						if [ "$_milestone_rc2" -ne 0 ]; then
							echo "milestone re-resolve failed after 422:" >&2
							cat "$_milestone_err" >&2
							exit 2
						fi
					else
						echo "milestone auto-create failed:" >&2
						cat "$_milestone_err" >&2
						echo "Re-run with explicit --milestone <title>." >&2
						exit 2
					fi
				else
					# Use canonical title from response (handles
					# GitHub title normalization e.g. whitespace strip).
					if command -v jq >/dev/null 2>&1; then
						MILESTONE=$(jq -r '.title // empty' "$_create_out")
					fi
					[ -z "$MILESTONE" ] && MILESTONE=$ver
				fi
			else
				echo "milestone auto-resolve failed for prefix '$ver':" >&2
				cat "$_milestone_err" >&2
				echo "Re-run with explicit --milestone <title>." >&2
				exit 2
			fi
		fi
		# Restore previous trap state (if any) for the success path —
		# the per-block cleanup below handles temp file removal so the
		# downstream code still gets its original EXIT handler.
		rm -f "$_milestone_err" "${_create_out:-}"
		if [ -n "$_prev_trap" ] && [ "$_prev_trap" != "trap -- '' EXIT" ]; then
			# shellcheck disable=SC2064
			trap "$_prev_trap" EXIT
		else
			trap - EXIT
		fi
	fi
fi

# Labels: if none passed, pr-labeler.yml will apply area:* server-side on
# PR open. No client-side resolution — see skill-common.sh for why.

# Pre-create pr-lint-check validates body has required template section
# headings before we post the PR. Runs BEFORE skc_approve_or_exit so a
# broken body refuses upfront — don't bother the operator with an
# approval prompt for a PR that would fail validation immediately.
LINT="$REPO_ROOT/.claude/hooks/pr-lint-check.sh"
# When body came from Copilot, the SSOT validator is required (rc=4
# fail-closed depends on it firing). Missing/non-exec lint = refuse —
# Copilot-drafted body cannot bypass preflight via silent skip.
if [ "$BODY_FROM_COPILOT" = "1" ] && [ ! -x "$LINT" ]; then
	echo "error: pr-lint-check.sh missing/non-exec — Copilot-drafted body cannot skip SSOT validation" >&2
	echo "  hint: ensure $LINT is present + executable, or pass --body-file directly" >&2
	exit 4
fi
if [ -x "$LINT" ]; then
	# Build labels JSON for the pre-create lint mode.
	labels_json='[]'
	if [ "${#LABELS[@]}" -gt 0 ]; then
		labels_json=$(printf '%s\n' "${LABELS[@]}" | jq -R . | jq -s .)
	fi
	# --skip-label-check: pr-labeler runs AFTER create (below), so the
	# pre-create PR has no area:* label yet. Without this flag, the
	# area-label gate would hard-fail every invocation, defeating the
	# labeler integration. Post-create we call LINT again (full gate,
	# no skip) once labels are applied.
	# Capture LINT stderr separately so a corrupt/segfaulted lint
	# script (rc=126/127/139) gets a distinct diagnostic instead of
	# being misreported as "Copilot drafted a bad body".
	lint_err=$(mktemp -t pr-lint-err.XXXXXX) || {
		echo "error: mktemp failed for lint stderr capture" >&2
		exit 3
	}
	# shellcheck disable=SC2064
	trap "rm -f '$lint_err'" RETURN 2>/dev/null || true
	lint_rc=0
	"$LINT" --body "$BODY_FILE" --labels "$labels_json" --skip-label-check 2>"$lint_err" || lint_rc=$?
	if [ "$lint_rc" -ne 0 ]; then
		# rc=126/127/139 indicate corruption (not-executable / not-found /
		# segfault) — surface separately. rc=1 is the normal "lint reported
		# violations" path.
		if [ "$lint_rc" -ge 126 ] || [ "$lint_rc" = "0" ]; then
			echo "error: pr-lint-check.sh execution failure (rc=$lint_rc) — script corrupted?" >&2
			[ -s "$lint_err" ] && {
				echo "  lint stderr:" >&2
				while IFS= read -r line; do echo "    $line" >&2; done <"$lint_err"
			}
			rm -f "$lint_err"
			exit 4
		fi
		# Surface lint's own stderr for the operator (it names the missing
		# section / failed check).
		if [ -s "$lint_err" ]; then
			cat "$lint_err" >&2
		fi
		rm -f "$lint_err"
		# When body came from Copilot draft (not from operator), pr-lint
		# failure is fail-closed at rc=4 — don't create a PR with a
		# broken body. Operator-supplied bodies stay rc=2.
		if [ "$BODY_FROM_COPILOT" = "1" ]; then
			echo "error: Copilot-drafted PR body failed pr-lint preflight — refusing to create." >&2
			echo "  hint: re-run + Copilot will redraft, or pass --body-file with a fixed body." >&2
			exit 4
		fi
		echo "pr-lint-check (pre-create, body+issue-link) failed — fix PR body before creating (re-run wrapper after)." >&2
		exit 2
	fi
fi

echo "=== Creating PR ==="
echo "  Title:    $TITLE"
echo "  Body:     $BODY_FILE"
echo "  Base:     $BASE"
echo "  Labels:   ${LABELS[*]:-(none)}"
echo "  Milestone: ${MILESTONE:-(none)}"
echo "  Draft:    $DRAFT"
echo ""
skc_approve_or_exit "Create this PR?"

GH_ARGS=(pr create --title "$TITLE" --body-file "$BODY_FILE" --base "$BASE")
for l in "${LABELS[@]+"${LABELS[@]}"}"; do GH_ARGS+=(--label "$l"); done
[ -n "$MILESTONE" ] && GH_ARGS+=(--milestone "$MILESTONE")
[ "$DRAFT" = "1" ] && GH_ARGS+=(--draft)

URL=$(SKILL_WRAPPER=1 gh "${GH_ARGS[@]}")
# `|| true` for pipefail safety: if $URL lacks `pull/N` (gh output format
# change, auth warning prefixing URL, network redraw), the first grep
# exits 1 and pipefail would propagate non-zero from the command
# substitution — aborting the wrapper BEFORE the explicit `[ -z "$PR_NUM" ]`
# guard below can surface the failure. The PR is already created on
# GitHub at this point, so silent-abort is the worst outcome.
PR_NUM=$(printf '%s' "$URL" | grep -oE 'pull/[0-9]+' | tail -1 | grep -oE '[0-9]+' || true)
echo "✓ Created PR: $URL"

# Surface PR_NUM extraction failure explicitly — without this, both the
# labeler and the post-labeler lint silently no-op on empty PR_NUM,
# leaving the PR on GitHub but bypassing both follow-up gates with no
# operator-visible signal.
if [ -z "$PR_NUM" ]; then
	echo "⚠ could not extract PR number from URL '$URL' — skipping pr-labeler and post-labeler pr-lint." >&2
	echo "  If this repeats, check whether gh pr create's output format changed." >&2
fi

# v4.21 wire-in: post-create pr-labeler. Applies area:* labels from
# .github/labeler.yml glob matches on the PR's changed files. Replaces
# the disabled pr-labeler.yml workflow during Actions cap.
LABELER="$REPO_ROOT/.claude/hooks/pr-labeler.sh"
LABELER_OK=0
if [ -x "$LABELER" ] && [[ $PR_NUM =~ ^[0-9]+$ ]]; then
	echo "=== Applying area labels via pr-labeler ==="
	# Capture exit code immediately via `|| labeler_rc=$?`. The previous
	# `if cmd; then ... else echo "... $?"` form happened to work today
	# because $? in the else-branch IS the tested command's exit — but
	# any future edit inserting a statement before the echo would clobber
	# it to 0. Same set-e-safe pattern used for trivy + auto-close below.
	labeler_rc=0
	"$LABELER" "$PR_NUM" 2>&1 || labeler_rc=$?
	if [ "$labeler_rc" -eq 0 ]; then
		LABELER_OK=1
	else
		echo "⚠ pr-labeler failed on #$PR_NUM (exit $labeler_rc) — area labels may be missing. Re-run: $LABELER $PR_NUM" >&2
	fi
fi

# v4.21 wire-in: post-labeler full pr-lint against the now-labeled PR.
# Pre-create used --skip-label-check (labels not yet applied); this run
# closes the loop by verifying the full gate (body + issue link + area
# label) that the remote pr-lint.yml would enforce. Warn-only — the PR
# is already on GitHub; if it fails, a fix-up commit is the remedy.
#
# Run the full gate when EITHER pr-labeler succeeded OR the PR already
# has an area:* label (manually applied via --label, see CR #134 r1).
# Only skip when there's no area:* on the PR at all — that's the case
# where the area-label gate would fail for unrelated reasons.
if [ -x "$LINT" ] && [[ $PR_NUM =~ ^[0-9]+$ ]]; then
	if [ "$LABELER_OK" = "1" ]; then
		_pr_has_area=1
	else
		# Check whether the live PR already has an area:* label
		# (manually applied at create time via --label). Capture gh
		# rc separately so a gh API failure surfaces as a clear warn
		# instead of being silently swallowed (`| grep` would treat
		# both API failure and "no area label" as "skip").
		_pr_has_area=0
		_pr_labels=""
		_pr_labels_rc=0
		_pr_labels=$(gh pr view "$PR_NUM" --json labels --jq '.labels[].name' 2>/dev/null) || _pr_labels_rc=$?
		if [ "$_pr_labels_rc" -ne 0 ]; then
			echo "⚠ could not read PR labels for #$PR_NUM (gh rc=$_pr_labels_rc) — skipping post-labeler pr-lint probe." >&2
		elif printf '%s\n' "$_pr_labels" | tr '[:upper:]' '[:lower:]' | grep -qE '^area:'; then
			_pr_has_area=1
		fi
	fi
	if [ "$_pr_has_area" = "1" ]; then
		echo "=== Post-labeler pr-lint full gate for #$PR_NUM ==="
		# pr-lint-check.sh takes `--body <path> --labels <json-array>`, NOT a
		# positional PR number (#211): `"$LINT" "$PR_NUM"` always errored with
		# "unknown flag: <PR#>", so this gate emitted a false-alarm warning on
		# EVERY create regardless of body validity (and could mask a real
		# failure). Fetch the live PR body + labels and pass them so the gate
		# reflects the actual lint result.
		_lint_body=$(mktemp)
		# One round-trip for both fields, then derive locally. The
		# `|| _pr_meta=""` guard is required: a bare `var=$(failing-cmd)` aborts
		# under set -e, so capture-then-test keeps a gh failure on the warn+skip
		# path.
		_pr_meta=$(gh pr view "$PR_NUM" --json body,labels 2>/dev/null) || _pr_meta=""
		if [ -n "$_pr_meta" ]; then
			# `.body // ""` so a null (empty) PR body becomes an empty file, not
			# the literal string "null" — otherwise pr-lint greps fabricated
			# content + misattributes the failure (silent-failure-hunter #211).
			printf '%s' "$_pr_meta" | jq -r '.body // ""' >"$_lint_body"
			_lint_labels_json=$(printf '%s' "$_pr_meta" | jq -c '[.labels[].name]')
			if ! "$LINT" --body "$_lint_body" --labels "$_lint_labels_json"; then
				echo "⚠ pr-lint full gate failed on #$PR_NUM — fix the body/labels to satisfy the remote gate." >&2
			fi
		else
			echo "⚠ could not fetch PR metadata for #$PR_NUM — skipping post-labeler pr-lint probe (remote pr-lint.yml is authoritative)." >&2
		fi
		rm -f "$_lint_body"
	else
		echo "⚠ skipping post-labeler pr-lint — no area:* label on PR (labeler failed AND none passed via --label)." >&2
	fi
fi

# v4.24-A (#566) wire-in: fire project-board-sync.sh --on-pr-open so the
# PR's linked issues cascade to Status=Review and parent epics to In
# Progress. Shipped v4.5.D #388 but the wrapper integration silently
# broke — this closes the loop. Idempotent + state-aware (refuses if PR
# is already merged/closed).
BOARD_SYNC="$REPO_ROOT/.claude/local-backups/project-board-sync.sh"
if [ -x "$BOARD_SYNC" ] && [[ $PR_NUM =~ ^[0-9]+$ ]]; then
	echo "=== Firing project-board-sync --on-pr-open #$PR_NUM ==="
	if ! "$BOARD_SYNC" --on-pr-open "$PR_NUM" 2>&1; then
		echo "⚠ project-board-sync --on-pr-open #$PR_NUM failed — board Status may not reflect the PR." >&2
		echo "  Re-run manually: $BOARD_SYNC --on-pr-open $PR_NUM" >&2
	fi
fi

printf '%s\n' "$URL"
