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
# Scope: CONSUMER repos only. The plugin source (identified by a
# .claude-plugin/plugin.json whose name == claude-workflow-core) deliberately
# ships NO domain labeling_instructions in its overlay (#2256: the base ships
# only the universal area:infrastructure), so the gate skips it. The name pin
# (not mere manifest presence) keeps a consumer that is ALSO a Claude plugin
# enforced rather than silently un-gated.
#
# Wiring: registered in .pre-commit-hooks.yaml (id: overlay-label-completeness)
# with pass_filenames:false and NO `files:` filter, so it runs on EVERY
# pre-commit and self-gates at runtime — exiting 0 when neither
# .coderabbit.overlay.yaml nor .github/labels.yml is tracked in the index. It
# reads the STAGED blobs (git show :path) so it validates what is being
# committed, not unstaged working-tree WIP — the project pre-commit pattern
# (cf. consumers-schema-check, #2287 CR phase2).
#
# Bypass: OVERLAY_LABEL_COMPLETENESS_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (plugin-source skip, overlay/labels not in index, or sets match)
#   1 — completeness drift (overlay domain set != labels.yml domain set)
#   2 — precondition error (yq missing, not a git tree, staged-read/parse
#       failure, or a labels.yml that is not a top-level sequence)

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

# Plugin-source skip — name-pinned (not just any .claude-plugin/plugin.json) so
# a consumer that is itself a Claude plugin is still enforced. Announced to
# stderr (parity with the bypass-env log) so the skip is never a silent no-op.
if [ -f .claude-plugin/plugin.json ]; then
	plugin_name=$(yq -r '.name // ""' .claude-plugin/plugin.json 2>/dev/null || echo "")
	if [ "$plugin_name" = "claude-workflow-core" ]; then
		echo "overlay-label-completeness: plugin source ($plugin_name) — skipping (base ships only the universal area:infrastructure, #2256)" >&2
		exit 0
	fi
fi

OVERLAY=".coderabbit.overlay.yaml"
LABELS=".github/labels.yml"

# Out of scope (not drift) when either SSOT is absent from the index. `git
# cat-file -e :path` tests index presence; the staged blob is what this commit
# would record (== HEAD when the file is unmodified), so the gate validates the
# committed state rather than unstaged WIP.
git cat-file -e ":$OVERLAY" 2>/dev/null || exit 0
git cat-file -e ":$LABELS" 2>/dev/null || exit 0

labels_staged=$(git show ":$LABELS") || {
	echo "overlay-label-completeness: cannot read staged $LABELS — refusing (precondition)" >&2
	exit 2
}
overlay_staged=$(git show ":$OVERLAY") || {
	echo "overlay-label-completeness: cannot read staged $OVERLAY — refusing (precondition)" >&2
	exit 2
}

# Shape-assert: labels.yml MUST be a top-level sequence. A valid-YAML mapping
# (e.g. a label-object map) makes `.[].name` emit "null" with rc=0, which would
# silently collapse to an empty domain set and mask drift (silent-failure-hunter
# r1, dogfood-confirmed: yq v4 `.[].name` over a !!map => "null", rc=0). Treat a
# non-sequence (or unparseable) labels.yml as a precondition error, not empty.
labels_tag=$(printf '%s\n' "$labels_staged" | yq -r '. | tag' 2>/dev/null || echo "")
if [ "$labels_tag" != "!!seq" ]; then
	echo "overlay-label-completeness: staged $LABELS is not a top-level sequence (tag='$labels_tag') — refusing (precondition)" >&2
	exit 2
fi

# Shared domain-label filter: area:*/type:* names, EXCLUDING the universal
# area:infrastructure. An empty result is VALID (a repo may define no domain
# labels) — `|| true` so the no-match grep rc=1 under pipefail does not abort.
_domain_filter() {
	grep -E '^(area|type):' | grep -vx 'area:infrastructure' | sort -u || true
}

# Separate the yq parse (genuine failure => precondition rc=2) from the domain
# filter (empty == valid). labels.yml is already shape-asserted as a sequence.
labels_raw=$(printf '%s\n' "$labels_staged" | yq -r '.[].name') || {
	echo "overlay-label-completeness: failed to parse staged $LABELS — refusing (precondition)" >&2
	exit 2
}
labels_domain=$(printf '%s\n' "$labels_raw" | _domain_filter)

# overlay set: reviews.labeling_instructions[].label. `(... // [])` so an
# overlay with no labeling_instructions yields an empty set (not a yq error).
overlay_raw=$(printf '%s\n' "$overlay_staged" | yq -r '(.reviews.labeling_instructions // [])[].label') || {
	echo "overlay-label-completeness: failed to parse staged $OVERLAY — refusing (precondition)" >&2
	exit 2
}
overlay_domain=$(printf '%s\n' "$overlay_raw" | _domain_filter)

# Bidirectional set-diff. The `grep -vE '^$'` keeps comm inputs clean when a set
# is empty (`printf '%s\n' ""` emits one blank line); both sets are sort -u'd.
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
