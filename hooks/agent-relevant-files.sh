#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W5 (#788 follow-up) — content-aware re-review gate.
#
# Given a base ref (and optional head ref), report whether the diff
# contains ANY file that would trigger AT LEAST one Phase 1 agent to
# re-review. Computes union of required_extensions + required_paths
# across all agents in review-config.yml.
#
# Usage:
#   .claude/hooks/agent-relevant-files.sh <base_ref> [head_ref]
#
# Default head_ref is HEAD.
#
# Exit codes (mirror list-phase1-agents.sh contract):
#   0 — diff contains 1+ relevant files (re-review needed)
#   1 — diff is empty of agent-relevant files (carry-forward applies)
#   2 — tooling broken (yq missing, base/head ref bad, config corrupt)
#
# Stdout (rc=0): one relevant file per line (operator-readable diagnostic;
# integration callers gate on rc only).
#
# WHY: PR #782 cycled 11 phase 0.5 + 25 phase 1 rounds across 20 commits.
# Most commits were review-driven (CR fixes touching only .sh, plus audit
# log appends + memory updates). Phase 1 agents have no work to do when
# only audit/log/config files change — but the existing post-commit
# hooks re-fire blindly, restarting the clean-streak counter every time.
# This helper is the routing decision: carry-forward when irrelevant.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIG="$REPO_ROOT/.claude/review-config.yml"
BASE="${1:-}"
HEAD_REF="${2:-HEAD}"

if [ -z "$BASE" ]; then
	echo "Usage: $0 <base_ref> [head_ref]" >&2
	exit 2
fi

command -v yq >/dev/null || {
	echo "ERROR: yq not installed" >&2
	exit 2
}
if [ ! -f "$CONFIG" ]; then
	echo "ERROR: $CONFIG missing" >&2
	exit 2
fi

cd "$REPO_ROOT" || exit 2

for ref in "$BASE" "$HEAD_REF"; do
	# CR PR #790 r14 phase2: surface git stderr instead of swallowing.
	# Permission errors, shallow clones, repo-corruption, and "ref does
	# not exist" all share rc!=0 — capturing stderr distinguishes them.
	if ! _rev_out=$(git rev-parse --verify "$ref" 2>&1); then
		echo "ERROR: git rev-parse '$ref' failed: $_rev_out" >&2
		exit 2
	fi
done

# CR PR #790 r2 MAJOR: guard mktemp under set -euo pipefail. Bare
# `$(mktemp)` fails the script with mktemp's rc instead of the
# documented rc=2 (tooling broken), breaking caller routing — phase1
# dispatch can't distinguish "tooling broken" from "diff empty".
_yq_err=$(mktemp) || {
	echo "ERROR: mktemp failed for yq stderr capture — cannot run content-aware gate" >&2
	exit 2
}
_diff_err=$(mktemp) || {
	echo "ERROR: mktemp failed for diff stderr capture — cannot run content-aware gate" >&2
	rm -f "$_yq_err"
	exit 2
}
# CR PR #790 r20 phase2: unify temp-file cleanup in one EXIT trap so
# both stderr captures get released on any exit path (was: _diff_err
# had ad-hoc rm-after-use which leaked on early returns).
trap '[ -n "${_yq_err:-}" ] && rm -f "$_yq_err"; [ -n "${_diff_err:-}" ] && rm -f "$_diff_err"' EXIT
# CR PR #790 r3 MAJOR: detect "always-run" agents (those with neither
# required_extensions nor required_paths) — per SSOT contract, an empty-
# filter agent should re-review ANY non-empty diff. Without this, an
# always-run agent silently gets carry-forward instead of re-running.
if ! HAS_ALWAYS_RUN=$(yq -r '[.agents[] | select((.required_extensions // [] | length == 0) and (.required_paths // [] | length == 0))] | length' "$CONFIG" 2>"$_yq_err"); then
	echo "ERROR: yq failed checking for always-run agents:" >&2
	cat "$_yq_err" >&2
	exit 2
fi
# Collect union of required_extensions across all agents.
# CR PR #790 r13 phase2 MAJOR: `// []` fallback so an agent without
# required_extensions doesn't error the whole union; treat missing key
# as empty contribution to the union.
if ! EXTS=$(yq -r '[.agents[].required_extensions // [] | .[]] | unique | .[]' "$CONFIG" 2>"$_yq_err"); then
	echo "ERROR: yq failed reading required_extensions union:" >&2
	cat "$_yq_err" >&2
	exit 2
fi
# Collect union of required_paths (same `// []` fallback as above).
if ! PATHS=$(yq -r '[.agents[].required_paths // [] | .[]] | unique | .[]' "$CONFIG" 2>"$_yq_err"); then
	echo "ERROR: yq failed reading required_paths union:" >&2
	cat "$_yq_err" >&2
	exit 2
fi

# Capture git-diff stderr; bad refs masquerade as empty CHANGED_FILES.
# CR PR #790 r20 phase2: _diff_err was hoisted above to the EXIT trap
# so cleanup is unified — no ad-hoc rm-after-use here (the rm would
# leak on early returns before this point anyway).
_diff_rc=0
CHANGED_FILES=$(git diff --name-only "${BASE}..${HEAD_REF}" 2>"$_diff_err") || _diff_rc=$?
if [ "$_diff_rc" -ne 0 ]; then
	echo "ERROR: git diff failed for ${BASE}..${HEAD_REF} (rc=$_diff_rc): $(cat "$_diff_err")" >&2
	exit 2
fi

# Empty diff → no relevant files. Distinct from rc=2.
[ -z "$CHANGED_FILES" ] && exit 1

# CR PR #790 r3 MAJOR: if any agent has no required_extensions AND no
# required_paths (always-run), then a non-empty diff IS relevant per SSOT
# — emit all files + exit 0.
if [ "$HAS_ALWAYS_RUN" -gt 0 ]; then
	# CR Phase 2: CHANGED_FILES already terminates with newline; use
	# `%s` to avoid an extra blank line that mismatches the array-style
	# emission below.
	printf '%s' "$CHANGED_FILES"
	exit 0
fi

RELEVANT=()
while IFS= read -r file; do
	[ -z "$file" ] && continue
	matched=0
	# Extension match (escape leading dot per list-phase1-agents pattern).
	if [ -n "$EXTS" ]; then
		while IFS= read -r ext; do
			[ -z "$ext" ] && continue
			esc_ext=${ext//./\\.}
			if printf '%s\n' "$file" | grep -qE -- "${esc_ext}$"; then
				matched=1
				break
			fi
		done <<<"$EXTS"
	fi
	# Path-glob match.
	if [ "$matched" = "0" ] && [ -n "$PATHS" ]; then
		while IFS= read -r glob; do
			[ -z "$glob" ] && continue
			# shellcheck disable=SC2254
			case "$file" in $glob)
				matched=1
				break
				;;
			esac
		done <<<"$PATHS"
	fi
	[ "$matched" = "1" ] && RELEVANT+=("$file")
done <<<"$CHANGED_FILES"

if [ "${#RELEVANT[@]}" -eq 0 ]; then
	exit 1
fi
printf '%s\n' "${RELEVANT[@]}"
exit 0
