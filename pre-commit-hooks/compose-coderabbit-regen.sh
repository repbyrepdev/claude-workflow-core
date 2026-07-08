#!/bin/bash
set -euo pipefail
# (#2402) Pre-commit gate: .coderabbit.yaml must equal
# compose(.coderabbit.base.yaml, .coderabbit.overlay.yaml).
#
# The composed .coderabbit.yaml is per-repo (NOT hashed, NOT in
# bootstrap-manifest.yml) and was covered by NO gate, so a base/overlay
# edit committed without re-running scripts/compose-coderabbit.sh silently
# shipped a stale composed config — caught (if ever) only when CR behaved
# unexpectedly. This gate catches the drift AT THE COMMIT that introduces
# it, mirroring source-hashes-regen-gate's staged-blob discipline.
#
# Algorithm:
#   1. Fire only when .coderabbit.base.yaml, .coderabbit.overlay.yaml, or
#      .coderabbit.yaml is staged.
#   2. Materialize the STAGED blobs (git show :path) of base + overlay to
#      temps — edits-since-stage robustness — and recompose to a temp out.
#      Exclusion-input parity (#2254/#2257 caveat): compose resolves the
#      consumer hooks/_lib dirs from dirname(--out), which for a temp out
#      would be $TMPDIR — so the repo's REAL consumer dirs are pinned via
#      COMPOSE_CR_CONSUMER_{HOOKS,LIB}_DIR (canonical dirs stay
#      script-sibling-resolved, correct in both the plugin repo and the
#      consumer cache). The exclusion pass compares LIVE hook trees on both
#      sides — same inputs the canonical regen used — so it cannot
#      false-positive on staged-vs-live skew of the yaml trio itself.
#   3. Compare the recompose to the STAGED .coderabbit.yaml blob. Any
#      difference (stale composed, hand-edited composed, composed missing
#      from the index) refuses the commit with the regen command.
#
# Bypass: COMPOSE_CR_REGEN_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (trio untouched, OR staged composed matches the recompose)
#   1 — drift: staged composed differs from compose(staged base, staged overlay)
#   2 — precondition error (compose script missing/failed, git index error)

if [ "${COMPOSE_CR_REGEN_SKIP:-0}" = "1" ]; then
	echo "compose-coderabbit-regen: COMPOSE_CR_REGEN_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "compose-coderabbit-regen: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

BASE_F=".coderabbit.base.yaml"
OVERLAY_F=".coderabbit.overlay.yaml"
COMPOSED_F=".coderabbit.yaml"

# 1. Trio staged? Fail-closed on index errors (a masked git failure would
# read as "nothing staged" → exit 0 false-pass).
if ! STAGED_ALL=$(git diff --cached --name-only --diff-filter=ACMRD 2>/dev/null); then
	echo "compose-coderabbit-regen: git diff --cached failed — refusing (fail-closed)" >&2
	exit 2
fi
TRIO_STAGED=$(printf '%s\n' "$STAGED_ALL" |
	grep -Ex '\.coderabbit(\.base|\.overlay)?\.yaml' || true)
[ -z "$TRIO_STAGED" ] && exit 0

# A repo without a composed config (base-only starter) has nothing to gate
# UNTIL it composes one; but base/overlay staged while the composed file is
# absent from BOTH index and tree means the operator forgot the compose step
# entirely — treat as drift, not as a starter.
if ! git ls-files --error-unmatch "$COMPOSED_F" >/dev/null 2>&1 &&
	[ ! -f "$COMPOSED_F" ]; then
	echo "compose-coderabbit-regen: $TRIO_STAGED staged but $COMPOSED_F does not exist (tree or index)" >&2
	echo "  Fix: scripts/compose-coderabbit.sh --base $BASE_F --overlay $OVERLAY_F --out $COMPOSED_F && git add $COMPOSED_F" >&2
	exit 1
fi

# Locate the compose script: repo-local (plugin repo) or the pinned plugin
# cache (consumer repo running the shared pre-commit hook set).
COMPOSE_SH="$REPO_ROOT/scripts/compose-coderabbit.sh"
if [ ! -x "$COMPOSE_SH" ]; then
	_hook_self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || _hook_self_dir=""
	if [ -n "$_hook_self_dir" ] && [ -x "$_hook_self_dir/../scripts/compose-coderabbit.sh" ]; then
		COMPOSE_SH="$_hook_self_dir/../scripts/compose-coderabbit.sh"
	fi
fi
if [ ! -x "$COMPOSE_SH" ]; then
	echo "compose-coderabbit-regen: compose-coderabbit.sh not found (repo scripts/ or plugin cache) — refusing" >&2
	exit 2
fi

WORK=$(mktemp -d -t cr-regen.XXXXXX) || {
	echo "compose-coderabbit-regen: mktemp failed" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317  # invoked via trap
_cleanup_work() { rm -rf "$WORK" 2>/dev/null || true; }
trap _cleanup_work EXIT INT TERM HUP

# 2. Staged blobs. Base: index version, else tree version (base not staged
# in this commit but present). Overlay: optional — absent from index AND
# tree means compose runs base-only.
if git ls-files --error-unmatch "$BASE_F" >/dev/null 2>&1 || git diff --cached --name-only | grep -qFx "$BASE_F"; then
	if ! git show ":$BASE_F" >"$WORK/base.yaml" 2>/dev/null; then
		# Not in index (e.g. tracked-but-renamed edge) — fall back to the tree.
		cp "$BASE_F" "$WORK/base.yaml" 2>/dev/null || {
			echo "compose-coderabbit-regen: cannot materialize $BASE_F (index or tree) — refusing" >&2
			exit 2
		}
	fi
else
	echo "compose-coderabbit-regen: $BASE_F not tracked — cannot recompose; refusing (fail-closed)" >&2
	exit 2
fi

OVERLAY_ARGS=()
if git show ":$OVERLAY_F" >"$WORK/overlay.yaml" 2>/dev/null; then
	OVERLAY_ARGS=(--overlay "$WORK/overlay.yaml")
elif [ -f "$OVERLAY_F" ]; then
	cp "$OVERLAY_F" "$WORK/overlay.yaml"
	OVERLAY_ARGS=(--overlay "$WORK/overlay.yaml")
fi

# Recompose with exclusion-input parity (see header).
if ! COMPOSE_CR_CONSUMER_HOOKS_DIR="$REPO_ROOT/.claude/hooks" \
	COMPOSE_CR_CONSUMER_LIB_DIR="$REPO_ROOT/.claude/_lib" \
	bash "$COMPOSE_SH" --base "$WORK/base.yaml" "${OVERLAY_ARGS[@]}" \
	--out "$WORK/composed.yaml" >"$WORK/compose.log" 2>&1; then
	echo "compose-coderabbit-regen: recompose FAILED — the staged base/overlay do not compose:" >&2
	cat "$WORK/compose.log" >&2
	exit 2
fi

# 3. Staged composed vs fresh recompose.
STAGED_COMPOSED=$(git show ":$COMPOSED_F" 2>/dev/null || cat "$COMPOSED_F" 2>/dev/null || echo "")
FRESH_COMPOSED=$(cat "$WORK/composed.yaml")

if [ "$STAGED_COMPOSED" != "$FRESH_COMPOSED" ]; then
	echo "compose-coderabbit-regen: $COMPOSED_F drifts from compose($BASE_F, $OVERLAY_F)" >&2
	echo "  (stale composed after a base/overlay edit, or a hand-edit to the composed artifact)" >&2
	echo "" >&2
	echo "  Fix: scripts/compose-coderabbit.sh --base $BASE_F${OVERLAY_ARGS:+ --overlay $OVERLAY_F} --out $COMPOSED_F && git add $COMPOSED_F" >&2
	echo "  Bypass (audit-log): COMPOSE_CR_REGEN_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
