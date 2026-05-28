#!/bin/bash
set -euo pipefail
# v0.29.0 (#172): apply-branch-protection — SSOT → GitHub branch-protection
# applicator + drift detector.
#
# Reads `.github/required-checks-list.yml` (the canonical list of required
# status checks for `main`) and either:
#   - applies the list to GitHub via PUT on the branch-protection API
#   - prints the planned PUT body (--dry-run)
#   - detects drift between SSOT and GitHub (--check)
#
# Closes the last manual SSOT-application gap. Today the YAML is READ by
# the pr-merge skill + run-required-checks.sh, but APPLYING it to
# GitHub's branch-protection settings is a manual `gh api PUT` step
# that operators have to remember. This script makes the round-trip
# mechanical.
#
# Usage:
#   scripts/apply-branch-protection.sh             # apply YAML → GitHub
#   scripts/apply-branch-protection.sh --dry-run   # print planned PUT body
#   scripts/apply-branch-protection.sh --check     # exit 1 if drift
#   scripts/apply-branch-protection.sh --help
#
# Exit codes:
#   0 — applied OK / --check clean / --dry-run printed
#   1 — --check detected drift (set differs from SSOT)
#   2 — usage error / missing dependency / SSOT parse failure
#   3 — gh API call failed
#
# Requires: yq, jq, gh (authenticated as a user with admin on the repo).

usage() {
	cat <<'EOF'
Usage: scripts/apply-branch-protection.sh [--dry-run|--check|--help]

Applies the required-checks list from `.github/required-checks-list.yml`
to GitHub branch protection on `main`. Idempotent.

Options:
  --dry-run    Print planned PUT body; do not call GitHub.
  --check      Compare current branch-protection state against SSOT;
               exit 1 on drift, 0 on match.
  --help       Show this help.

Exit codes:
  0  apply succeeded / dry-run printed / --check found no drift
  1  --check detected drift (current set ≠ SSOT)
  2  usage error, missing dependency, or SSOT parse failure
  3  gh API call failed (auth, network, permissions)
EOF
}

MODE="apply"

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		MODE="dry-run"
		shift
		;;
	--check)
		MODE="check"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "apply-branch-protection: unknown arg: $1" >&2
		usage
		exit 2
		;;
	esac
done

for bin in yq jq gh; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "apply-branch-protection: ERROR $bin not in PATH" >&2
		exit 2
	fi
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SSOT="$REPO_ROOT/.github/required-checks-list.yml"

if [ ! -f "$SSOT" ]; then
	echo "apply-branch-protection: ERROR SSOT missing at $SSOT" >&2
	exit 2
fi

# Extract required check names from SSOT. Each entry has `check_name:`.
REQUIRED_NAMES=$(yq -r '.required[].check_name' "$SSOT") || {
	echo "apply-branch-protection: ERROR yq failed to parse $SSOT" >&2
	exit 2
}
if [ -z "$REQUIRED_NAMES" ]; then
	echo "apply-branch-protection: ERROR SSOT .required[] is empty" >&2
	exit 2
fi

# Resolve owner/repo from current remote.
OWNER=$(gh repo view --json owner --jq '.owner.login') || {
	echo "apply-branch-protection: ERROR cannot resolve owner via gh repo view" >&2
	exit 3
}
REPO=$(gh repo view --json name --jq '.name') || {
	echo "apply-branch-protection: ERROR cannot resolve repo via gh repo view" >&2
	exit 3
}
BRANCH="main"

# Modern GitHub uses `checks[]` (context + app_id), legacy uses
# `contexts[]`. CHECKS_JSON is built below from the validated/deduped
# REQUIRED_NAMES list.

# Tempfile cleanup via single trap (avoids leak on signal / future exit
# paths). All temp files live under $WORK.
WORK=$(mktemp -d -t apply-branch-protection.XXXXXX) || {
	echo "apply-branch-protection: ERROR mktemp -d failed" >&2
	exit 2
}
trap 'rm -rf "$WORK"' EXIT INT TERM
current_err="$WORK/current.err"

# Validate REQUIRED_NAMES: no empty entries, no whitespace-only, no
# duplicates. Whitespace-only/empty would silently register an
# unsatisfiable required check; duplicates create false-positive drift.
clean_names=$(printf '%s\n' "$REQUIRED_NAMES" | awk 'NF>0 && !seen[$0]++')
if [ -z "$clean_names" ]; then
	echo "apply-branch-protection: ERROR SSOT .required[] yielded no usable check_names after trim" >&2
	exit 2
fi
if [ "$(printf '%s\n' "$REQUIRED_NAMES" | awk 'NF>0' | wc -l)" != "$(printf '%s\n' "$clean_names" | wc -l)" ]; then
	echo "apply-branch-protection: ERROR SSOT .required[] contains duplicate check_names" >&2
	exit 2
fi
REQUIRED_NAMES="$clean_names"
CHECKS_JSON=$(printf '%s\n' "$REQUIRED_NAMES" | jq -R '{context: ., app_id: -1}' | jq -s '.')

# Fetch the current branch-protection state once; cope with the "branch
# not protected" 404 by using a sensible empty default. Both --check and
# apply modes use this; --check treats 404 as drift (SSOT non-empty vs
# current empty), apply mode uses defaults to build the initial PUT.
current_payload=""
current_rc=0
current_payload=$(gh api "repos/$OWNER/$REPO/branches/$BRANCH/protection" 2>"$current_err") || current_rc=$?
if [ "$current_rc" -ne 0 ]; then
	if grep -q "Branch not protected" "$current_err" 2>/dev/null; then
		current_payload='{}'
	else
		echo "apply-branch-protection: ERROR gh api fetch failed (rc=$current_rc): $(head -c 200 "$current_err")" >&2
		exit 3
	fi
fi

if [ "$MODE" = "check" ]; then
	# Accept both modern (.required_status_checks.checks[].context) and
	# legacy (.required_status_checks.contexts[]) representations.
	current_names=$(printf '%s' "$current_payload" | jq -r '((.required_status_checks.checks // []) | map(.context)) + (.required_status_checks.contexts // []) | unique | .[]' | sort)
	expected_names=$(printf '%s\n' "$REQUIRED_NAMES" | sort)
	if [ "$current_names" = "$expected_names" ]; then
		echo "apply-branch-protection: ✓ branch protection on $OWNER/$REPO:$BRANCH matches SSOT"
		exit 0
	fi
	echo "apply-branch-protection: DRIFT — branch protection on $OWNER/$REPO:$BRANCH differs from SSOT" >&2
	echo "  Expected (SSOT):" >&2
	while IFS= read -r name; do printf '    - %s\n' "$name" >&2; done <<<"$expected_names"
	echo "  Current (GitHub):" >&2
	if [ -z "$current_names" ]; then
		echo "    (branch not protected OR no required checks set)" >&2
	else
		while IFS= read -r name; do printf '    - %s\n' "$name" >&2; done <<<"$current_names"
	fi
	echo "  To fix: scripts/apply-branch-protection.sh" >&2
	exit 1
fi

# GitHub's PUT endpoint uses a restricted subset of fields; we explicitly
# construct each top-level key. Strict_status_checks is preserved.
STRICT=$(printf '%s' "$current_payload" | jq -r '.required_status_checks.strict // true')
ENFORCE_ADMINS=$(printf '%s' "$current_payload" | jq -r '.enforce_admins.enabled // false')
REQUIRED_LINEAR_HISTORY=$(printf '%s' "$current_payload" | jq -r '.required_linear_history.enabled // false')
ALLOW_FORCE_PUSHES=$(printf '%s' "$current_payload" | jq -r '.allow_force_pushes.enabled // false')
ALLOW_DELETIONS=$(printf '%s' "$current_payload" | jq -r '.allow_deletions.enabled // false')
REQUIRED_CONVERSATION_RESOLUTION=$(printf '%s' "$current_payload" | jq -r '.required_conversation_resolution.enabled // false')

# Preserve required_pull_request_reviews if present; otherwise null.
PR_REVIEWS=$(printf '%s' "$current_payload" | jq -c '.required_pull_request_reviews // null')

PUT_BODY=$(jq -n \
	--argjson checks "$CHECKS_JSON" \
	--argjson strict "$STRICT" \
	--argjson enforce_admins "$ENFORCE_ADMINS" \
	--argjson required_linear_history "$REQUIRED_LINEAR_HISTORY" \
	--argjson allow_force_pushes "$ALLOW_FORCE_PUSHES" \
	--argjson allow_deletions "$ALLOW_DELETIONS" \
	--argjson required_conversation_resolution "$REQUIRED_CONVERSATION_RESOLUTION" \
	--argjson pr_reviews "$PR_REVIEWS" \
	'{
		required_status_checks: {strict: $strict, checks: $checks},
		enforce_admins: $enforce_admins,
		required_pull_request_reviews: $pr_reviews,
		restrictions: null,
		required_linear_history: $required_linear_history,
		allow_force_pushes: $allow_force_pushes,
		allow_deletions: $allow_deletions,
		required_conversation_resolution: $required_conversation_resolution
	}')

if [ "$MODE" = "dry-run" ]; then
	echo "# apply-branch-protection: DRY RUN — would PUT repos/$OWNER/$REPO/branches/$BRANCH/protection"
	echo "# Body:"
	printf '%s\n' "$PUT_BODY" | jq .
	exit 0
fi

# Pre-validate PUT body before sending (defense against upstream
# breakage producing an empty/invalid body).
if [ -z "$PUT_BODY" ] || ! printf '%s' "$PUT_BODY" | jq -e '.required_status_checks.checks | length > 0' >/dev/null 2>&1; then
	echo "apply-branch-protection: ERROR PUT body invalid or has empty checks[] — refusing to apply" >&2
	exit 2
fi

# Apply.
apply_err="$WORK/apply.err"
if ! printf '%s' "$PUT_BODY" | gh api --method PUT "repos/$OWNER/$REPO/branches/$BRANCH/protection" --input - >/dev/null 2>"$apply_err"; then
	echo "apply-branch-protection: ERROR PUT failed:" >&2
	if jq -e . "$apply_err" >/dev/null 2>&1; then
		jq . "$apply_err" >&2
	else
		cat "$apply_err" >&2
	fi
	exit 3
fi
echo "apply-branch-protection: ✓ branch protection on $OWNER/$REPO:$BRANCH updated to match SSOT ($(printf '%s' "$CHECKS_JSON" | jq 'length') required checks)"
exit 0
