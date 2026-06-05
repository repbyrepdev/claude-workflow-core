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
or testing infra not present in this repo.
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
repo policy: command injection in shell scripts is generally non-exploitable
unless a concrete untrusted input path is identified.
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

	# v0.34.35 (#2240) canonical-review-exclusion: in a CONSUMER, narrow the
	# review surface to its consumer-authored (non-canonical) changed files. The
	# canonical mirrors (.claude/hooks, _lib, skills/ship-pr-cycle, ...) are
	# byte-identical to the pinned plugin cache (hash-drift --verify enforces it)
	# and were already reviewed upstream — re-reviewing them is the verbatim
	# treadmill. No-op for the PLUGIN itself (producer): it has plugin.json, so
	# the consumer guard below is false and it reviews its full diff.
	#
	# Consumer-vs-plugin is the plugin.json marker (one cheap rev-parse), and the
	# file list comes from the TESTED canonical_review_noncanonical_changed
	# helper — so this never shells out to `git diff` twice (#2240 phase0.5) and
	# never re-implements the filter. scope_clause carries its own surrounding
	# blank lines, so the empty (plugin) case leaves NO stray blank line.
	local scope_clause="" _cre_lib _cre_root
	_cre_lib="$(dirname "${BASH_SOURCE[0]}")/canonical-review-exclude.sh"
	if [ -r "$_cre_lib" ]; then
		# shellcheck source=./canonical-review-exclude.sh
		# No 2>/dev/null: this sources a pure function-def lib, so a genuine
		# source error (corruption) must surface. `|| true` still keeps the
		# fail-safe — the command -v guard below degrades to full review if the
		# predicate ends up undefined — without aborting the caller under set -e.
		# (#2240 phase2 CR: don't suppress source diagnostics.)
		. "$_cre_lib" || true
		_cre_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
		if command -v canonical_review_noncanonical_changed >/dev/null 2>&1 &&
			[ -n "$_cre_root" ] && [ ! -f "$_cre_root/.claude-plugin/plugin.json" ]; then
			# A FAILED diff (helper rc != 0 — e.g. `main` does not resolve in this
			# consumer / CI checkout) falls through to NO clause = full review
			# (fail-safe). Only a SUCCESSFUL diff distinguishes all-canonical
			# (empty) from partial (the consumer-authored file list). (#2240 r1
			# silent-failure-hunter: empty-on-failure must NOT read as "review
			# nothing".)
			local _noncanon
			if _noncanon=$(canonical_review_noncanonical_changed main); then
				if [ -n "$_noncanon" ]; then
					scope_clause="
CANONICAL-EXCLUSION: review ONLY these consumer-authored files (any other changed files are byte-identical pinned-canonical mirrors, upstream-reviewed + hash-drift-enforced — out of scope):
$(printf '%s\n' "$_noncanon" | sed 's/^/  - /')
"
				else
					scope_clause='
CANONICAL-EXCLUSION: every changed file is byte-identical to the pinned plugin canonical (upstream-reviewed + hash-drift-enforced). Nothing consumer-authored to review — return `[]`.
'
				fi
			fi
		fi
	fi

	cat <<EOF
Review the diff \`git diff main..HEAD\` for the current branch (HEAD ${sha:-<resolve>}, round $round).

$focus
${scope_clause}
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

# v0.7.3 (#28): Phase 0.5 prefilter prompt (Copilot/Gemini/Codex). Same
# READ-ONLY + treadmill-proof structure as Phase 1. External CLIs return
# text — no local Edit access — but prompt-structure parity prevents
# scope creep + ensures same finding shape.
phase05_agent_prompt() {
	local agent="$1"
	local repo_root="${2:-}"
	local sha="${3:-}"
	local provider="${4:-copilot}"

	if [ -z "$agent" ]; then
		echo "phase05_agent_prompt: usage: <agent-name> [repo-root] [sha] [provider]" >&2
		return 2
	fi

	local focus
	focus=$(_phase1_agent_focus "$agent") || return $?

	cat <<EOF
Phase 0.5 prefilter (${provider}) — pre-Claude pass on the diff.

Review the diff \`git diff main..HEAD\` for the current branch (HEAD ${sha:-<resolve>}).

$focus

Return findings as a JSON array of {severity: high|medium|low, file: path,
line: number, category: string, description: 1-2 sentences (include suggestion
text here if any), confidence: 0-10}. Empty array \`[]\` if clean.

Output ONLY the JSON array — no prose, no markdown, no commentary. The
prefilter parses your output programmatically.

Treadmill-proof guards (same as Phase 1):
- Skip findings already logged in prior round (check
  ${repo_root:-\$REPO_ROOT}/.claude/review-log/${sha:-<sha>}.jsonl)
- Skip findings with prove-yourself coverage
- Confidence floor: 7
- One-shot: return JSON once

Scope: ONLY changes in this PR's diff.
EOF
}

# CLI invocation
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# Default to phase1; --phase 0.5 overrides
	mode="phase1"
	if [ "${1:-}" = "--phase" ] && [ "${2:-}" = "0.5" ]; then
		mode="phase0.5"
		shift 2
	fi
	if [ "$mode" = "phase0.5" ]; then
		phase05_agent_prompt "$@"
	else
		phase1_agent_prompt "$@"
	fi
fi
