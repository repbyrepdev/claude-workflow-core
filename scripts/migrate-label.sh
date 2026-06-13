#!/bin/bash
set -euo pipefail
# migrate-label.sh — rename a GitHub label across all four SSOT sites (#2288 of
# #2286 / #2278). One-shot, idempotent, --dry-run-able.
#
# Renames <old> -> <new> in:
#   1. .github/labels.yml          — the label-EXISTENCE SSOT (seq of {name,...})
#   2. .github/labeler.yml         — the path-to-label SSOT (top-level <label>: key)
#   3. .coderabbit.overlay.yaml    — the CR suggestion layer (reviews.labeling_instructions[].label)
#   4. GitHub label state          — `gh label edit <old> --name <new>` (preserves
#                                     existing assignments on issues/PRs)
#
# Steps 1-3 are no-ops when <old> is absent from that file (idempotent — a
# partially-applied migration completes cleanly on re-run). Step 4 is skipped
# when <old> does not exist as a GitHub label OR <new> already does.
#
# Works in the plugin OR any consumer (it edits whatever SSOT files are present
# in the current repo). Run from the repo whose labels you are renaming.
#
# Usage:
#   scripts/migrate-label.sh --old <label> --new <label> [--dry-run]
#   scripts/migrate-label.sh --help
#
# Exit codes:
#   0 — migration applied (or --dry-run plan shown, or already-migrated no-op)
#   2 — usage / precondition error (bad args, yq/gh missing, not a git tree)

# Print the leading comment block (everything after the shebang+set line, up to
# the first non-comment line) as help. Robust to line-number shifts.
usage() {
	awk 'NR>2 && /^#/ {sub(/^# ?/, ""); print; next} NR>2 {exit}' "$0"
}

OLD=""
NEW=""
DRY_RUN=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--old)
		OLD="${2:-}"
		shift 2 || {
			echo "migrate-label: --old needs a value" >&2
			exit 2
		}
		;;
	--new)
		NEW="${2:-}"
		shift 2 || {
			echo "migrate-label: --new needs a value" >&2
			exit 2
		}
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--help | -h)
		usage
		exit 0
		;;
	*)
		echo "migrate-label: unknown arg '$1'" >&2
		exit 2
		;;
	esac
done

if [ -z "$OLD" ] || [ -z "$NEW" ]; then
	echo "migrate-label: both --old and --new are required" >&2
	exit 2
fi
if [ "$OLD" = "$NEW" ]; then
	echo "migrate-label: --old and --new are identical ('$OLD') — nothing to do" >&2
	exit 2
fi

command -v yq >/dev/null 2>&1 || {
	echo "migrate-label: yq not installed — refusing (precondition)" >&2
	exit 2
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "migrate-label: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

# Export so yq's strenv(OLD)/strenv(NEW) resolve in every child invocation
# (a var-assignment prefix on a shell-function call is not seen by the
# function's own child processes — shellcheck SC2097/SC2098).
export OLD NEW

DRY_LABEL=""
[ "$DRY_RUN" = "1" ] && DRY_LABEL=" (dry-run)"

_act() {
	# _act "<description>" "<command...>" — run, or (in dry-run) just announce.
	local desc="$1"
	shift
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would: $desc"
	else
		echo "  $desc"
		"$@"
	fi
}

echo "migrate-label: $OLD -> $NEW$DRY_LABEL"

# 1. labels.yml — rename the name field of the matching seq entry.
LABELS=".github/labels.yml"
if [ -f "$LABELS" ] && yq -e '.[] | select(.name == strenv(OLD))' "$LABELS" >/dev/null 2>&1; then
	_act "labels.yml: rename name $OLD -> $NEW" \
		yq -i '(.[] | select(.name == strenv(OLD)) | .name) = strenv(NEW)' "$LABELS"
else
	echo "  labels.yml: $OLD absent — skip"
fi

# 2. labeler.yml — rename the top-level <label> key (order is cosmetic for a
#    label->glob map; the renamed key is re-appended).
LABELER=".github/labeler.yml"
if [ -f "$LABELER" ] && yq -e '.[strenv(OLD)]' "$LABELER" >/dev/null 2>&1; then
	_act "labeler.yml: rename key $OLD -> $NEW" \
		yq -i '.[strenv(NEW)] = .[strenv(OLD)] | del(.[strenv(OLD)])' "$LABELER"
else
	echo "  labeler.yml: $OLD absent — skip"
fi

# 3. .coderabbit.overlay.yaml — rename any labeling_instructions[].label.
OVERLAY=".coderabbit.overlay.yaml"
if [ -f "$OVERLAY" ] && yq -e '(.reviews.labeling_instructions // [])[] | select(.label == strenv(OLD))' "$OVERLAY" >/dev/null 2>&1; then
	_act "overlay: rename labeling_instructions label $OLD -> $NEW" \
		yq -i '(.reviews.labeling_instructions[] | select(.label == strenv(OLD)) | .label) = strenv(NEW)' "$OVERLAY"
else
	echo "  overlay: $OLD absent — skip"
fi

# 4. GitHub label state — rename via API (preserves assignments). Skip if gh
#    unavailable, if <old> is not a label, or if <new> already exists.
if ! command -v gh >/dev/null 2>&1; then
	echo "  gh label: gh not installed — skip API rename (edit files only)"
elif ! gh label list --limit 500 --json name --jq '.[].name' 2>/dev/null | grep -qxF "$OLD"; then
	echo "  gh label: $OLD not a GitHub label — skip"
elif gh label list --limit 500 --json name --jq '.[].name' 2>/dev/null | grep -qxF "$NEW"; then
	echo "  gh label: $NEW already exists — skip API rename (reconcile manually)"
else
	_act "gh label: edit $OLD --name $NEW (preserves assignments)" \
		gh label edit "$OLD" --name "$NEW"
fi

if [ "$DRY_RUN" = "1" ]; then
	echo "migrate-label: done (dry-run — no changes applied)"
else
	echo "migrate-label: done"
fi
