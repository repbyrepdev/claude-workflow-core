#!/bin/bash
set -euo pipefail
# Pre-commit gate: workflows-source/ ↔ workflows/ hash-equivalence.
#
# The plugin owns two parallel directories:
#   * .github/workflows-source/ — SSOT directory; canonical versions
#     of every cascadable workflow.
#   * .github/workflows/        — live directory GitHub Actions reads.
#
# These must stay byte-identical for any workflow listed in
# .github/workflows-cascade.yml under `cascade:`. Drift between them
# would mean either (a) operator edited workflows/ but forgot to
# update workflows-source/ (consumers will then receive the stale
# SSOT on next refresh), or (b) operator edited workflows-source/
# but forgot to mirror to workflows/ (plugin's own CI uses the stale
# version).
#
# This hook detects drift in BOTH directions and blocks the commit.
#
# Wiring: registered in .pre-commit-config.yaml + .pre-commit-hooks.yaml.
# Bypass: WORKFLOW_SOURCE_PIN_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (no workflow change staged, OR every cascade workflow
#       is hash-equivalent between source and live)
#   1 — drift (one or more cascade workflows differ between source
#       and live)
#   2 — precondition error (yq missing, cascade file missing, yq parse
#       failure, mktemp failure)

if [ "${WORKFLOW_SOURCE_PIN_SKIP:-0}" = "1" ]; then
	echo "workflow-source-pin: WORKFLOW_SOURCE_PIN_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "workflow-source-pin: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

CASCADE_FILE=".github/workflows-cascade.yml"
SOURCE_DIR=".github/workflows-source"
LIVE_DIR=".github/workflows"

# Fire only when a workflow-related file is staged (cascade.yml itself,
# any workflows-source/*.yml, or any workflows/*.yml). Cheap on
# unrelated commits.
STAGED=$(git diff --cached --name-only --diff-filter=ACMRD |
	grep -E "^(${CASCADE_FILE//./\\.}|${SOURCE_DIR}/.+\\.ya?ml|${LIVE_DIR}/.+\\.ya?ml)\$" || true)
if [ -z "$STAGED" ]; then
	exit 0
fi

if [ ! -f "$CASCADE_FILE" ]; then
	echo "workflow-source-pin: cascade file missing: $CASCADE_FILE" >&2
	echo "  This file declares which workflows propagate to consumers." >&2
	exit 2
fi

command -v yq >/dev/null 2>&1 || {
	echo "workflow-source-pin: yq required" >&2
	exit 2
}

yq_err=$(mktemp -t wf-pin-yq.XXXXXX) || {
	echo "workflow-source-pin: mktemp failed" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

_yq_or_die() {
	local expr=$1 file=$2 desc=$3
	local out
	: >"$yq_err"
	if ! out=$(yq -r "$expr" "$file" 2>"$yq_err"); then
		echo "workflow-source-pin: yq failed parsing $file ($desc):" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	printf '%s' "$out"
}

# Validate schema_version.
spec_version=$(_yq_or_die '.schema_version' "$CASCADE_FILE" 'schema_version')
if [ "$spec_version" != "1" ]; then
	echo "workflow-source-pin: $CASCADE_FILE schema_version must equal 1 (got '$spec_version')" >&2
	exit 1
fi

# Iterate every workflow in cascade[].
cascade_workflows=$(_yq_or_die '.cascade // [] | .[]' "$CASCADE_FILE" 'cascade list')

if [ -z "$cascade_workflows" ]; then
	# Empty cascade list — no enforcement (cascade can legitimately be
	# empty if everything is plugin-only). Pass.
	exit 0
fi

errs=0
err_lines=""

while IFS= read -r wf; do
	[ -n "$wf" ] || continue

	src_path="${SOURCE_DIR}/${wf}"
	live_path="${LIVE_DIR}/${wf}"

	if [ ! -f "$src_path" ]; then
		err_lines="${err_lines}  - cascade declares ${wf} but ${src_path} missing on disk"$'\n'
		errs=$((errs + 1))
		continue
	fi
	if [ ! -f "$live_path" ]; then
		err_lines="${err_lines}  - cascade declares ${wf} but ${live_path} missing on disk"$'\n'
		errs=$((errs + 1))
		continue
	fi

	# Compare hashes — byte-identical means no drift.
	src_hash=$(shasum -a 256 "$src_path" | awk '{print $1}')
	live_hash=$(shasum -a 256 "$live_path" | awk '{print $1}')
	if [ "$src_hash" != "$live_hash" ]; then
		err_lines="${err_lines}  - ${wf} drift: ${src_path} ≠ ${live_path}"$'\n'
		errs=$((errs + 1))
	fi
done <<<"$cascade_workflows"

if [ "$errs" -gt 0 ]; then
	echo "workflow-source-pin: ${errs} drift / missing violation(s):" >&2
	printf '%s' "$err_lines" >&2
	echo "" >&2
	echo "  Fix: edit the SSOT file at ${SOURCE_DIR}/<workflow>, then" >&2
	echo "       copy to ${LIVE_DIR}/<workflow> + re-stage both." >&2
	echo "  (Or vice versa — they must stay byte-identical.)" >&2
	echo "  Bypass (audit-log): WORKFLOW_SOURCE_PIN_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
