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
# #223 r1 (silent-failure-hunter): capture `git diff` + its rc SEPARATELY so a
# genuine git failure (corrupt index, partial repo) fails CLOSED (exit 2) rather
# than being masked as "no shadow staged".
# CR-CLI r3: NUL-delimited (-z) output into a temp file so we keep that rc check
# AND iterate NUL-safely — a staged path with an embedded newline can't be split
# into two names or slip past the filter. (A temp file is the portable route:
# `grep -z` is GNU-only and bash strips NULs in $(...) command substitution.)
NAMES_TMP=$(mktemp -t stale-shadow-names.XXXXXX) || {
	echo "stale-shadow-guard: mktemp failed" >&2
	exit 2
}
# Register cleanup right after the first temp (all names :- guarded) so nothing
# leaks if a later mktemp fails (CR #478 r5).
# shellcheck disable=SC2329,SC2317  # invoked via trap registered below
_cleanup() { rm -f "${NAMES_TMP:-}" "${STAGED_TMP:-}" "${CANON_TMP:-}"; }
trap _cleanup EXIT INT TERM HUP
git diff --cached --name-only -z --diff-filter=ACMR >"$NAMES_TMP" 2>/dev/null || {
	echo "stale-shadow-guard: git diff --cached failed — refusing (fail-closed)" >&2
	exit 2
}

# Cheap early-exit when nothing under .claude/scripts|_lib is staged. The `tr`
# is for this presence check ONLY; the authoritative per-file filter is the
# NUL-safe `case` in the loop below.
_present_rc=0
tr '\0' '\n' <"$NAMES_TMP" | grep -qE '^\.claude/(scripts|_lib)/' || _present_rc=$?
if [ "$_present_rc" -eq 1 ]; then
	exit 0
elif [ "$_present_rc" -ne 0 ]; then
	echo "stale-shadow-guard: presence-check grep failed (rc=$_present_rc) — refusing (fail-closed)" >&2
	exit 2
fi

# Per-candidate staged-blob comparison against the repo-root canonical.
STAGED_TMP=$(mktemp -t stale-shadow.XXXXXX) || {
	echo "stale-shadow-guard: mktemp failed" >&2
	exit 2
}
# CR #478 p2: second temp for the STAGED canonical blob (see comparison below).
CANON_TMP=$(mktemp -t stale-shadow-canon.XXXXXX) || {
	echo "stale-shadow-guard: mktemp failed" >&2
	exit 2
}

drifts=()
while IFS= read -r -d '' shadow; do
	[ -n "$shadow" ] || continue
	# NUL-safe per-file scope filter (authoritative; the tr-grep above is only a
	# cheap presence check). Skip anything outside .claude/scripts|_lib.
	case "$shadow" in
	.claude/scripts/* | .claude/_lib/*) ;;
	*) continue ;;
	esac
	# Map shadow → canonical: strip the leading `.claude/` segment.
	canonical="${shadow#.claude/}"

	# No canonical in the INDEX ⇒ legitimately-local file, NOT a shadow (the
	# producer-local exemption, e.g. .claude/review-config.yml). CR-CLI r3: gate
	# on the index (git cat-file -e :canonical), NOT the worktree [ -f ] — keeps
	# it consistent with the staged-blob comparison below, so a canonical staged
	# but absent from the worktree (add-then-rm) is still compared.
	git cat-file -e ":${canonical}" 2>/dev/null || continue

	# Materialize the STAGED blob of the shadow (not the worktree copy) so an
	# add-then-edit can't sneak a stale copy past the gate. This guard only fires
	# in the PRODUCER (a consumer has no repo-root canonical, so the cat-file
	# check above skips it). Override a false positive with STALE_SHADOW_GUARD_SKIP=1.
	if ! git show ":${shadow}" >"$STAGED_TMP" 2>/dev/null; then
		echo "stale-shadow-guard: could not read staged blob for $shadow" >&2
		exit 2
	fi

	# CR #478 p2: compare against what's BEING COMMITTED as the canonical — the
	# STAGED canonical blob (`git show :canonical`, == HEAD's when the canonical
	# isn't itself staged) — NOT the worktree, which may carry unstaged edits the
	# staged shadow legitimately matches (a false positive).
	# CR-CLI r5: cat-file -e above already proved an index entry exists, so this
	# git show should always succeed; if it somehow fails (index corruption), fail
	# CLOSED (exit 2, mirroring the shadow-blob read) rather than fall back to the
	# worktree — a worktree copy with unstaged edits could spuriously differ and
	# report a FALSE drift.
	if ! git show ":${canonical}" >"$CANON_TMP" 2>/dev/null; then
		echo "stale-shadow-guard: could not read staged canonical blob for $canonical (unexpected — cat-file said it exists)" >&2
		exit 2
	fi
	if ! cmp -s "$STAGED_TMP" "$CANON_TMP"; then
		drifts+=("$shadow  (canonical: $canonical)")
	fi
done <"$NAMES_TMP"

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
