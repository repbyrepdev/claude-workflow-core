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
# --no-renames: with rename detection on, a staged rename of a trio file
# surfaces only under its NEW name (R) — the removal of .coderabbit.yaml
# itself would be invisible here and the gate would early-exit 0 (phase2).
if ! STAGED_ALL=$(git diff --cached --no-renames --name-only --diff-filter=ACMRDT 2>/dev/null); then
	echo "compose-coderabbit-regen: git diff --cached failed — refusing (fail-closed)" >&2
	exit 2
fi
TRIO_STAGED=$(printf '%s\n' "$STAGED_ALL" |
	grep -Ex '\.coderabbit(\.base|\.overlay)?\.yaml' || true)
[ -z "$TRIO_STAGED" ] && exit 0

# The commit ships INDEX state, so every trio input is judged by the INDEX
# alone — a worktree-only composed file (present but never staged) still
# means the commit ships base/overlay WITHOUT it (phase1 r2: the old
# tree-fallback here let exactly that false-pass).
if ! git show ":$COMPOSED_F" >"/dev/null" 2>&1; then
	echo "compose-coderabbit-regen: $TRIO_STAGED staged but $COMPOSED_F is not in the index — the commit would ship base/overlay without their composed artifact" >&2
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

# 2. Materialize the trio from the INDEX ONLY (git show :path). No worktree
# fallbacks: the commit ships index state, and a tree fallback silently
# validates content the commit does not contain (phase1 r2 silent-failure:
# a staged-DELETE of base/overlay used to recompose from the file being
# removed). Base absent from the index = refuse; overlay absent from the
# index = compose base-only (the correct post-commit semantics for a
# staged overlay deletion).
if ! git show ":$BASE_F" >"$WORK/base.yaml" 2>/dev/null; then
	echo "compose-coderabbit-regen: $BASE_F is not in the index (untracked, or staged for deletion while $COMPOSED_F is retained) — cannot recompose; refusing (fail-closed)" >&2
	exit 1
fi

# Overlay: absence and failure are DIFFERENT (CR-in-CI #2506). Index
# membership decides presence; a git show failure on a PRESENT overlay is
# a real error and must refuse, not silently degrade to base-only.
OVERLAY_ARGS=()
if git ls-files --cached --error-unmatch "$OVERLAY_F" >/dev/null 2>&1; then
	if ! git show ":$OVERLAY_F" >"$WORK/overlay.yaml" 2>/dev/null; then
		echo "compose-coderabbit-regen: $OVERLAY_F is in the index but could not be materialized (git show failed) — refusing (fail-closed)" >&2
		exit 2
	fi
	OVERLAY_ARGS=(--overlay "$WORK/overlay.yaml")
fi

# Recompose with exclusion-input parity (see header). Empty-array expansion
# under set -u aborts on bash 3.2 (macOS /bin/bash; fixed only in 4.4), so
# the base-only path uses the ${arr[@]+...} guard idiom.
if ! COMPOSE_CR_CONSUMER_HOOKS_DIR="$REPO_ROOT/.claude/hooks" \
	COMPOSE_CR_CONSUMER_LIB_DIR="$REPO_ROOT/.claude/_lib" \
	bash "$COMPOSE_SH" --base "$WORK/base.yaml" ${OVERLAY_ARGS[@]+"${OVERLAY_ARGS[@]}"} \
	--out "$WORK/composed.yaml" >"$WORK/compose.log" 2>&1; then
	echo "compose-coderabbit-regen: recompose FAILED — the staged base/overlay do not compose:" >&2
	cat "$WORK/compose.log" >&2
	exit 2
fi

# 3. Staged composed vs fresh recompose — BYTE-exact via cmp (a $(...)
# capture strips trailing newlines on both sides, masking a trailing-
# whitespace hand-edit; phase1 r2 silent-failure).
if ! git show ":$COMPOSED_F" >"$WORK/staged-composed.yaml" 2>/dev/null; then
	# Unreachable in practice (step-1 guard already required it) — belt and
	# suspenders for a mid-run index mutation.
	echo "compose-coderabbit-regen: $COMPOSED_F vanished from the index mid-run — refusing" >&2
	exit 2
fi
if ! cmp -s "$WORK/staged-composed.yaml" "$WORK/composed.yaml"; then
	echo "compose-coderabbit-regen: $COMPOSED_F drifts from compose($BASE_F, $OVERLAY_F)" >&2
	echo "  (stale composed after a base/overlay edit, or a hand-edit to the composed artifact)" >&2
	echo "" >&2
	_ovl_hint=""
	[ "${#OVERLAY_ARGS[@]}" -gt 0 ] && _ovl_hint=" --overlay $OVERLAY_F"
	echo "  Fix: scripts/compose-coderabbit.sh --base $BASE_F$_ovl_hint --out $COMPOSED_F && git add $COMPOSED_F" >&2
	echo "  Bypass (audit-log): COMPOSE_CR_REGEN_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
