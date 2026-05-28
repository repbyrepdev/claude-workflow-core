#!/bin/bash
set -euo pipefail
# v0.19.1 (#143) — pre-commit validator for .github/ISSUE_TEMPLATE/*.yml.
#
# Successor to v3.23.G #314's epic-structure.sh (epic.yml-only). Extends
# coverage to all 5 issue templates (bug, feature, task, epic, brainstorm)
# driven by the SSOT spec at .github/ISSUE_TEMPLATE/_spec.yml.
#
# If any template drifts (someone removes `id: area`, changes the label
# auto-apply, deletes a required section), ai-triage's heuristics + the
# board Type=Epic sync would break silently. This hook locks the
# required-section list per template.
#
# Fires only when an ISSUE_TEMPLATE file is in the staged diff — cheap on
# unrelated commits.
#
# Bypass: ISSUE_TEMPLATE_SCHEMA_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (no templates staged, OR all staged templates valid)
#   1 — schema violation (template missing required id or label)
#   2 — precondition error (yq missing, spec missing, staging anomaly)

if [ "${ISSUE_TEMPLATE_SCHEMA_SKIP:-0}" = "1" ]; then
	echo "issue-template-schema-check: ISSUE_TEMPLATE_SCHEMA_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "issue-template-schema-check: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

SPEC=".github/ISSUE_TEMPLATE/_spec.yml"
TEMPLATE_DIR=".github/ISSUE_TEMPLATE"

# Only run when at least one issue-template file (or the spec itself) is
# staged. ACMRD captures add/copy/modify/rename/delete — deletion of the
# spec would silently bypass the gate without it.
STAGED=$(git diff --cached --name-only --diff-filter=ACMRD |
	grep -E "^${TEMPLATE_DIR}/.+\.ya?ml$" || true)
if [ -z "$STAGED" ]; then
	exit 0
fi

if [ ! -f "$SPEC" ]; then
	echo "issue-template-schema-check: spec file missing: $SPEC" >&2
	echo "  This file defines required ids + labels per template." >&2
	exit 2
fi

command -v yq >/dev/null 2>&1 || {
	echo "issue-template-schema-check: yq required" >&2
	exit 2
}

# Fail-loud yq pattern (mirrors consumers-schema-check.sh + check-ssot-drift.sh).
yq_err=$(mktemp -t issue-tmpl-yq.XXXXXX) || {
	echo "issue-template-schema-check: mktemp failed" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

_yq_or_die() {
	local expr=$1 file=$2 desc=$3
	local out
	if ! out=$(yq -r "$expr" "$file" 2>"$yq_err"); then
		echo "issue-template-schema-check: yq failed parsing $file ($desc):" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	printf '%s' "$out"
}

# Validate spec_version=1.
spec_version=$(_yq_or_die '.schema_version' "$SPEC" 'spec schema_version')
if [ "$spec_version" != "1" ]; then
	echo "issue-template-schema-check: $SPEC schema_version must equal 1 (got '$spec_version')" >&2
	exit 1
fi

# Iterate every template declared in the spec.
template_names=$(_yq_or_die '.templates | keys | .[]' "$SPEC" 'template name list')
errs=0
err_lines=""

while IFS= read -r tname; do
	[ -n "$tname" ] || continue
	tfile=$(_yq_or_die ".templates.${tname}.file" "$SPEC" "${tname}.file")
	tpath="${TEMPLATE_DIR}/${tfile}"

	# If the template file doesn't exist on disk, that's a schema violation
	# — the spec promises it does. Schema-spec drift.
	if [ ! -f "$tpath" ]; then
		err_lines="${err_lines}  - ${tpath} declared in spec but missing on disk"$'\n'
		errs=$((errs + 1))
		continue
	fi

	# Required ids: each must appear as `^  - type: ...` followed (within a
	# few lines) by `id: <name>`. Simpler invariant: every required id
	# appears as a literal `id: NAME` line in the file.
	required_ids=$(_yq_or_die ".templates.${tname}.required_ids[]" "$SPEC" "${tname}.required_ids") || required_ids=""
	while IFS= read -r req_id; do
		[ -n "$req_id" ] || continue
		if ! grep -Eq "^[[:space:]]*id:[[:space:]]*${req_id}[[:space:]]*\$" "$tpath"; then
			err_lines="${err_lines}  - ${tfile}: missing 'id: ${req_id}'"$'\n'
			errs=$((errs + 1))
		fi
	done <<<"$required_ids"

	# Required labels: each must appear in the top-level `labels: [...]`.
	# Spec allows empty list (task.yml is intentionally label-less at open).
	required_labels=$(_yq_or_die ".templates.${tname}.required_labels[]" "$SPEC" "${tname}.required_labels") || required_labels=""
	if [ -n "$required_labels" ]; then
		# Extract the labels line from the template.
		labels_line=$(grep -E '^[[:space:]]*labels:[[:space:]]*\[' "$tpath" || true)
		if [ -z "$labels_line" ]; then
			err_lines="${err_lines}  - ${tfile}: missing top-level 'labels: [...]'"$'\n'
			errs=$((errs + 1))
		else
			while IFS= read -r req_lbl; do
				[ -n "$req_lbl" ] || continue
				# Match either "label" or 'label' or bare label inside the brackets.
				if ! echo "$labels_line" | grep -Eq "[\"']?${req_lbl}[\"']?"; then
					err_lines="${err_lines}  - ${tfile}: labels line missing '${req_lbl}'"$'\n'
					errs=$((errs + 1))
				fi
			done <<<"$required_labels"
		fi
	fi
done <<<"$template_names"

if [ "$errs" -gt 0 ]; then
	echo "issue-template-schema-check: ${errs} violation(s):" >&2
	printf '%s' "$err_lines" >&2
	echo "" >&2
	echo "  Fix: edit the named template + re-stage." >&2
	echo "  Spec: $SPEC declares the required-id + required-label contract." >&2
	echo "  Bypass (audit-log): ISSUE_TEMPLATE_SCHEMA_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
