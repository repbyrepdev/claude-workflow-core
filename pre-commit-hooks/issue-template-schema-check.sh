#!/bin/bash
set -euo pipefail
# Pre-commit validator for .github/ISSUE_TEMPLATE/*.yml. Drives required-
# id + required-label checks per template from the SSOT spec at
# .github/ISSUE_TEMPLATE/_spec.yml.
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

# Detect staged deletion of the spec explicitly so the operator sees a
# clear "unstage" hint instead of the generic "spec file missing" path.
# r2 silent-failure-hunter HIGH: capture git output to var BEFORE grep
# so a real git failure (corrupt index, lock contention) doesn't get
# masked by grep's "no match" exit 1 in the pipeline. set -e + bare
# command substitution surfaces git's failure code directly.
deleted_paths=$(git diff --cached --name-only --diff-filter=D) || {
	echo "issue-template-schema-check: git diff failed reading deleted-files set" >&2
	exit 2
}
if printf '%s\n' "$deleted_paths" | grep -Fxq "$SPEC"; then
	echo "issue-template-schema-check: $SPEC is staged for deletion — refusing" >&2
	echo "  Unstage: git reset HEAD $SPEC" >&2
	exit 2
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
	# r2 silent-failure-hunter HIGH: truncate yq_err at start so a prior
	# call's stale stderr can't surface as this call's diagnostic.
	: >"$yq_err"
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

# Phase 1 r1 silent-failure-hunter F2 (HIGH): assert non-empty list to
# catch empty / corrupt-but-yq-parseable spec. An empty `templates:` map
# would otherwise vacuous-pass.
if [ -z "$template_names" ]; then
	echo "issue-template-schema-check: $SPEC declares zero templates — refusing to vacuous-pass" >&2
	exit 2
fi

errs=0
err_lines=""

while IFS= read -r tname; do
	[ -n "$tname" ] || continue

	# Phase 1 r1 silent-failure-hunter F3 (MEDIUM): validate template-name
	# charset to defend against regex injection in id matching below.
	case "$tname" in *[^a-zA-Z0-9_-]*)
		echo "issue-template-schema-check: invalid template name '$tname' in spec (alphanumeric + _- only)" >&2
		exit 2
		;;
	esac

	# Phase 1 r1 silent-failure-hunter F1 (CRITICAL): drop the `|| ="" `
	# guard. `_yq_or_die` `exit 2` inside $(...) only exits the subshell,
	# so the guard previously swallowed the failure and treated the
	# template as having zero required ids — vacuous pass on yq error.
	# Bare call lets the inner exit 2 propagate via set -e + return-from-
	# command-substitution semantics.
	tfile=$(_yq_or_die ".templates.${tname}.file" "$SPEC" "${tname}.file")
	tpath="${TEMPLATE_DIR}/${tfile}"

	# If the template file doesn't exist on disk, that's a schema violation
	# — the spec promises it does. Schema-spec drift.
	if [ ! -f "$tpath" ]; then
		err_lines="${err_lines}  - ${tpath} declared in spec but missing on disk"$'\n'
		errs=$((errs + 1))
		continue
	fi

	# Required ids: each must appear as `id: <name>` on its own line.
	# r2 silent-failure-hunter F1-regression (CRITICAL): use _yq_or_die
	# with `// []` null-default so absent/empty required_ids returns rc=0
	# with empty output (legitimate), but actual yq parse failures still
	# propagate exit 2. Prior `|| true` reintroduced the vacuous-pass
	# pattern that r1 fixed elsewhere.
	required_ids=$(_yq_or_die ".templates.${tname}.required_ids // [] | .[]" "$SPEC" "${tname}.required_ids")
	while IFS= read -r req_id; do
		[ -n "$req_id" ] || continue
		# Validate id charset same as template name — regex injection guard.
		case "$req_id" in *[^a-zA-Z0-9_-]*)
			echo "issue-template-schema-check: invalid required_id '$req_id' for $tname (alphanumeric + _- only)" >&2
			exit 2
			;;
		esac
		if ! grep -Eq "^[[:space:]]*id:[[:space:]]*${req_id}[[:space:]]*\$" "$tpath"; then
			err_lines="${err_lines}  - ${tfile}: missing 'id: ${req_id}'"$'\n'
			errs=$((errs + 1))
		fi
	done <<<"$required_ids"

	# Required labels: parse via yq, set-compare via grep -Fxq line-exact.
	# Form-agnostic (inline-array OR block-list) + substring-safe.
	# r2 silent-failure-hunter F1-regression: use _yq_or_die with `// []`
	# null-default so absent/empty required_labels returns rc=0, but real
	# parse failures still die loudly.
	required_labels=$(_yq_or_die ".templates.${tname}.required_labels // [] | .[]" "$SPEC" "${tname}.required_labels")
	if [ -n "$required_labels" ]; then
		# Extract actual labels[] from the template — form-agnostic.
		actual_labels=$(_yq_or_die '.labels[]' "$tpath" "${tfile}.labels")
		if [ -z "$actual_labels" ]; then
			err_lines="${err_lines}  - ${tfile}: missing top-level 'labels:' list"$'\n'
			errs=$((errs + 1))
		else
			while IFS= read -r req_lbl; do
				[ -n "$req_lbl" ] || continue
				# Line-exact match against the yq-extracted label list.
				if ! echo "$actual_labels" | grep -Fxq "$req_lbl"; then
					err_lines="${err_lines}  - ${tfile}: labels list missing '${req_lbl}'"$'\n'
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
