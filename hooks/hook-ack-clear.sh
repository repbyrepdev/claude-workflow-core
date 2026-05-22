#!/bin/bash
set -u
# NOTE: `set -u` only — no `-eo pipefail`. Early-out paths (no payload,
# no repo root, no sentinel file) intentionally `exit 0` and would
# conflict with `set -e`. Critical operations have explicit error
# checks: mktemp || exit 1, awk if-statement guard with explicit fail
# branch, mv || exit 1. set -u remains to catch unset-variable typos.
# event: PostToolUse
# matcher: Read
# v4.28-W3-C — clears hook-output-pending sentinel entries when the
# operator Reads the affected file. Pairs with hook-ack.sh + the
# universal stale-state-gate.sh (PreToolUse Bash/Edit blocker).

PAYLOAD=$(cat 2>/dev/null || echo "{}")
FILE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -z "$FILE" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
SENTINEL="$REPO_ROOT/.claude/.session-state/hook-output-pending.txt"
[ -f "$SENTINEL" ] || exit 0

# v4.30.D #800: if the operator Read the sentinel itself, treat it as a
# bulk-ack — reading the sentinel surfaces every (hook, reason, file)
# triple to the operator, so it counts as acknowledging all of them.
# This eliminates the N-Read-calls-per-bulk-acks ceremony observed in
# bats test runs and CR autofix cycles.
# CR PR #801 r2 MAJOR: match THIS REPO's sentinel exactly (compare via
# realpath so symlink-resolved paths like /var/folders → /private/var/
# folders on macOS still match), not any path ending in the suffix —
# unconditional-suffix glob would clear on unrelated repos' sentinels.
_FILE_REAL=$(realpath "$FILE" 2>/dev/null || echo "$FILE")
_SENTINEL_REAL=$(realpath "$SENTINEL" 2>/dev/null || echo "$SENTINEL")
if [ "$_FILE_REAL" = "$_SENTINEL_REAL" ] ||
	[ "$FILE" = ".claude/.session-state/hook-output-pending.txt" ] ||
	[ "$FILE" = "./.claude/.session-state/hook-output-pending.txt" ]; then
	# Truncate to clear all entries. Use `: > FILE` (in-place truncate)
	# rather than `rm` so any watcher / external monitor doesn't see a
	# missing file blip.
	: >"$SENTINEL" || exit 1
	exit 0
fi

# Remove all sentinel entries whose file_path (4th tab-separated field)
# matches the Read'd file. Path normalization: hooks may write relative
# paths (e.g. bats-gate writes ".claude/hooks/foo.sh") while the Read
# tool always passes absolute paths. Match exact, REPO_ROOT-relative
# form of the absolute target, OR basename suffix. Other entries
# (different files OR no file) remain — they require their own Read.
# r8 SFH #1+#2: mktemp + awk error checks. Prior code did
# unconditional `mv "$TMP" "$SENTINEL"` after awk; if mktemp failed,
# awk failed, or $TMP ended up empty/partial, the mv silently wiped
# the sentinel — destroying every queued un-acknowledged ack. Now:
# fail-fast on mktemp, propagate awk's rc, only mv on rc=0.
TMP=$(mktemp) || {
	echo "hook-ack-clear: mktemp failed — refusing to mutate sentinel" >&2
	exit 1
}
trap 'rm -f "$TMP"' EXIT
TARGET_BASE=${FILE##*/}
TARGET_REL="${FILE#"$REPO_ROOT/"}"
if ! awk -F'\t' -v target="$FILE" -v target_rel="$TARGET_REL" -v target_base="$TARGET_BASE" '
	{
		fp = $4
		if (fp == "") { print; next }
		# Exact match against absolute or repo-relative form.
		if (fp == target) next
		if (target_rel != "" && fp == target_rel) next
		# Basename match — fp is just the basename or ends with /basename.
		if (target_base != "") {
			if (fp == target_base) next
			needle = "/" target_base
			pos = length(fp) - length(needle) + 1
			if (pos > 0 && substr(fp, pos) == needle) next
		}
		print
	}
' "$SENTINEL" >"$TMP"; then
	echo "hook-ack-clear: awk filter failed — refusing to overwrite sentinel" >&2
	exit 1
fi
mv "$TMP" "$SENTINEL" || exit 1
exit 0
