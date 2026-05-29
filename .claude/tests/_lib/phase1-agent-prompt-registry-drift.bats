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

# Indent-agnostic case-label extractor — matches `<name>)` at start of an
# indented line. Widened from the original `^\t[a-z][a-z-]*\)$` to also
# tolerate spaces-indent (shfmt switch) AND mixed-case / digit agent names
# (e.g. future `code-reviewer-v2`). Cross-checks against a count of ALL
# case-arm lines to catch silent regex-miss drift (R2 pr-test-analyzer).
_extract_hardcoded_agents() {
	grep -E '^[[:space:]]+[a-zA-Z][a-zA-Z0-9_-]*\)$' "$PROMPT_LIB" |
		sed -E 's/^[[:space:]]+([a-zA-Z][a-zA-Z0-9_-]*)\)$/\1/' |
		grep -v '^\*$' |
		sort -u
}

@test "case-label extraction regex matches every case arm (regex-coverage guard)" {
	# If the extractor regex drifts so it misses arms, drift checks silently
	# pass. Cross-check the extracted count against a count of ALL indented
	# `name)` lines in the case body (including the `*)` catchall, minus 1).
	all_arms=$(grep -cE '^[[:space:]]+[a-zA-Z*][a-zA-Z0-9_-]*\)$' "$PROMPT_LIB")
	extracted=$(_extract_hardcoded_agents | wc -l | tr -d ' ')
	# all_arms includes the `*)` catchall; extracted excludes it. Expect
	# extracted == all_arms - 1.
	expected=$((all_arms - 1))
	if [ "$extracted" -ne "$expected" ]; then
		echo "Case-arm regex miscount — extractor: $extracted, total arms (incl *): $all_arms, expected: $expected" >&2
		echo "Extractor regex likely drifted; fix _extract_hardcoded_agents in this test." >&2
		false
	fi
}

@test "hardcoded agent set ⊆ registry SSOT (no stranded prompts)" {
	hardcoded=$(_extract_hardcoded_agents)
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
	# Reverse-direction sanity: every agent extracted dynamically from the
	# prompt-lib case statement must exist in registry. Catches a registry
	# deletion that strands a prompt — and unlike the original hardcoded
	# loop, this auto-updates if someone adds a new agent to the case body.
	registry=$("$REGISTRY_SCRIPT" --all | sort -u)
	[ -n "$registry" ]
	hardcoded=$(_extract_hardcoded_agents)
	[ -n "$hardcoded" ]
	while IFS= read -r agent; do
		[ -n "$agent" ] || continue
		echo "$registry" | grep -qx "$agent" || {
			echo "Registry SSOT missing agent '$agent' that $PROMPT_LIB depends on" >&2
			false
		}
	done <<<"$hardcoded"
}

@test "unknown-agent dispatch returns rc=2 + stderr (negative path guard)" {
	# Regression guard: if the `*)` catchall is ever changed to return 0
	# silently, unknown agents would dispatch with no focus block. Source
	# the lib + invoke with a bogus name + assert the documented contract.
	# shellcheck source=/dev/null
	source "$PROMPT_LIB"
	run _phase1_agent_focus this-agent-does-not-exist
	[ "$status" -eq 2 ]
	[[ $output == *"unknown agent"* ]]
}

@test "sourceable + callable: phase1_agent_prompt code-reviewer emits scaffold" {
	# Regression guard for the dual-mode CLI/sourceable contract. The
	# docstring promises `source ... && phase1_agent_prompt <agent> ...`
	# works. Catches accidental `local` scoping or CLI-guard inversion.
	# shellcheck source=/dev/null
	source "$PROMPT_LIB"
	run phase1_agent_prompt code-reviewer "/tmp" "abc123" 1
	[ "$status" -eq 0 ]
	# Output should include code-reviewer-specific focus (architecture
	# decisions, coupling). The "Do NOT flag" guidance does reference other
	# agents' specialties — so don't anti-check on those keywords; instead
	# assert the code-reviewer's positive-focus phrase is present.
	[[ $output == *"architecture decisions"* ]]
}
