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
# r1 silent-failure-hunter CRITICAL: probe shasum before relying on it.
# `shasum | awk '{print $1}'` on a missing-binary host returns rc=0 with
# empty stdout (awk on empty stdin succeeds). Both hashes would become
# empty strings + compare equal → vacuous-pass on every drift.
command -v shasum >/dev/null 2>&1 || {
	echo "workflow-source-pin: shasum required (BSD shasum on macOS, perl shasum on Linux)" >&2
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

# r1 silent-failure-hunter HIGH: empty cascade[] would silently disable
# enforcement. Operator might accidentally empty it (typo, merge,
# key-rename). Refuse and require explicit opt-out via empty-but-
# present marker.
if [ -z "$cascade_workflows" ]; then
	echo "workflow-source-pin: $CASCADE_FILE declares empty cascade[] — refusing to silent-disable enforcement" >&2
	echo "  If this is intentional, document the rationale in the cascade.yml comment block first." >&2
	exit 1
fi

# r1 silent-failure-hunter + code-reviewer (both flagged) HIGH: validate
# cascade-entry name shape BEFORE concatenating into a path. A typo or
# malicious entry like `../../etc/passwd` would otherwise read outside
# the intended source/live trees. Bare-filename + .yml/.yaml extension
# is the entire allowed shape.
no_cascade_workflows=$(_yq_or_die '.no_cascade // [] | .[]' "$CASCADE_FILE" 'no_cascade list')
planned_workflows=$(_yq_or_die '.planned // [] | .[]' "$CASCADE_FILE" 'planned list')

_validate_entry_shape() {
	local entry=$1 list_name=$2
	# The regex below ALREADY rejects slashes, `..`, and absolute paths
	# (`[A-Za-z0-9._-]+` excludes `/`, and `..` would need extra `.`
	# before/after the dot pair which `+` allows but the `.yml/.yaml`
	# anchor catches if it doesn't end correctly). Keeping the regex
	# as the single source of truth avoids the shellcheck SC2221/SC2222
	# pattern-overlap warning that an explicit case+regex would trigger.
	if ! [[ $entry =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]]; then
		echo "workflow-source-pin: ${list_name} entry '$entry' has unsafe shape (alphanumeric + ._- + .yml/.yaml only; no slashes or '..')" >&2
		exit 1
	fi
	# Defense-in-depth: also reject literal `..` anywhere in the entry
	# even though the regex above should catch it (a bare-`..`-containing
	# name like `..yml` would technically match the regex). r1
	# silent-failure-hunter + code-reviewer dup-HIGH.
	if [[ $entry == *..* ]]; then
		echo "workflow-source-pin: ${list_name} entry '$entry' contains '..' (rejected to prevent path traversal)" >&2
		exit 1
	fi
}

for entry_list_pair in "cascade:$cascade_workflows" "no_cascade:$no_cascade_workflows" "planned:$planned_workflows"; do
	list_name="${entry_list_pair%%:*}"
	entries="${entry_list_pair#*:}"
	while IFS= read -r entry; do
		[ -n "$entry" ] || continue
		_validate_entry_shape "$entry" "$list_name"
	done <<<"$entries"
done

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
	# r1 silent-failure-hunter CRITICAL: validate hash output shape
	# (64-char hex) before comparing. Defends against shasum producing
	# unexpected output (rare but possible on degraded systems).
	src_hash=$(shasum -a 256 "$src_path" | awk '{print $1}')
	live_hash=$(shasum -a 256 "$live_path" | awk '{print $1}')
	for hp in "src:${src_path}:${src_hash}" "live:${live_path}:${live_hash}"; do
		side="${hp%%:*}"
		rest="${hp#*:}"
		path="${rest%:*}"
		hash="${rest##*:}"
		if ! [[ $hash =~ ^[0-9a-f]{64}$ ]]; then
			echo "workflow-source-pin: shasum produced malformed output for ${side} ${path} (got '${hash}')" >&2
			exit 2
		fi
	done
	if [ "$src_hash" != "$live_hash" ]; then
		err_lines="${err_lines}  - ${wf} drift: ${src_path} ≠ ${live_path}"$'\n'
		errs=$((errs + 1))
	fi
done <<<"$cascade_workflows"

# r1 code-reviewer F2: surface orphan workflows in workflows-source/ —
# any *.yml file there must be classified in cascade[]/no_cascade[]/
# planned[]. Unclassified file = silent SSOT growth.
if [ -d "$SOURCE_DIR" ]; then
	# Build the allowed-entry set from all three lists.
	allowed=$(printf '%s\n%s\n%s\n' "$cascade_workflows" "$no_cascade_workflows" "$planned_workflows" | sort -u)
	for src_file in "$SOURCE_DIR"/*.yml "$SOURCE_DIR"/*.yaml; do
		[ -f "$src_file" ] || continue
		bn=$(basename "$src_file")
		if ! echo "$allowed" | grep -Fxq "$bn"; then
			err_lines="${err_lines}  - orphan workflow ${SOURCE_DIR}/${bn} (must be listed in cascade/no_cascade/planned in ${CASCADE_FILE})"$'\n'
			errs=$((errs + 1))
		fi
	done
fi

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
