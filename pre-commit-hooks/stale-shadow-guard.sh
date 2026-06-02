#!/bin/bash
set -euo pipefail
# (#223) Pre-commit gate: block a DRIFTING shadow of a plugin-canonical helper.
#
# _lib/resolve-plugin-helper.sh resolves a helper by checking the consumer's
# $REPO_ROOT/.claude/<rel> copy BEFORE the canonical $plugin_root/<rel>. That
# consumer-first order is intentional (it preserves overrides), but it means a
# STALE local copy of a helper SILENTLY shadows the SSOT — and these helper
# paths are NOT tracked in .claude/.source-hashes.json, so hash-drift never
# catches them. A stale .claude/scripts/copilot/try-free.sh once shadowed the
# fixed canonical undetected and broke the copilot prefilter.
#
# This gate fires when a repo ships a `.claude/scripts/**` or `.claude/_lib/**`
# file that DUPLICATES a plugin-canonical helper AND DIFFERS from it (a
# drifting shadow). The canonical for a staged `.claude/<rel>` is the
# repo-root `<rel>` (i.e. `.claude/scripts/copilot/try-free.sh` ⇒
# `scripts/copilot/try-free.sh`) — the exact inverse of the resolver's
# `$plugin_root/<rel>` ↔ `$REPO_ROOT/.claude/<rel>` mapping.
#
# It does NOT fire when no canonical exists at the repo-root path. That is the
# producer's legitimately-local case (e.g. `.claude/review-config.yml`, whose
# only copy lives under .claude/ with no top-level sibling) — though such files
# also sit directly under .claude/ and are out of the scripts/**|_lib/** scope
# anyway. The "canonical must exist" guard is the load-bearing exemption.
#
# Identical copies are allowed (a non-drifting mirror is harmless; only DRIFT
# is dangerous). The staged blob is compared, not the worktree file, so an
# add-then-edit can't slip a stale copy past the gate.
#
# Bypass: STALE_SHADOW_GUARD_SKIP=1 (audit-logged to stderr — for a genuine,
# reviewed intentional override; prefer deleting the shadow so the canonical
# SSOT resolves).
#
# Exit codes:
#   0 — passed (no shadow staged, OR shadow has no canonical, OR shadow ==
#       canonical, OR bypass)
#   1 — a staged shadow DIFFERS from its plugin canonical (drift)
#   2 — precondition error (not in a git repo, mktemp/git-show failure)

if [ "${STALE_SHADOW_GUARD_SKIP:-0}" = "1" ]; then
	echo "stale-shadow-guard: STALE_SHADOW_GUARD_SKIP=1 — bypassing (audit-logged)" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "stale-shadow-guard: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

# Staged shadow candidates: .claude/scripts/** or .claude/_lib/** (any depth).
# --diff-filter=ACMR (added/copied/modified/renamed) — a deletion removes a
# shadow and can't drift, so it's not a candidate.
STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null |
	grep -E '^\.claude/(scripts|_lib)/' || true)

if [ -z "$STAGED" ]; then
	exit 0
fi

# Per-candidate staged-blob comparison against the repo-root canonical.
STAGED_TMP=$(mktemp -t stale-shadow.XXXXXX) || {
	echo "stale-shadow-guard: mktemp failed" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317  # invoked via trap registered below
_cleanup() { rm -f "$STAGED_TMP"; }
trap _cleanup EXIT INT TERM HUP

drifts=()
while IFS= read -r shadow; do
	[ -n "$shadow" ] || continue
	# Map shadow → canonical: strip the leading `.claude/` segment.
	canonical="${shadow#.claude/}"

	# No canonical at the repo root ⇒ legitimately-local file, NOT a shadow.
	# This is the producer-local exemption (e.g. .claude/review-config.yml).
	[ -f "$canonical" ] || continue

	# Materialize the STAGED blob of the shadow (not the worktree copy) so an
	# add-then-edit can't sneak a stale copy past the gate. Compare against the
	# canonical's WORKTREE content intentionally: this guard only fires in the
	# PRODUCER (a consumer has no repo-root canonical, so the `-f` check above
	# skips it), where the canonical IS the live SSOT a shadow must match — its
	# index/staged state is irrelevant. Override a false positive with
	# STALE_SHADOW_GUARD_SKIP=1.
	if ! git show ":${shadow}" >"$STAGED_TMP" 2>/dev/null; then
		echo "stale-shadow-guard: could not read staged blob for $shadow" >&2
		exit 2
	fi

	if ! cmp -s "$STAGED_TMP" "$canonical"; then
		drifts+=("$shadow  (canonical: $canonical)")
	fi
done <<<"$STAGED"

if [ ${#drifts[@]} -gt 0 ]; then
	echo "stale-shadow-guard: ${#drifts[@]} drifting shadow(s) of plugin-canonical helper(s):" >&2
	for d in "${drifts[@]}"; do
		echo "  - $d" >&2
	done
	echo "" >&2
	echo "A .claude/scripts|_lib copy that DIFFERS from its repo-root canonical" >&2
	echo "silently shadows the SSOT via _lib/resolve-plugin-helper.sh (these" >&2
	echo "paths are NOT hash-tracked, so drift goes uncaught — #223)." >&2
	echo "" >&2
	echo "  Fix: delete the stale shadow so the canonical resolves, OR re-sync" >&2
	echo "       it byte-for-byte with its canonical." >&2
	echo "  Bypass (reviewed intentional override, audit-log):" >&2
	echo "       STALE_SHADOW_GUARD_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
