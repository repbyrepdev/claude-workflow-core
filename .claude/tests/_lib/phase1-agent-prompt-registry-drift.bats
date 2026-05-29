#!/usr/bin/env bats
# covers: _lib/phase1-agent-prompt.sh

# v0.30.A (#187): drift guard. `_lib/phase1-agent-prompt.sh` hardcodes a
# case statement of agent names; SSOT for the agent set is
# `.claude/review-config.yml` consumed via `hooks/list-phase1-agents.sh --all`.
# Subset-not-equal because some registry agents (semgrep, type-design-analyzer)
# dispatch via their own paths (semgrep_scan tool, canonical_brief in YAML)
# and don't need a hardcoded focus block.

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	PROMPT_LIB="$REPO_ROOT/_lib/phase1-agent-prompt.sh"
	REGISTRY_SCRIPT="$REPO_ROOT/hooks/list-phase1-agents.sh"
	[ -f "$PROMPT_LIB" ]
	[ -x "$REGISTRY_SCRIPT" ]
}

@test "hardcoded agent set ⊆ registry SSOT (no stranded prompts)" {
	# Extract agent names from case-label lines. The case bodies start
	# with `^\t<agent-name>)` (literal tab, name, close-paren).
	hardcoded=$(grep -E '^	[a-z][a-z-]*\)$' "$PROMPT_LIB" | sed -E 's/^	([a-z-]+)\)$/\1/' | sort -u)
	[ -n "$hardcoded" ]
	registry=$("$REGISTRY_SCRIPT" --all | sort -u)
	[ -n "$registry" ]
	# `comm -23` prints lines unique to first input (hardcoded but not in
	# registry). If non-empty, the case statement has stale agent names.
	missing=$(comm -23 <(echo "$hardcoded") <(echo "$registry"))
	if [ -n "$missing" ]; then
		echo "Hardcoded agents not in registry SSOT:" >&2
		# shellcheck disable=SC2001  # multi-line indent prefix; bash ${//} can't do this cleanly
		echo "$missing" | sed 's/^/  /' >&2
		echo "Either add them to .claude/review-config.yml or remove from $PROMPT_LIB" >&2
		false
	fi
}

@test "registry SSOT has at least the 6 agents the prompt lib covers" {
	# Reverse-direction sanity: the 6 documented prompt-lib agents must all
	# exist in registry. Catches a registry deletion that strands the prompt.
	registry=$("$REGISTRY_SCRIPT" --all | sort -u)
	for agent in code-reviewer code-simplifier comment-analyzer pr-test-analyzer silent-failure-hunter security-review; do
		echo "$registry" | grep -qx "$agent" || {
			echo "Registry SSOT missing agent '$agent' that $PROMPT_LIB depends on" >&2
			false
		}
	done
}
