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
#   * bootstrap_date that doesn't parse as YYYY-MM-DD (shape-only check;
#     impossible dates like 2026-13-45 pass — informational field)
#   * staged DELETION of the registry (registry SSOT presence is part of
#     the plugin contract; cascade tools depend on its existence)
#
# Wiring: registered in .pre-commit-config.yaml (id: consumers-schema-check)
# and .pre-commit-hooks.yaml (entry for consumer-side use).
#
# Bypass: CONSUMERS_SCHEMA_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (no consumers.yml staged, OR staged + schema valid)
#   1 — schema violation (in-file content invalid, or registry deleted)
#   2 — precondition error (yq/jq missing, staging anomaly, mktemp failure,
#       yq parse failure — distinguishes infrastructure from content bugs)

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

# Stage detection — use --name-status with --diff-filter=ACMRD so we see
# BOTH the change-status code AND old/new paths for rename entries.
# r2 silent-failure-hunter: dropped `2>/dev/null` on git diff calls so
# index corruption / permission errors on .git/index surface instead of
# silently disabling the gate.
# r2 code-reviewer: `git mv .github/consumers.yml elsewhere.yml` records
# a single `R<score>` entry whose name-only output is ONLY the new path.
# That bypassed the prior pure-deletion guard. --name-status surfaces
# the rename so we can detect "rename-away" (registry → other path).
STAGED_RAW=$(git diff --cached --name-status --diff-filter=ACMRD)
if [ -z "$STAGED_RAW" ]; then
	exit 0
fi

# Walk the status output. For each line:
#   A/C/M/D  <path>
#   R<score> <old>   <new>
# Detect: registry add/modify (STAGED_MODIFY), pure deletion (STAGED_DELETE),
# rename-away (STAGED_RENAME_AWAY — registry → other path), rename-to
# (registry-becomes — other path → registry).
STAGED_MODIFY=""
STAGED_DELETE=""
STAGED_RENAME_AWAY=""
STAGED_RENAME_TO=""
while IFS=$'\t' read -r status p1 p2; do
	case "$status" in
	A | C* | M | T)
		[ "$p1" = "$REGISTRY" ] && STAGED_MODIFY=1
		;;
	D)
		[ "$p1" = "$REGISTRY" ] && STAGED_DELETE=1
		;;
	R*)
		if [ "$p1" = "$REGISTRY" ] && [ "$p2" != "$REGISTRY" ]; then
			STAGED_RENAME_AWAY=1
		fi
		if [ "$p2" = "$REGISTRY" ] && [ "$p1" != "$REGISTRY" ]; then
			STAGED_RENAME_TO=1
		fi
		;;
	esac
done <<<"$STAGED_RAW"

# Touch detection: any of the registry-affecting status codes.
if [ -z "$STAGED_MODIFY" ] && [ -z "$STAGED_DELETE" ] &&
	[ -z "$STAGED_RENAME_AWAY" ] && [ -z "$STAGED_RENAME_TO" ]; then
	exit 0
fi

# Pure deletion OR rename-away both leave the registry path empty in the
# committed tree — both break cascade tools that depend on its presence.
if { [ -n "$STAGED_DELETE" ] || [ -n "$STAGED_RENAME_AWAY" ]; } && [ -z "$STAGED_MODIFY" ] && [ -z "$STAGED_RENAME_TO" ]; then
	if [ -n "$STAGED_RENAME_AWAY" ]; then
		echo "consumers-schema-check: $REGISTRY staged for RENAME-AWAY — refusing" >&2
		echo "  $REGISTRY is the SSOT for plugin consumers; cascade tools depend" >&2
		echo "  on it existing AT THIS PATH. If relocating the SSOT, update the" >&2
		echo "  cascade tools + this hook + bootstrap-repo.sh template first." >&2
	else
		echo "consumers-schema-check: $REGISTRY staged for DELETION — refusing" >&2
		echo "  $REGISTRY is the SSOT for plugin consumers; cascade tools depend" >&2
		echo "  on it existing. If consolidating, write a deprecation issue first." >&2
	fi
	echo "  Bypass (audit-log): CONSUMERS_SCHEMA_SKIP=1 git commit ..." >&2
	exit 1
fi

if [ ! -f "$REGISTRY" ]; then
	# Staged in ACMR but not on disk = staging anomaly (e.g. post-rebase
	# index/worktree skew). That's infrastructure, not content — exit 2.
	# (Phase 1 comment-analyzer #10: prior code returned exit 1 here,
	# conflating staging anomalies with schema violations.)
	echo "consumers-schema-check: $REGISTRY staged but missing on disk" >&2
	echo "  Staging anomaly (post-rebase skew?). Reset index or restore file." >&2
	exit 2
fi

for cmd in yq jq; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "consumers-schema-check: $cmd required" >&2
		exit 2
	}
done

# Parse the staged content (not on-disk — staged may differ). Materialize
# to a temp file before parsing; yq's stdin path is unreliable under set -e
# (exits non-zero on certain comment-only diffs even when output is valid).
staged_tmp=$(mktemp -t consumers-staged.XXXXXX) || {
	echo "consumers-schema-check: mktemp failed — cannot stage parse buffer" >&2
	exit 2
}
yq_err=$(mktemp -t consumers-yq.XXXXXX) || {
	rm -f "$staged_tmp"
	echo "consumers-schema-check: mktemp failed — cannot stage yq error buffer" >&2
	exit 2
}
# Cleanup on every exit path (including INT/TERM/HUP). Phase 1 lesson
# #647: trap on EXIT alone leaks tmp files when the user Ctrl-C's mid-run.
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$staged_tmp" "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

# Capture git show stderr to yq_err (reusing tmp buffer) and surface
# it on failure. r2 silent-failure-hunter #1: prior `2>/dev/null` masked
# corrupt-object-store / permission errors as a generic "could not read"
# message with no diagnostic context.
if ! git show ":${REGISTRY}" >"$staged_tmp" 2>"$yq_err"; then
	echo "consumers-schema-check: could not read staged $REGISTRY:" >&2
	cat "$yq_err" >&2
	exit 2
fi

# Fail-loud yq pattern (mirrors check-ssot-drift.sh:56-62 from Phase 1
# round 1, #647). The prior `2>/dev/null || echo ""` swallowed yq parse
# errors as "schema_version must equal 1" — a corrupt YAML file would
# blame the operator's content instead of surfacing the real parse
# failure. Capture stderr explicitly + check exit code; distinguishes
# field-absent (yq exit 0, empty output) from parse-failure (yq exit !=0).
_yq_or_die() {
	local expr=$1 desc=$2
	local out
	if ! out=$(yq -r "$expr" "$staged_tmp" 2>"$yq_err"); then
		echo "consumers-schema-check: yq failed parsing $REGISTRY — schema validation aborted:" >&2
		echo "  expression: $expr" >&2
		echo "  context:    $desc" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	printf '%s' "$out"
}

# 1. schema_version present and equals 1.
schema_version=$(_yq_or_die '.schema_version' 'schema_version lookup')
if [ "$schema_version" != "1" ]; then
	echo "consumers-schema-check: $REGISTRY .schema_version must equal 1 (got '$schema_version')" >&2
	exit 1
fi

# 2. consumers is a non-empty list.
consumer_count=$(_yq_or_die '.consumers | length' 'consumers list length')
if ! [[ $consumer_count =~ ^[0-9]+$ ]] || [ "$consumer_count" -lt 1 ]; then
	echo "consumers-schema-check: $REGISTRY .consumers must be a non-empty list (got '$consumer_count' entries)" >&2
	exit 1
fi

# 3. Per-consumer required fields + format checks.
errors=()
names_seen=""
required_fields="name repo local_path pinned_version overrides_file bootstrap_date contact notes"
i=0
while [ "$i" -lt "$consumer_count" ]; do
	for field in $required_fields; do
		value=$(_yq_or_die ".consumers[$i].${field}" "consumers[$i].${field} lookup")
		if [ -z "$value" ] || [ "$value" = "null" ]; then
			errors+=("consumers[$i].${field} missing or null")
		fi
	done

	name=$(_yq_or_die ".consumers[$i].name" "consumers[$i].name lookup")
	repo=$(_yq_or_die ".consumers[$i].repo" "consumers[$i].repo lookup")
	pinned=$(_yq_or_die ".consumers[$i].pinned_version" "consumers[$i].pinned_version lookup")
	bd=$(_yq_or_die ".consumers[$i].bootstrap_date" "consumers[$i].bootstrap_date lookup")

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

	# pinned_version = X.Y.Z semver. Released-versions only by design;
	# prerelease/build metadata deferred to schema v2 (Sub 13/14 #151/#152)
	# if real need emerges.
	if [ -n "$pinned" ] && [ "$pinned" != "null" ]; then
		if ! [[ $pinned =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			errors+=("consumers[$i].pinned_version '$pinned' must be X.Y.Z semver")
		fi
	fi

	# bootstrap_date = YYYY-MM-DD shape. Shape-only by design (informational
	# field); impossible dates like 2026-13-45 pass. Tightening to a real
	# calendar parse would require date(1) and BSD/GNU portability work
	# disproportionate to the field's role (never gates downstream behavior).
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
