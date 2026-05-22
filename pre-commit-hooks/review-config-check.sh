#!/bin/bash
# v4.24-O (#601) — pre-commit drift guard for .claude/review-config.yml.
#
# The file is SSOT for Phase 1 orchestration (list-phase1-agents.sh,
# phase1-launcher.sh, phase1-dedup.sh, review-log.sh). If someone
# accidentally removes `agents:`, drops `dedup_key`, or adds an agent
# without required shape, downstream hooks fail opaquely. This guard
# enforces the schema at commit time.
#
# Fires only when .claude/review-config.yml is in the staged diff.

set -u

staged=$(git diff --cached --name-only 2>/dev/null || true)
echo "$staged" | grep -qx ".claude/review-config.yml" || exit 0

if ! command -v yq >/dev/null 2>&1; then
	echo "ERROR: yq required to validate review-config.yml drift" >&2
	exit 1
fi

# Read the STAGED version — not working tree. Protects against edits-since-stage.
if ! tpl=$(git show ":.claude/review-config.yml" 2>&1); then
	echo "ERROR: unable to read staged .claude/review-config.yml: $tpl" >&2
	exit 1
fi

_tmp=$(mktemp)
trap 'rm -f "$_tmp"' EXIT
printf '%s' "$tpl" >"$_tmp"

errs=0

# Required top-level keys.
if ! yq -e '.agents' "$_tmp" >/dev/null 2>&1; then
	echo "✗ review-config.yml missing required top-level: agents" >&2
	errs=$((errs + 1))
fi

# Every agent must have scope + canonical_brief + output_shape.fields + dedup_key.
# Skipping this check for agents that are purely skip-rule definitions would
# allow downstream tools to consume a brief-less agent and emit a blank prompt.
agent_names=$(yq -r '.agents | keys | .[]' "$_tmp" 2>/dev/null || echo "")
if [ -z "$agent_names" ]; then
	echo "✗ review-config.yml has no agents defined" >&2
	errs=$((errs + 1))
fi
for agent in $agent_names; do
	for field in "scope" "canonical_brief" "dedup_key"; do
		if ! yq -e ".agents.\"$agent\".$field" "$_tmp" >/dev/null 2>&1; then
			echo "✗ review-config.yml agents.$agent missing: $field" >&2
			errs=$((errs + 1))
		fi
	done
	# output_shape.fields must be a non-empty array.
	if ! yq -e ".agents.\"$agent\".output_shape.fields | length > 0" "$_tmp" >/dev/null 2>&1; then
		echo "✗ review-config.yml agents.$agent.output_shape.fields must be non-empty array" >&2
		errs=$((errs + 1))
	fi
done

# Required canonical agent set (Conventional Phase 1 roster).
# Adding to this list is fine; removing one breaks downstream listers.
# v4.24-O CR Round 3: dynamic lookup from list-phase1-agents.sh instead of hardcoding.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
LIST_SCRIPT="$REPO_ROOT/.claude/hooks/list-phase1-agents.sh"
if [ -x "$LIST_SCRIPT" ]; then
	# Call with main argument to get the canonical list. Suppress stderr
	# (missing base is expected during pre-commit on empty repo) and fall
	# back to the hardcoded list on failure.
	REQUIRED_AGENTS=$("$LIST_SCRIPT" main 2>/dev/null | sort -u || echo "")
	if [ -n "$REQUIRED_AGENTS" ]; then
		for required_agent in $REQUIRED_AGENTS; do
			if ! yq -e ".agents.\"$required_agent\"" "$_tmp" >/dev/null 2>&1; then
				echo "✗ review-config.yml must define agent: $required_agent" >&2
				errs=$((errs + 1))
			fi
		done
	fi
else
	# Fallback when list-phase1-agents.sh not present (bootstrapping).
	for required_agent in "code-reviewer" "silent-failure-hunter" "comment-analyzer" "pr-test-analyzer" "code-simplifier" "security-review" "semgrep"; do
		if ! yq -e ".agents.\"$required_agent\"" "$_tmp" >/dev/null 2>&1; then
			echo "✗ review-config.yml must define agent: $required_agent" >&2
			errs=$((errs + 1))
		fi
	done
fi

# dedup_rules shape — each rule needs name + agents + precedence.
if yq -e '.dedup_rules' "$_tmp" >/dev/null 2>&1; then
	rule_count=$(yq '.dedup_rules | length' "$_tmp" 2>/dev/null || echo 0)
	# Top-level agent set used for cross-validation of dedup_rules[].agents
	# and .precedence. A rule referencing an undefined agent name was
	# previously a silent downstream no-op in phase1-dedup.sh — the rule
	# would never match because precedence_for requires all rule agents to
	# appear in the group, and a phantom agent can never appear.
	top_level_agents=$(yq -r '.agents | keys | .[]' "$_tmp" 2>/dev/null || echo "")
	i=0
	while [ "$i" -lt "$rule_count" ]; do
		for field in "name" "agents" "precedence"; do
			if ! yq -e ".dedup_rules[$i].$field" "$_tmp" >/dev/null 2>&1; then
				echo "✗ review-config.yml dedup_rules[$i] missing: $field" >&2
				errs=$((errs + 1))
			fi
		done
		if yq -e ".dedup_rules[$i].agents" "$_tmp" >/dev/null 2>&1 &&
			yq -e ".dedup_rules[$i].precedence" "$_tmp" >/dev/null 2>&1; then
			rule_agents=$(yq -r ".dedup_rules[$i].agents[]" "$_tmp" 2>/dev/null || echo "")
			rule_prec=$(yq -r ".dedup_rules[$i].precedence[]" "$_tmp" 2>/dev/null || echo "")
			# rule.agents must be non-empty (empty list = rule never matches).
			if [ -z "$rule_agents" ]; then
				echo "✗ review-config.yml dedup_rules[$i].agents is empty — rule will never match" >&2
				errs=$((errs + 1))
			fi
			# Every name in rule.agents must exist at top-level .agents.<name>.
			# Without this, a typo in a rule agent becomes a silent downstream
			# no-op rather than a loud schema error at commit time.
			bad_rule_agents=""
			while IFS= read -r a; do
				[ -z "$a" ] && continue
				if ! echo "$top_level_agents" | grep -qx "$a"; then
					bad_rule_agents="${bad_rule_agents:+$bad_rule_agents }$a"
				fi
			done <<<"$rule_agents"
			if [ -n "$bad_rule_agents" ]; then
				echo "✗ review-config.yml dedup_rules[$i].agents references undefined top-level agents: $bad_rule_agents" >&2
				errs=$((errs + 1))
			fi
			# Precedence must only contain agents listed in THIS rule's
			# agents list (precedence orders the rule's own agents).
			bad=""
			while IFS= read -r p; do
				[ -z "$p" ] && continue
				if ! echo "$rule_agents" | grep -qx "$p"; then
					bad="${bad:+$bad }$p"
				fi
			done <<<"$rule_prec"
			if [ -n "$bad" ]; then
				echo "✗ review-config.yml dedup_rules[$i].precedence references agents not in dedup_rules[$i].agents: $bad" >&2
				errs=$((errs + 1))
			fi
		fi
		i=$((i + 1))
	done
fi

if [ "$errs" -gt 0 ]; then
	echo "" >&2
	echo "$errs schema drift error(s) in .claude/review-config.yml" >&2
	echo "This file is SSOT for Phase 1 orchestration. Restore required fields or revert." >&2
	exit 1
fi

exit 0
