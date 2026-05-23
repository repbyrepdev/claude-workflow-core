#!/bin/bash
# v0.7.2 (#26): emit canonical Phase 1 agent prompt with READ-ONLY directive
# + treadmill-proofing + scope guards baked in. Called by ship-pr-cycle.sh
# when emitting the phase1 directive, OR directly by skills that fire Phase 1
# agents.
#
# Usage (as a sourceable lib):
#   source "$(...)/_lib/phase1-agent-prompt.sh"
#   phase1_agent_prompt code-reviewer "$REPO_ROOT" "$SHA" "$ROUND"
#
# Usage (as an executable):
#   _lib/phase1-agent-prompt.sh <agent-name> <repo-root> <sha> <round>
#   → prints the full prompt to stdout

# shellcheck disable=SC2034  # function exported for callers

# Per-agent focus blocks. Each agent gets a tight scope so they don't
# overlap. Treadmill-proofing applies uniformly.
_phase1_agent_focus() {
	case "$1" in
	code-reviewer)
		cat <<'EOF'
Focus ONLY on: architecture decisions, coupling/cohesion, public-API shape,
naming clarity, test organization. Do NOT flag: style nits, silent failures,
comment accuracy, test coverage gaps, simplification opportunities — other
agents in this round own those.
EOF
		;;
	code-simplifier)
		cat <<'EOF'
Focus ONLY on: simplification opportunities, dead code, redundant abstractions,
premature optimization, three-similar-lines-vs-abstraction tradeoffs. Do NOT
flag: architecture, comments, tests, silent failures — other agents own those.
EOF
		;;
	comment-analyzer)
		cat <<'EOF'
Focus ONLY on: comment accuracy vs code, stale references, misleading commit-
message wording, lying comments. Do NOT flag: missing comments (presence is
not a defect) or comments that merely COULD be more verbose.
EOF
		;;
	pr-test-analyzer)
		cat <<'EOF'
Focus ONLY on: test coverage gaps, weak assertions, missing edge cases for
THIS PR's changes. Do NOT flag: lack of tests for pre-existing untouched code,
or testing infra not present in this repo (e.g. bats-gate deferral noted in
CLAUDE.md).
EOF
		;;
	silent-failure-hunter)
		cat <<'EOF'
Focus ONLY on: silent failures, inadequate error handling, inappropriate
fallback behavior, `2>/dev/null` masking real errors, `|| true` masking
non-zero rc. Do NOT flag: deliberately silent paths documented as such.
EOF
		;;
	security-review)
		cat <<'EOF'
Focus on HIGH-CONFIDENCE security vulnerabilities ONLY. Exclude DoS, secrets-
on-disk (handled separately), rate-limiting, theoretical race conditions. Per
CLAUDE.md, command injection in shell scripts is generally non-exploitable
unless concrete untrusted input path is identified.
EOF
		;;
	*)
		echo "phase1_agent_prompt: unknown agent '$1'" >&2
		return 2
		;;
	esac
}

phase1_agent_prompt() {
	local agent="$1"
	local repo_root="${2:-}"
	local sha="${3:-}"
	local round="${4:-1}"

	if [ -z "$agent" ]; then
		echo "phase1_agent_prompt: usage: <agent-name> [repo-root] [sha] [round]" >&2
		return 2
	fi

	local focus
	focus=$(_phase1_agent_focus "$agent") || return $?

	cat <<EOF
Review the diff \`git diff main..HEAD\` for the current branch (HEAD ${sha:-<resolve>}, round $round).

$focus

READ ONLY — do NOT modify, edit, or write to any files. Return findings as a
JSON array of {severity: high|medium|low, file: path, line: number, category:
string, description: 1-2 sentences (include suggestion text here if any),
confidence: 0-10}. Empty array \`[]\` if clean.

Treadmill-proof guards:
- If a finding has already been logged in a prior round (check
  ${repo_root:-\$REPO_ROOT}/.claude/review-log/${sha:-<sha>}.jsonl), do NOT
  re-flag the same item.
- If a finding has prove-yourself coverage at
  ${repo_root:-\$REPO_ROOT}/.claude/.session-state/prove-yourself/*.json, do
  NOT re-flag.
- Confidence floor: 7. Speculative findings waste rounds.
- One-shot: return your JSON array or \`[]\` once. Do not iterate.

Scope: ONLY changes in this PR's diff. Pre-existing code untouched by this
PR is out of scope.
EOF
}

# CLI invocation
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	phase1_agent_prompt "$@"
fi
