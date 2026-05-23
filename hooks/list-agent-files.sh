#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W3-C (#671): per-agent file scoping for the unified cache.
#
# Output: one file path per line — the subset of `git diff <base>..HEAD`
# that matches <agent>'s required_extensions / required_paths in
# review-config.yml. Used by phase1-launcher.sh + review-log.sh to
# (a) decide which agents are cached-clean at file granularity and
# (b) record cache entries per file after a successful agent run.
#
# Why per-file: the prior whole-diff sha256 cache key invalidated every
# agent's prior clean review whenever ANY file changed — even a file
# entirely outside that agent's scope. Per-file blob-sha keying matches
# the bats-gate model and only invalidates the agents whose scoped files
# actually changed.
#
# Usage:
#   .claude/hooks/list-agent-files.sh <agent> [base-ref]
#
# Exit codes:
#   0 — success: emitted 0 or more file paths to stdout. Empty output is
#       legitimate (agent has no in-scope files in this diff). Cache-check
#       callers (phase1-launcher, review-log) treat empty as "no cache
#       basis → can't claim cache-hit → agent still runs"; review-log's
#       cache-record loop simply records nothing for this agent. Zero-files
#       does NOT mean "skip the agent's review".
#   2 — yq missing, base ref missing, agent unknown, or config corrupt

AGENT="${1:-}"
BASE="${2:-main}"

if [ -z "$AGENT" ]; then
	echo "Usage: $0 <agent> [base-ref]" >&2
	exit 2
fi

# v0.6.6 (#13): resolve from git + plugin-helper (same pattern as
# list-phase1-agents.sh). Previously `../../` from <cache>/hooks/ landed
# in plugin-cache parent dir, not a real repo.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; })
PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
if [ -f "$PLUGIN_LIB/resolve-plugin-helper.sh" ]; then
	# shellcheck source=../_lib/resolve-plugin-helper.sh
	. "$PLUGIN_LIB/resolve-plugin-helper.sh"
	CONFIG="$(resolve_plugin_helper "review-config.yml" 2>/dev/null || echo "")"
	[ -n "$CONFIG" ] || CONFIG="$REPO_ROOT/.claude/review-config.yml"
else
	CONFIG="$REPO_ROOT/.claude/review-config.yml"
fi

command -v yq >/dev/null || {
	echo "ERROR: yq not installed" >&2
	exit 2
}
[ -f "$CONFIG" ] || {
	echo "ERROR: $CONFIG missing (checked \$REPO_ROOT/.claude/ + plugin cache)" >&2
	exit 2
}

cd "$REPO_ROOT" || exit 2

if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
	echo "ERROR: base ref '$BASE' does not exist" >&2
	exit 2
fi

if ! A="$AGENT" yq -e '.agents[strenv(A)]' "$CONFIG" >/dev/null 2>&1; then
	echo "ERROR: agent '$AGENT' not found in $CONFIG" >&2
	exit 2
fi

_diff_err=$(mktemp)
_diff_rc=0
CHANGED_FILES=$(git diff --name-only "$BASE"..HEAD 2>"$_diff_err") || _diff_rc=$?
if [ "$_diff_rc" -ne 0 ]; then
	echo "ERROR: git diff failed for ${BASE}..HEAD (rc=$_diff_rc): $(cat "$_diff_err")" >&2
	rm -f "$_diff_err"
	exit 2
fi
rm -f "$_diff_err"

[ -z "$CHANGED_FILES" ] && exit 0

yq_err=$(mktemp)
if ! EXTS=$(A="$AGENT" yq -r '.agents[strenv(A)].required_extensions[]' "$CONFIG" 2>"$yq_err"); then
	echo "ERROR: yq required_extensions read failed for $AGENT:" >&2
	cat "$yq_err" >&2
	rm -f "$yq_err"
	exit 2
fi
if ! PATHS=$(A="$AGENT" yq -r '.agents[strenv(A)].required_paths[]' "$CONFIG" 2>"$yq_err"); then
	echo "ERROR: yq required_paths read failed for $AGENT:" >&2
	cat "$yq_err" >&2
	rm -f "$yq_err"
	exit 2
fi
rm -f "$yq_err"

if [ -z "$EXTS" ] && [ -z "$PATHS" ]; then
	printf '%s\n' "$CHANGED_FILES"
	exit 0
fi

while IFS= read -r f; do
	[ -z "$f" ] && continue
	matched=0
	if [ -n "$EXTS" ]; then
		for ext in $EXTS; do
			esc_ext=${ext//./\\.}
			if echo "$f" | grep -qE -- "${esc_ext}$"; then
				matched=1
				break
			fi
		done
	fi
	if [ "$matched" = "0" ] && [ -n "$PATHS" ]; then
		while IFS= read -r glob; do
			[ -z "$glob" ] && continue
			# shellcheck disable=SC2254
			case "$f" in $glob)
				matched=1
				break
				;;
			esac
		done <<<"$PATHS"
	fi
	if [ "$matched" = "1" ]; then printf '%s\n' "$f"; fi
done <<<"$CHANGED_FILES"
exit 0
