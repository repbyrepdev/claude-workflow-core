#!/bin/bash
# v3.23.G #314 — pre-commit validator for .github/ISSUE_TEMPLATE/epic.yml.
#
# If epic.yml's schema drifts (someone removes `id: area`, changes the label
# auto-apply, deletes the sub-issues section), ai-triage's epic-detection
# heuristic + the board Type=Epic sync would break silently. This hook
# locks the required-section list.
#
# Fires only when epic.yml is in the staged diff — cheap on unrelated commits.

set -u

staged=$(git diff --cached --name-only 2>/dev/null || true)
echo "$staged" | grep -qx ".github/ISSUE_TEMPLATE/epic.yml" || exit 0

epic=$(git show ":.github/ISSUE_TEMPLATE/epic.yml" 2>/dev/null || cat .github/ISSUE_TEMPLATE/epic.yml)

errs=0
# CR v3.23.G: anchor the id-field checks so incidental text (like "id: arealabel"
# in a description) can't satisfy the regex. The actual form uses leading
# whitespace + `id: NAME` on its own line.
for required in area goal scope sub_issues acceptance rollout rollback; do
	if ! printf '%s\n' "$epic" | grep -Eq "^[[:space:]]*id:[[:space:]]*${required}[[:space:]]*$"; then
		echo "✗ epic.yml missing: id: $required" >&2
		errs=$((errs + 1))
	fi
done

# Both 'epic' AND 'enhancement' must auto-apply — ai-triage's epic detection
# + the board Type=Epic sync both depend on the label being present at open.
labels_line=$(printf '%s\n' "$epic" | grep -E '^[[:space:]]*labels:[[:space:]]*\[.*\]' || true)
if [ -z "$labels_line" ]; then
	echo "✗ epic.yml missing labels: [...] top-level auto-apply" >&2
	errs=$((errs + 1))
else
	echo "$labels_line" | grep -q '"epic"' || {
		echo "✗ epic.yml labels line must include \"epic\"" >&2
		errs=$((errs + 1))
	}
	echo "$labels_line" | grep -q '"enhancement"' || {
		echo "✗ epic.yml labels line must include \"enhancement\"" >&2
		errs=$((errs + 1))
	}
fi

if [ "$errs" -eq 0 ]; then
	echo "✓ epic.yml valid"
	exit 0
fi
exit 1
