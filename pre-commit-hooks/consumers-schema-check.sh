#!/bin/bash
set -euo pipefail
# (#141) Pre-commit gate: .github/consumers.yml schema integrity.
#
# Validates the consumer-registry SSOT every time `.github/consumers.yml`
# is staged. Catches:
#   * schema_version drift (must be 1)
#   * missing required fields (name, repo, local_path, pinned_version,
#     overrides_file, bootstrap_date, contact, notes)
#   * malformed pinned_version (must be X.Y.Z semver)
#   * duplicate consumer names
#   * malformed repo coordinate (must be owner/name)
#   * bootstrap_date that doesn't parse as YYYY-MM-DD
#
# Bypass: CONSUMERS_SCHEMA_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (no consumers.yml staged, OR staged + schema valid)
#   1 — schema violation
#   2 — precondition error (yq missing, etc.)

if [ "${CONSUMERS_SCHEMA_SKIP:-0}" = "1" ]; then
	echo "consumers-schema-check: CONSUMERS_SCHEMA_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "consumers-schema-check: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

REGISTRY=".github/consumers.yml"

# Only validate when consumers.yml is in the staged set.
STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null |
	grep -Fx "$REGISTRY" || true)
if [ -z "$STAGED" ]; then
	exit 0
fi

if [ ! -f "$REGISTRY" ]; then
	echo "consumers-schema-check: $REGISTRY staged but missing on disk" >&2
	exit 1
fi

for cmd in yq jq; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "consumers-schema-check: $cmd required" >&2
		exit 2
	}
done

# Parse the staged content (not on-disk — staged may differ).
# Use a temp file because piping `git show :path` through yq is more
# fragile under set -e than file-based.
staged_tmp=$(mktemp -t consumers-staged.XXXXXX)
trap 'rm -f "$staged_tmp"' EXIT
git show ":${REGISTRY}" >"$staged_tmp" 2>/dev/null || {
	echo "consumers-schema-check: could not read staged $REGISTRY" >&2
	exit 2
}

# 1. schema_version present and equals 1.
schema_version=$(yq -r '.schema_version' "$staged_tmp" 2>/dev/null || echo "")
if [ "$schema_version" != "1" ]; then
	echo "consumers-schema-check: $REGISTRY .schema_version must equal 1 (got '$schema_version')" >&2
	exit 1
fi

# 2. consumers is a non-empty list.
consumer_count=$(yq -r '.consumers | length' "$staged_tmp" 2>/dev/null || echo "0")
if [ "$consumer_count" -lt 1 ]; then
	echo "consumers-schema-check: $REGISTRY .consumers must be a non-empty list (got $consumer_count entries)" >&2
	exit 1
fi

# 3. Per-consumer required fields + format checks.
errors=()
names_seen=""
required_fields="name repo local_path pinned_version overrides_file bootstrap_date contact notes"
i=0
while [ "$i" -lt "$consumer_count" ]; do
	for field in $required_fields; do
		value=$(yq -r ".consumers[$i].${field}" "$staged_tmp" 2>/dev/null || echo "")
		if [ -z "$value" ] || [ "$value" = "null" ]; then
			errors+=("consumers[$i].${field} missing or null")
		fi
	done

	name=$(yq -r ".consumers[$i].name" "$staged_tmp" 2>/dev/null || echo "")
	repo=$(yq -r ".consumers[$i].repo" "$staged_tmp" 2>/dev/null || echo "")
	pinned=$(yq -r ".consumers[$i].pinned_version" "$staged_tmp" 2>/dev/null || echo "")
	bd=$(yq -r ".consumers[$i].bootstrap_date" "$staged_tmp" 2>/dev/null || echo "")

	# Duplicate name
	if [ -n "$name" ] && [ "$name" != "null" ]; then
		if printf '%s\n' "$names_seen" | grep -Fxq "$name"; then
			errors+=("duplicate consumer name: $name")
		fi
		names_seen="${names_seen}${name}"$'\n'
	fi

	# repo = owner/name format
	if [ -n "$repo" ] && [ "$repo" != "null" ]; then
		if ! [[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
			errors+=("consumers[$i].repo '$repo' must be owner/name format")
		fi
	fi

	# pinned_version = X.Y.Z semver
	if [ -n "$pinned" ] && [ "$pinned" != "null" ]; then
		if ! [[ $pinned =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			errors+=("consumers[$i].pinned_version '$pinned' must be X.Y.Z semver")
		fi
	fi

	# bootstrap_date = YYYY-MM-DD
	if [ -n "$bd" ] && [ "$bd" != "null" ]; then
		if ! [[ $bd =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
			errors+=("consumers[$i].bootstrap_date '$bd' must be YYYY-MM-DD")
		fi
	fi

	i=$((i + 1))
done

if [ ${#errors[@]} -gt 0 ]; then
	echo "consumers-schema-check: ${#errors[@]} violation(s) in $REGISTRY:" >&2
	for e in "${errors[@]}"; do
		echo "  - $e" >&2
	done
	echo "" >&2
	echo "  Fix: edit .github/consumers.yml + re-stage." >&2
	echo "  Bypass (audit-log): CONSUMERS_SCHEMA_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
