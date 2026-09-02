#!/bin/bash
set -euo pipefail
# v4.24-P (#603) — commit-time gate: refuse staged .sh files that use
# bash 4.0+ features with `#!/bin/bash` shebang. macOS bash 3.2 would
# silently fail on those features at runtime.
#
# Rule lives in .claude/_lib/bash4-features-check.sh — same lib consumed
# by .claude/hooks/bash4-features-write-guard.sh (PreToolUse Write/Edit/MultiEdit gate).
# Two gates, one source.

# shellcheck disable=SC2034  # REPO_ROOT kept for ABI; consumer-repo paths set via plugin-relative _lib lookup

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LIB="$(dirname "$0")/../_lib/bash4-features-check.sh"
# Fail-open on fresh clone where the shared lib isn't present yet. Matches the
# sibling .claude/hooks/bash4-features-write-guard.sh fail-open (both gates
# degrade gracefully; at least one enforces as soon as the lib is checked in).
[ -f "$LIB" ] || exit 0
# shellcheck source=../_lib/bash4-features-check.sh
. "$LIB"
# v0.34.31 (#2235): consumer-aware canonical-skip — no-op in the plugin itself.
_CCS="$(dirname "$0")/../_lib/canonical-consumer-skip.sh"
# shellcheck source=../_lib/canonical-consumer-skip.sh
[ -f "$_CCS" ] && . "$_CCS"

# Added AND modified .sh files (#2645 — was --diff-filter=A). The old
# added-only grandfathering meant a bash-4 feature could be EDITED INTO a
# tracked file forever unchecked; the anchor regression class (#2644's
# `a788b2f`, the CR-autofix mapfile in phase1-launcher) enters exactly that
# way. No flag day: with comment-line stripping hoisted into the SSOT
# detector (see _lib/bash4-features-check.sh), a full-tree audit of all 226
# tracked *.sh flags only the exempt detector lib itself. `-z` emits
# NUL-delimited filenames so the while-read loop below is safe for paths
# containing spaces, tabs, or newlines (prior `for f in $STAGED` word-split
# + broke on those).
# Enumerate staged files to a TEMP FILE, checking git's exit (#2645 r1
# silent-failure): in the old `done < <(git diff ... 2>/dev/null)` form a
# git failure (index.lock contention, corrupt index) was unreachable by
# set -e, its stderr discarded, and the gate scanned zero files — a silent
# pass of every staged .sh. A variable capture would strip the NUL
# delimiters bash cannot store, so the -z stream goes to a file.
_b4_staged="$(mktemp "${TMPDIR:-/tmp}/bash4-staged.XXXXXX")" || {
	echo "BLOCK: mktemp failed — cannot enumerate staged files (failing closed)" >&2
	exit 1
}
# The stderr capture is ALSO mktemp-created (CR #2649): "$_b4_staged.err"
# was a derived, predictable name — not atomically created — so a
# pre-planted file/symlink at that path in a shared TMPDIR could be
# followed. Both files now come from mktemp.
_b4_staged_err="$(mktemp "${TMPDIR:-/tmp}/bash4-staged-err.XXXXXX")" || {
	echo "BLOCK: mktemp failed — cannot capture git stderr (failing closed)" >&2
	rm -f "$_b4_staged"
	exit 1
}
# stderr goes to its OWN file (#2645 r1 security): merged into the -z
# stream, an rc-0 git warning (fsmonitor, .gitattributes) becomes part of
# the first NUL record and silently unscans that file.
# --no-renames (phase2 r2): with rename detection on, a staged rename is
# status R — outside the AM filter — so `git mv bad.sh new.sh` (or a
# delete+add git chooses to pair) would land its destination UNSCANNED.
# Disabling detection surfaces the destination as a plain A.
if ! git diff --cached --name-only --no-renames --diff-filter=AM -z >"$_b4_staged" 2>"$_b4_staged_err"; then
	echo "BLOCK: git diff --cached failed — cannot enumerate staged files (failing closed):" >&2
	cat "$_b4_staged_err" >&2
	rm -f "$_b4_staged" "$_b4_staged_err"
	exit 1
fi
[ -s "$_b4_staged_err" ] && cat "$_b4_staged_err" >&2
errs=0
while IFS= read -r -d '' f; do
	[ -n "$f" ] || continue
	case "$f" in *.sh) ;; *) continue ;; esac
	# v0.34.31 (#2235): skip canonical files in a consumer (validated upstream).
	command -v canonical_consumer_skip >/dev/null 2>&1 && canonical_consumer_skip "$f" && continue
	# `_*.sh` carve-out — shared predicate; rationale + caveats live with
	# it in the SSOT lib (#2645 r1).
	bash4_features_skip_basename "$f" && continue
	# Detector-lib self-exemption — the SHARED predicate from the SSOT lib
	# (#2645 r1): exactly one file wide (the detector's own regex source
	# self-matches), replacing the blanket `.claude/_lib/` carve-out. Every
	# other non-underscore-named lib is IN scope; deliberate guarded use
	# goes through `# bash4-waiver: <key> — <reason>` instead.
	bash4_features_exempt_path "$f" && continue
	# Scan the STAGED BLOB (:0:), never the worktree file (#2645 r1
	# security): the worktree can differ from what actually commits —
	# maliciously (stage bad, restore clean worktree) or carelessly (fix
	# after a block, forget `git add`, recommit) — and a staged-then-
	# deleted file has no worktree path at all. The old
	# `bash4_features_check_file "$f"` cat'd the worktree, so the gate
	# could bless bytes it never saw. Unreadable blob = fail closed.
	if ! _b4_blob=$(git show ":0:$f" 2>/dev/null); then
		echo "BLOCK: $f — cannot read staged blob :0:$f (failing closed)" >&2
		errs=$((errs + 1))
		continue
	fi
	bash4_features_check_content "$f" "$_b4_blob" || errs=$((errs + 1))
done <"$_b4_staged"
rm -f "$_b4_staged" "$_b4_staged_err"

# Fail-closed (#2235 CR): exit 1 on ANY failure (not the raw count — a count
# >255 would wrap to 0 = silent pass; codes 2+ also collide with usage-error
# conventions). Pre-commit treats any non-zero as failure.
[ "$errs" -eq 0 ] || exit 1
exit 0
