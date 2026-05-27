#!/bin/bash
set -euo pipefail
# auto-register: false
# (Invoked by skills/github-pr-creation/run.sh as pre-create body
#  validation, not a Claude tool-use hook — install-hooks.sh skips
#  opted-out files.)
# Local mirror of .github/workflows/pr-lint.yml — runs the same three
# checks on the operator's machine BEFORE `gh pr create` so a body that
# would fail server-side pr-lint refuses upfront, never reaching GitHub.
#
# Closes #119 — the github-pr-creation skill wrapper already calls this
# script via `LINT="$REPO_ROOT/.claude/hooks/pr-lint-check.sh"`, but the
# script itself was missing → wrapper silently skipped pre-create
# validation, letting bad bodies reach GitHub's pr-lint where they
# round-tripped through edit-fix-repush. The whole point of the local
# mirror chain was defeated by absence.
#
# Three checks (mirror of pr-lint.yml jobs.pr-lint.steps):
#   1. Body references an issue via `Closes/Fixes/Resolves #N`
#   2. Body contains `## Summary` AND `## Test plan` headings
#   3. Labels include at least one `area:*` (skipped under --skip-label-check
#      because the wrapper's pre-create path runs BEFORE pr-labeler applies
#      the label server-side)
#
# Usage:
#   pr-lint-check.sh --body <path> --labels <json-array> [--skip-label-check]
#
# Exit codes (stable contract):
#   0  all checks passed
#   1  at least one check failed — stderr names each violation
#   2  argparse error
#   3  internal failure (missing dep, malformed input)

BODY_FILE=""
LABELS_JSON="[]"
SKIP_LABEL_CHECK=0

_usage() {
	cat <<USAGE
usage: pr-lint-check.sh --body <path> --labels <json-array> [--skip-label-check]

Local mirror of .github/workflows/pr-lint.yml. Same three checks:
  - Body references an issue (Closes/Fixes/Resolves #N)
  - Body has '## Summary' + '## Test plan' headings
  - Labels include at least one area:* (skippable for pre-create)

Returns rc=0 on pass, rc=1 on violation, rc=2 on argparse, rc=3 on internal failure.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--body)
		if [ $# -lt 2 ]; then
			echo "error: --body requires a path" >&2
			exit 2
		fi
		BODY_FILE=$2
		shift 2
		;;
	--labels)
		if [ $# -lt 2 ]; then
			echo "error: --labels requires a JSON-array argument" >&2
			exit 2
		fi
		LABELS_JSON=$2
		shift 2
		;;
	--skip-label-check)
		SKIP_LABEL_CHECK=1
		shift
		;;
	-h | --help)
		_usage
		exit 0
		;;
	*)
		echo "error: unknown flag: $1" >&2
		_usage >&2
		exit 2
		;;
	esac
done

if [ -z "$BODY_FILE" ]; then
	echo "error: --body is required" >&2
	exit 2
fi
if [ ! -f "$BODY_FILE" ]; then
	echo "error: --body file not found: $BODY_FILE" >&2
	exit 3
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "error: jq required for label parsing" >&2
	exit 3
fi
if ! command -v yq >/dev/null 2>&1; then
	echo "error: yq required for SSOT area-label derivation" >&2
	exit 3
fi

rc=0

# Read against the file directly — `echo "$BODY" | grep` interprets
# `-n`/`-e`/backslash sequences when body starts with them; using
# grep -F file path avoids both that and the trailing-newline strip
# (`BODY=$(cat ...)` collapses trailing newlines).

# Check 1: issue reference (matches Closes/Fixes/Resolves with optional
# -s/-d suffix, case-insensitive).
if ! grep -qiE "(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+" "$BODY_FILE"; then
	echo "✗ PR body must reference an issue (e.g., 'Closes #47')" >&2
	rc=1
fi

# Check 2: template section headings. Line-anchored to match the actual
# heading (not a substring inside prose or a fenced code block).
MISSING=""
for heading in "## Summary" "## Test plan"; do
	# Escape the heading for ERE then anchor with `^...[[:space:]]*$`.
	esc=$(printf '%s' "$heading" | sed 's/[][\\.*^$(){}?+|]/\\&/g')
	if ! grep -qE "^${esc}[[:space:]]*$" "$BODY_FILE"; then
		MISSING="$MISSING $heading"
	fi
done
if [ -n "$MISSING" ]; then
	echo "✗ PR body missing required template sections:$MISSING" >&2
	echo "  fix: read .github/pull_request_template.md and mirror its section structure" >&2
	rc=1
fi

# Check 3: area:* label (skippable for pre-create when labeler hasn't fired yet).
if [ "$SKIP_LABEL_CHECK" = "0" ]; then
	# Validate LABELS_JSON shape up front so a malformed --labels arg
	# (e.g., 'area:foo' instead of '["area:foo"]') gets a clear error
	# instead of a misleading "no area:* label" finding.
	if ! _jq_err=$(printf '%s' "$LABELS_JSON" | jq -e 'type=="array"' 2>&1 >/dev/null); then
		echo "error: --labels must be a JSON array (got: $LABELS_JSON)" >&2
		[ -n "$_jq_err" ] && echo "  jq stderr: $_jq_err" >&2
		exit 2
	fi
	# Resolve allowed area labels from .github/labels.yml SSOT — adding a
	# new area:* there is immediately accepted without editing this script.
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	LABELS_YML="$REPO_ROOT/.github/labels.yml"
	if [ ! -f "$LABELS_YML" ]; then
		echo "error: .github/labels.yml missing — cannot validate area:* labels" >&2
		exit 3
	fi
	AREA_LABELS=$(yq -r '.[] | select(.name | test("^area:")) | .name' "$LABELS_YML")
	if [ -z "$AREA_LABELS" ]; then
		echo "error: .github/labels.yml has no area:* entries" >&2
		exit 3
	fi
	FOUND=0
	while IFS= read -r label; do
		[ -z "$label" ] && continue
		if printf '%s' "$LABELS_JSON" | jq -e --arg l "$label" 'index($l)' >/dev/null 2>&1; then
			FOUND=1
			break
		fi
	done <<<"$AREA_LABELS"
	if [ "$FOUND" = "0" ]; then
		echo "✗ PR must have an area:* label. Options (.github/labels.yml SSOT):" >&2
		while IFS= read -r label; do
			[ -z "$label" ] && continue
			echo "    - $label" >&2
		done <<<"$AREA_LABELS"
		rc=1
	fi
fi

exit "$rc"
