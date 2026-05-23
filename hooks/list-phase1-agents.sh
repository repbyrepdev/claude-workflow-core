#!/bin/bash
# auto-register: false
# v4.4.A (#378): SSOT consumer for `.claude/review-config.yml`. Outputs
# one Phase 1 agent name per line, filtered by file-extensions in the
# current diff. The skill reads this to decide which agents to launch
# instead of hardcoding the 6 names in 3 different files.
#
# Usage:
#   .claude/hooks/list-phase1-agents.sh [base-ref]
#   .claude/hooks/list-phase1-agents.sh --all
#
# Default base-ref is main. Outputs the agents that should RUN for the
# current diff given the skip-rules in review-config.yml. Example:
# on a diff with no test files, `pr-test-analyzer` is in the output
# if the diff has *.sh (its required_extensions); omitted if not.
#
# `--all`: skip diff filtering and emit every configured agent name.
# Used by review-log.sh (#816) to validate agent names for the
# not-applicable logging path — i.e. logging filtered-OUT agents
# requires accepting their names, which the diff-filtered output by
# definition excludes.
#
# Exit codes:
#   0 — listed 1+ agents
#   1 — listed 0 agents (no agents matched diff scope) OR review-config.yml missing
#   2 — yq not installed, or base ref does not exist
#
# v4.28-W3 #660 contract update: 0-agents-matched is no longer "unexpected" —
# every agent now has explicit required_extensions/required_paths, so a
# doc-only or empty diff legitimately matches zero agents. The producer
# distinguishes rc=1 (no-match-legitimate) from rc=2 (tooling-broken).
#
# Caller compatibility (v4.28-W3 r2 code-reviewer finding): only
# phase0.5-copilot-prefilter.sh distinguishes the two so far.
# phase1-launcher.sh and pre-push-pipeline-gate.sh still treat ALL
# non-zero rc as "fail closed → exit 2" — that's a deliberate fail-safe
# in the pre-orchestrator world (refuse Phase 1 push without explicit
# operator override). The #657 ship-pr-cycle orchestrator will
# distinguish rc=1 (skip Phase 1 cleanly) from rc=2 (real config bug).
set -euo pipefail

# v0.6.5 (#39): resolve REPO_ROOT from git (so the hook works when invoked
# from plugin-cache where ../../ resolves into the cache layout, not a repo).
# Then resolve config via the plugin-helper resolver — consumer copy wins,
# plugin cache fallback otherwise.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PLUGIN_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../_lib" && pwd)"
if [ -f "$PLUGIN_LIB/resolve-plugin-helper.sh" ]; then
	# shellcheck source=../_lib/resolve-plugin-helper.sh
	. "$PLUGIN_LIB/resolve-plugin-helper.sh"
	CONFIG="$(resolve_plugin_helper "review-config.yml" 2>/dev/null || echo "")"
	[ -n "$CONFIG" ] || CONFIG="$REPO_ROOT/.claude/review-config.yml"
else
	# Legacy path — running before v0.6.5 lib was installed.
	CONFIG="$REPO_ROOT/.claude/review-config.yml"
fi
ALL_MODE=0
if [ "${1:-}" = "--all" ]; then
	ALL_MODE=1
	BASE=""
else
	BASE="${1:-main}"
fi

command -v yq >/dev/null || {
	echo "ERROR: yq not installed" >&2
	exit 2
}
if [ ! -f "$CONFIG" ]; then
	echo "ERROR: $CONFIG missing — cannot derive Phase 1 agent list" >&2
	exit 1
fi

cd "$REPO_ROOT" || exit 2

# v4.4 round-2: validate base ref exists BEFORE the git diff — otherwise
# an unknown base swallows the error, CHANGED_FILES ends up empty, and
# every filtered agent silently skips. Explicit exit 2 distinguishes this
# from the legitimate "empty diff" case.
# (Skipped under --all — that mode doesn't use the base ref at all.)
if [ "$ALL_MODE" = "0" ] && ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
	echo "ERROR: base ref '$BASE' does not exist (did you fetch? typo?)" >&2
	exit 2
fi

# All configured agents.
# CR Phase 2 final8: top-level .agents read needs the same yq-stderr-capture
# treatment as the per-agent reads below (lines 96-109). Without it, a
# corrupted config produces empty AGENTS → exit 1 ("legitimate no agents")
# masquerading as the rc=2 ("tooling broken") case. Caller can't distinguish.
_top_yq_err=$(mktemp)
if ! AGENTS=$(yq -r '.agents | keys | .[]' "$CONFIG" 2>"$_top_yq_err"); then
	echo "ERROR: yq failed reading .agents from $CONFIG:" >&2
	cat "$_top_yq_err" >&2
	rm -f "$_top_yq_err"
	exit 2
fi
rm -f "$_top_yq_err"
[ -z "$AGENTS" ] && {
	echo "ERROR: review-config.yml has no .agents keys" >&2
	exit 1
}

# --all: emit every configured agent without diff filtering (#816 validation).
if [ "$ALL_MODE" = "1" ]; then
	# shellcheck disable=SC2086
	printf '%s\n' $AGENTS
	exit 0
fi

# v4.28-W3 r3 SFH: capture git diff stderr — bad base ref / shallow clone /
# repo corruption could produce empty CHANGED_FILES that masquerades as
# legitimate empty diff, silently filtering all agents. Same pattern fixed
# in phase0.5-copilot-prefilter.sh during r2 (F6); missed here.
# CR Phase 2 final fix: gate on git's exit code, not stderr-presence —
# git emits harmless warnings to stderr (refname ambiguity, gc hints)
# that aren't failures. Surface stderr only when git actually exits non-zero.
_diff_err=$(mktemp)
_diff_rc=0
CHANGED_FILES=$(git diff --name-only "$BASE"..HEAD 2>"$_diff_err") || _diff_rc=$?
if [ "$_diff_rc" -ne 0 ]; then
	echo "ERROR: git diff failed for ${BASE}..HEAD (rc=$_diff_rc): $(cat "$_diff_err")" >&2
	rm -f "$_diff_err"
	exit 2
fi
rm -f "$_diff_err"
# v4.28-W3 #660: empty diff = 0 agents = exit 1 (legitimate "no work"
# state, distinct from exit 2 "tooling broken"). All agents now have
# explicit required_extensions; a pre-#660 always-on subset no longer
# exists. Callers gate on this rc to skip Phase 1 cleanly.

OUT=()
for agent in $AGENTS; do
	# Read the agent's required_extensions + required_paths (both optional).
	# mikefarah/yq doesn't support `// empty`; missing paths yield empty
	# string with rc=0. Genuine yq failures (corrupt config, OOM) get rc>0
	# — capture stderr + fail loud per v4.28-W3 #660 silent-failure-hunter
	# r2 (same yq-stderr-capture pattern fixed in phase0.5-copilot-prefilter.sh's
	# canonical_brief read during r1; missed here on this sibling required_*
	# read until r2).
	yq_err=$(mktemp)
	if ! EXTS=$(A="$agent" yq -r '.agents[strenv(A)].required_extensions[]' "$CONFIG" 2>"$yq_err"); then
		echo "ERROR: yq failed reading required_extensions for agent=$agent:" >&2
		cat "$yq_err" >&2
		rm -f "$yq_err"
		exit 2
	fi
	if ! PATHS=$(A="$agent" yq -r '.agents[strenv(A)].required_paths[]' "$CONFIG" 2>"$yq_err"); then
		echo "ERROR: yq failed reading required_paths for agent=$agent:" >&2
		cat "$yq_err" >&2
		rm -f "$yq_err"
		exit 2
	fi
	rm -f "$yq_err"

	# If no filters at all → always run
	if [ -z "$EXTS" ] && [ -z "$PATHS" ]; then
		OUT+=("$agent")
		continue
	fi

	# Match extensions. v4.4 round-2 fix: escape the leading dot so grep
	# treats `.ts` as a literal suffix rather than "any character + ts".
	# File `fooats` was a false-positive under the old pattern.
	MATCHED=0
	if [ -n "$EXTS" ]; then
		for ext in $EXTS; do
			# Escape dot in ext (expect ".ts", treat as literal "\.ts$").
			# Bash parameter expansion is faster + shellcheck-clean (SC2001).
			esc_ext=${ext//./\\.}
			if echo "$CHANGED_FILES" | grep -qE -- "${esc_ext}$"; then
				MATCHED=1
				break
			fi
		done
	fi
	# Match path globs (bash glob matching)
	if [ "$MATCHED" = "0" ] && [ -n "$PATHS" ]; then
		while IFS= read -r glob; do
			[ -z "$glob" ] && continue
			while IFS= read -r file; do
				# shellcheck disable=SC2254
				case "$file" in $glob)
					MATCHED=1
					break 2
					;;
				esac
			done <<<"$CHANGED_FILES"
		done <<<"$PATHS"
	fi

	if [ "$MATCHED" = "1" ]; then
		OUT+=("$agent")
	fi
done

if [ "${#OUT[@]}" -eq 0 ]; then
	echo "ERROR: no Phase 1 agents matched the current diff — skip-rules too strict?" >&2
	exit 1
fi
printf '%s\n' "${OUT[@]}"
