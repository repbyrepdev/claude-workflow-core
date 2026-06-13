#!/bin/bash
set -euo pipefail
# overlay-label-completeness — pre-commit gate (#2287 of #2286 / #2278).
#
# Asserts a CONSUMER's CodeRabbit suggestion-layer overlay declares a
# labeling_instructions entry for EVERY domain label (area:*/type:*) defined in
# its .github/labels.yml, excluding the universal area:infrastructure (which the
# plugin base ships). Makes overlay-label completeness DETERMINISTIC at commit
# time rather than relying on CR-in-CI to notice a missing label.
#
# Scope: CONSUMER repos only. The plugin source (identified by its
# .claude-plugin/plugin.json manifest) deliberately ships NO domain
# labeling_instructions in its overlay (#2256: the base ships only the
# universal area:infrastructure), so the gate skips it.
#
# Wiring: registered in .pre-commit-hooks.yaml (id: overlay-label-completeness);
# runs when .coderabbit.overlay.yaml or .github/labels.yml is staged.
#
# Bypass: OVERLAY_LABEL_COMPLETENESS_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (plugin-source skip, missing overlay/labels SSOT, or sets match)
#   1 — completeness drift (overlay domain set != labels.yml domain set)
#   2 — precondition error (yq missing, not a git tree, parse failure)

if [ "${OVERLAY_LABEL_COMPLETENESS_SKIP:-0}" = "1" ]; then
	echo "overlay-label-completeness: OVERLAY_LABEL_COMPLETENESS_SKIP=1 — bypassing" >&2
	exit 0
fi

command -v yq >/dev/null 2>&1 || {
	echo "overlay-label-completeness: yq not installed — refusing (precondition)" >&2
	exit 2
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "overlay-label-completeness: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

# Plugin-source skip: the plugin deliberately ships only the universal
# area:infrastructure label and NO domain labeling_instructions (#2256), so
# overlay-vs-labels completeness does not apply to it.
if [ -f .claude-plugin/plugin.json ]; then
	exit 0
fi

OVERLAY=".coderabbit.overlay.yaml"
LABELS=".github/labels.yml"

# A repo without a CR overlay or a labels registry is out of scope (not drift).
[ -f "$OVERLAY" ] || exit 0
[ -f "$LABELS" ] || exit 0

# labels.yml domain set: area:*/type:* names, EXCLUDING the universal
# area:infrastructure (plugin-base-shipped, not a consumer domain label).
# Separate the yq parse (genuine failure => precondition rc=2) from the grep
# filter (an empty result is VALID — a repo may define no domain labels).
labels_raw=$(yq -r '.[].name' "$LABELS") || {
	echo "overlay-label-completeness: failed to parse $LABELS — refusing (precondition)" >&2
	exit 2
}
labels_domain=$(printf '%s\n' "$labels_raw" | grep -E '^(area|type):' | grep -vx 'area:infrastructure' | sort -u || true)

# overlay set: reviews.labeling_instructions[].label. `(... // [])` so an
# overlay with no labeling_instructions yields an empty set (not a yq error).
overlay_raw=$(yq -r '(.reviews.labeling_instructions // [])[].label' "$OVERLAY") || {
	echo "overlay-label-completeness: failed to parse $OVERLAY — refusing (precondition)" >&2
	exit 2
}
overlay_domain=$(printf '%s\n' "$overlay_raw" | grep -E '^(area|type):' | grep -vx 'area:infrastructure' | sort -u || true)

# Bidirectional set-diff (empty-line filter keeps comm inputs clean when a set
# is empty; both inputs are already sort -u'd).
missing_from_overlay=$(comm -23 <(printf '%s\n' "$labels_domain" | grep -vE '^$' || true) <(printf '%s\n' "$overlay_domain" | grep -vE '^$' || true))
extra_in_overlay=$(comm -13 <(printf '%s\n' "$labels_domain" | grep -vE '^$' || true) <(printf '%s\n' "$overlay_domain" | grep -vE '^$' || true))

if [ -z "$missing_from_overlay" ] && [ -z "$extra_in_overlay" ]; then
	exit 0
fi

echo "overlay-label-completeness: $OVERLAY labeling_instructions drifted from $LABELS domain labels (area:*/type:*, excl area:infrastructure):" >&2
if [ -n "$missing_from_overlay" ]; then
	echo "  MISSING from overlay (defined in labels.yml, no labeling_instructions):" >&2
	printf '%s\n' "$missing_from_overlay" | sed 's/^/    /' >&2
fi
if [ -n "$extra_in_overlay" ]; then
	echo "  EXTRA in overlay (labeling_instructions for a label absent from labels.yml):" >&2
	printf '%s\n' "$extra_in_overlay" | sed 's/^/    /' >&2
fi
echo "  Fix: add semantic labeling_instructions for the MISSING labels (no path-globs — defer paths to .github/labeler.yml), or reconcile the EXTRA ones against .github/labels.yml." >&2
exit 1
