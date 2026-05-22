#!/bin/bash
set -u
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

# Only newly-added .sh files — existing scripts are grandfathered (same
# semantic as bash-safety.sh's --diff-filter=A). `-z` emits NUL-delimited
# filenames so the while-read loop below is safe for paths containing
# spaces, tabs, or newlines (prior `for f in $STAGED` word-split + broke
# on those).
errs=0
while IFS= read -r -d '' f; do
	[ -n "$f" ] || continue
	case "$f" in *.sh) ;; *) continue ;; esac
	[ -f "$f" ] || continue
	# Skip library files (sourced, not run). Both the `_*.sh` basename
	# convention AND files under `.claude/_lib/` are exempt — the latter
	# because the detector's own source contains the feature-regex
	# patterns, which would false-positive on itself.
	case "$(basename "$f")" in
	_*.sh) continue ;;
	esac
	case "$f" in
	*/.claude/_lib/*.sh | .claude/_lib/*.sh) continue ;;
	esac
	bash4_features_check_file "$f" || errs=$((errs + 1))
done < <(git diff --cached --name-only --diff-filter=A -z 2>/dev/null)

exit "$errs"
