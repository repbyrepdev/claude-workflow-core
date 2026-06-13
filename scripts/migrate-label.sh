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
# Per file site (1-3): no-op when <old> is absent (idempotent — a partially
# applied migration completes cleanly on re-run); REFUSE (exit 2) on a target
# that is not parseable YAML (a parse error is never silently treated as
# "absent"); and SKIP with a reconcile warning when <new> already exists at
# that site, so a rename never clobbers an existing <new>. Step 4 skips when
# <old> is not a GitHub label or <new> already exists, and EXITS 2 if the
# GitHub API cannot be reached (an API failure is never reported as success).
#
# Requires the mikefarah implementation of yq (uses strenv() and -i, which the
# python/jq-wrapper yq does not support). Works in the plugin OR any consumer;
# run it from the repo whose labels you are renaming.
#
# Usage:
#   scripts/migrate-label.sh --old <label> --new <label> [--dry-run]
#   scripts/migrate-label.sh --help
#
# Exit codes:
#   0 — migration applied (or --dry-run plan shown, or already-migrated no-op;
#       a missing gh degrades to file-only edits and still exits 0)
#   2 — usage / precondition error (bad args; yq missing or not mikefarah; not
#       a git tree; a target file that is not valid YAML; gh API unreachable)

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
# The yq expressions below (strenv(), in-place -i) are mikefarah-specific; a
# python/kislyuk yq on PATH would error on them. Without this check those
# errors would be swallowed by the per-site existence probes and every site
# would silently report "absent — skip" while changing nothing.
yq --version 2>&1 | grep -qi mikefarah || {
	echo "migrate-label: requires the mikefarah yq (a different yq is on PATH) — refusing" >&2
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
	# In apply mode the description prints AFTER the command succeeds, so a
	# failing command (which aborts under set -e) never emits a line that reads
	# as a completed action.
	local desc="$1"
	shift
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would: $desc"
	else
		"$@"
		echo "  $desc"
	fi
}

_require_yaml() {
	# Refuse (exit 2) when $1 is not parseable YAML, so a malformed/corrupt
	# target file is a hard precondition error rather than a silent "absent —
	# skip". `yq 'true'` (no -e) exits 0 on any successful parse — including an
	# empty doc — and non-zero only on a genuine parse failure.
	yq 'true' "$1" >/dev/null 2>&1 || {
		echo "migrate-label: $1 is not valid YAML — refusing (precondition)" >&2
		exit 2
	}
}

echo "migrate-label: $OLD -> $NEW$DRY_LABEL"

# 1. labels.yml — rename the name field of the matching seq entry.
LABELS=".github/labels.yml"
if [ ! -f "$LABELS" ]; then
	echo "  labels.yml: file absent — skip"
else
	_require_yaml "$LABELS"
	if ! yq -e '.[] | select(.name == strenv(OLD))' "$LABELS" >/dev/null 2>&1; then
		echo "  labels.yml: $OLD absent — skip"
	elif yq -e '.[] | select(.name == strenv(NEW))' "$LABELS" >/dev/null 2>&1; then
		echo "  labels.yml: $NEW already exists — skip (reconcile manually)"
	else
		_act "labels.yml: rename name $OLD -> $NEW" \
			yq -i '(.[] | select(.name == strenv(OLD)) | .name) = strenv(NEW)' "$LABELS"
	fi
fi

# 2. labeler.yml — rename the top-level <label> key (order is cosmetic for a
#    label->glob map; the renamed key is re-appended).
LABELER=".github/labeler.yml"
if [ ! -f "$LABELER" ]; then
	echo "  labeler.yml: file absent — skip"
else
	_require_yaml "$LABELER"
	if ! yq -e '.[strenv(OLD)]' "$LABELER" >/dev/null 2>&1; then
		echo "  labeler.yml: $OLD absent — skip"
	elif yq -e '.[strenv(NEW)]' "$LABELER" >/dev/null 2>&1; then
		echo "  labeler.yml: $NEW already exists — skip (reconcile manually)"
	else
		_act "labeler.yml: rename key $OLD -> $NEW" \
			yq -i '.[strenv(NEW)] = .[strenv(OLD)] | del(.[strenv(OLD)])' "$LABELER"
	fi
fi

# 3. .coderabbit.overlay.yaml — rename any labeling_instructions[].label.
OVERLAY=".coderabbit.overlay.yaml"
if [ ! -f "$OVERLAY" ]; then
	echo "  overlay: file absent — skip"
else
	_require_yaml "$OVERLAY"
	if ! yq -e '(.reviews.labeling_instructions // [])[] | select(.label == strenv(OLD))' "$OVERLAY" >/dev/null 2>&1; then
		echo "  overlay: $OLD absent — skip"
	elif yq -e '(.reviews.labeling_instructions // [])[] | select(.label == strenv(NEW))' "$OVERLAY" >/dev/null 2>&1; then
		echo "  overlay: $NEW already exists — skip (reconcile manually)"
	else
		_act "overlay: rename labeling_instructions label $OLD -> $NEW" \
			yq -i '(.reviews.labeling_instructions[] | select(.label == strenv(OLD)) | .label) = strenv(NEW)' "$OVERLAY"
	fi
fi

# 4. GitHub label state — rename via API (preserves assignments). The label set
#    is fetched ONCE (no double call, no SIGPIPE-from-grep-q race) and a list
#    failure is a hard error: gh's stderr is NOT suppressed and an auth/network
#    failure exits 2 rather than being misread as "label absent" + silent success.
if ! command -v gh >/dev/null 2>&1; then
	echo "  gh label: gh not installed — skip API rename (edit files only)"
else
	gh_names=$(gh label list --limit 500 --json name --jq '.[].name') || {
		echo "migrate-label: gh label list failed (auth/network?) — cannot reconcile GitHub label state" >&2
		exit 2
	}
	if ! grep -qxF "$OLD" <<<"$gh_names"; then
		echo "  gh label: $OLD not a GitHub label — skip"
	elif grep -qxF "$NEW" <<<"$gh_names"; then
		echo "  gh label: $NEW already exists — skip API rename (reconcile manually)"
	else
		_act "gh label: edit $OLD --name $NEW (preserves assignments)" \
			gh label edit "$OLD" --name "$NEW"
	fi
fi

if [ "$DRY_RUN" = "1" ]; then
	echo "migrate-label: done (dry-run — no changes applied)"
else
	echo "migrate-label: done"
fi
