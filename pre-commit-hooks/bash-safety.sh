#!/bin/bash
set -euo pipefail
# Pre-commit: enforce `set -u` in every staged shell script (typo-in-varname
# silently expanding to empty = a known hazard we've been bitten by).
#
# Applies to *.sh files under scripts/, .claude/, and the repo root. Skips
# library files (_lib.sh pattern) which are sourced by others and inherit
# options from callers.
#
# Opt-out: prepend `# set-u: opt-out — <reason>` in the top 5 lines.
#
# v4.24-O (#601): rule lives in .claude/_lib/bash-safety-check.sh — shared
# with .claude/hooks/bash-safety-write-guard.sh (PreToolUse Write gate) so
# the two enforcement points never drift. Previously a Claude frustration
# vector: commits blocked but Write-tool didn't prevent the file landing.
#
# Part of v3.21 #264.

# shellcheck disable=SC2034  # REPO_ROOT kept for ABI; consumer-repo paths set via plugin-relative _lib lookup

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=../_lib/bash-safety-check.sh
. "$(dirname "$0")/../_lib/bash-safety-check.sh"
# v0.34.31 (#2235): consumer-aware canonical-skip — no-op in the plugin itself.
_CCS="$(dirname "$0")/../_lib/canonical-consumer-skip.sh"
# shellcheck source=../_lib/canonical-consumer-skip.sh
[ -f "$_CCS" ] && . "$_CCS"

# --diff-filter=A only — newly added files. Existing scripts are grandfathered
# so modifying them doesn't retroactively require a behavioral change. New files
# written since this hook lands MUST include set -u.
STAGED=$(git diff --cached --name-only --diff-filter=A | grep -E '\.sh$' || true)
[ -z "$STAGED" ] && exit 0

errs=0
for f in $STAGED; do
	# v0.34.31 (#2235): skip canonical files in a consumer (validated upstream).
	command -v canonical_consumer_skip >/dev/null 2>&1 && canonical_consumer_skip "$f" && continue
	if ! bash_safety_check_file "$f"; then
		errs=$((errs + 1))
	fi
done

exit "$errs"
