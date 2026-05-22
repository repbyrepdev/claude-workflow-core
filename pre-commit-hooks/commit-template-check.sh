#!/bin/bash
# v4.24 (#597) — pre-commit drift guard for .github/commit-template.yml.
#
# If commit-template.yml's schema drifts (someone removes `types`, changes
# `max_length`, deletes anti_patterns), the /git-commit skill's draft step
# + post-commit-template-lint.sh's validation would both break silently.
# This hook locks the required-section list at commit time.
#
# Fires only when commit-template.yml is in the staged diff — cheap on
# unrelated commits (mirrors epic-structure.sh pattern).

set -u

staged=$(git diff --cached --name-only 2>/dev/null || true)
echo "$staged" | grep -qx ".github/commit-template.yml" || exit 0

# Read the STAGED version (not working tree) so we check what's about to
# land, not what might have been already modified since staging. If git-show
# fails on a staged file, that's a real error — don't silently fall back to
# working tree (would validate wrong content).
if ! tpl=$(git show ":.github/commit-template.yml" 2>&1); then
	echo "ERROR: unable to read staged .github/commit-template.yml: $tpl" >&2
	exit 1
fi

errs=0

# Required top-level keys.
for required in "^schema:" "^examples:" "^anti_patterns:"; do
	if ! printf '%s\n' "$tpl" | grep -Eq "$required"; then
		echo "✗ commit-template.yml missing required top-level: ${required#^}" >&2
		errs=$((errs + 1))
	fi
done

# Required schema subkeys — these are consumed by downstream tools and
# changing names silently breaks drafting + validation.
for required in "max_length" "types" "scope_optional" "body" "required_for" "footer" "trailers"; do
	if ! printf '%s\n' "$tpl" | grep -Eq "^[[:space:]]+${required}:"; then
		echo "✗ commit-template.yml missing schema field: $required" >&2
		errs=$((errs + 1))
	fi
done

# Validate required_for contains the mandatory types (feat, fix, refactor, perf).
# Use yq if available — it handles both inline flow-style `[feat, fix]` AND
# block-style bullets. Grep-only approach failed on flow-style arrays.
if command -v yq >/dev/null 2>&1; then
	_tmpl_tmp=$(mktemp)
	printf '%s' "$tpl" >"$_tmpl_tmp"
	for required_type in "feat" "fix" "refactor" "perf"; do
		if ! yq -e ".schema.body.required_for[] | select(. == \"$required_type\")" "$_tmpl_tmp" >/dev/null 2>&1; then
			echo "✗ commit-template.yml body.required_for must include: $required_type" >&2
			errs=$((errs + 1))
		fi
	done
	rm -f "$_tmpl_tmp"
fi
# If yq missing, skip this check — the types-list check below still catches
# type-removal regressions via grep on `types:` bullets, but does NOT validate
# body.required_for contents (e.g., dropping "perf" won't be detected).
# Installing yq is required for full SSOT enforcement of .github/commit-template.yml
# schema including body.required_for field validation (reference: .claude/pre-commit-hooks/commit-template-check.sh).

# Conventional Commits 1.0.0 standard types MUST be represented in the
# types list. If someone removes 'feat' or 'fix', release-notes
# categorization breaks.
for required in "feat" "fix" "refactor" "perf" "chore" "docs" "test" "revert" "build" "ci"; do
	if ! printf '%s\n' "$tpl" | grep -qE "^[[:space:]]+-[[:space:]]+${required}\b"; then
		echo "✗ commit-template.yml types must include: $required" >&2
		errs=$((errs + 1))
	fi
done

# max_length must be exactly 70 (Conventional Commits standard + GitHub UI).
ml=$(printf '%s\n' "$tpl" | grep -E "^[[:space:]]+max_length:" | grep -oE '[0-9]+' | head -1)
if [ -z "$ml" ] || ! [ "$ml" -eq 70 ] 2>/dev/null; then
	echo "✗ commit-template.yml max_length must be 70 (got: ${ml:-none})" >&2
	errs=$((errs + 1))
fi

if [ "$errs" -gt 0 ]; then
	echo "" >&2
	echo "$errs schema drift error(s) in .github/commit-template.yml" >&2
	echo "This file is SSOT for downstream tooling. Restore required fields or revert." >&2
	exit 1
fi

exit 0
