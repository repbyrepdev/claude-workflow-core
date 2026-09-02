#!/bin/bash
set -euo pipefail
# v4.24-P (#603) — commit-time gate: refuse staged .sh files that use
# bash 4.0+ features with `#!/bin/bash` shebang. macOS bash 3.2 would
# silently fail on those features at runtime.
#
# Rule lives in .claude/_lib/bash4-features-check.sh — same lib consumed
# by .claude/hooks/bash4-features-write-guard.sh (PreToolUse Write gate).
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
errs=0
while IFS= read -r -d '' f; do
	[ -n "$f" ] || continue
	case "$f" in *.sh) ;; *) continue ;; esac
	[ -f "$f" ] || continue
	# v0.34.31 (#2235): skip canonical files in a consumer (validated upstream).
	command -v canonical_consumer_skip >/dev/null 2>&1 && canonical_consumer_skip "$f" && continue
	# Skip library files (sourced, not run). Both the `_*.sh` basename
	# convention AND files under `.claude/_lib/` are exempt — the latter
	# because the detector's own source contains the feature-regex
	# patterns, which would false-positive on itself.
	case "$(basename "$f")" in
	_*.sh) continue ;;
	esac
	# Any `_lib/` directory, in every layout: plugin-repo `_lib/`, consumer
	# `.claude/_lib/`, and `skills/_lib/` (#2645 — the old patterns covered
	# only the consumer layout, so under AM the detector would flag ITSELF
	# when this repo stages _lib/bash4-features-check.sh).
	case "$f" in
	_lib/*.sh | */_lib/*.sh) continue ;;
	esac
	bash4_features_check_file "$f" || errs=$((errs + 1))
done < <(git diff --cached --name-only --diff-filter=AM -z 2>/dev/null)

# Fail-closed (#2235 CR): exit 1 on ANY failure (not the raw count — a count
# >255 would wrap to 0 = silent pass; codes 2+ also collide with usage-error
# conventions). Pre-commit treats any non-zero as failure.
[ "$errs" -eq 0 ] || exit 1
exit 0
