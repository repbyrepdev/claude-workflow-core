#!/bin/bash
# auto-register: false
set -euo pipefail
# v4.24-O (#601) — Phase 1 cross-agent finding deduper.
# v4.28-W5 (#709) — switched from drop-mode to advisory-cluster mode.
#
# Problem: when multiple agents review the same diff, they sometimes flag
# the same issue with different descriptions (e.g. silent-failure-hunter
# and code-reviewer both flag an unchecked error at foo.sh:42). Drop-mode
# (prior behavior) picked a winner + dropped losers — same shape as
# dismissal, can lose 1% of real findings.
#
# Advisory-cluster mode (current):
#   - Same dedup-hash → assigned same cluster_id
#   - ALL findings emitted (input.length == output.length always)
#   - dedup_rules in review-config.yml still apply — they still mark
#     known-overlap pairs (silent-failure-hunter + code-reviewer, etc.)
#     so the cluster is operator-visible, but no findings are dropped.
#   - Caller (phase1-launcher.sh / autofix-cycle.sh) groups by cluster_id
#     for visual presentation; per-cluster decisions go to prove-yourself
#     via --cluster-id <id> (existing arg).
#
# Usage:
#   cat round-N-findings.json | .claude/hooks/phase1-dedup.sh
#   .claude/hooks/phase1-dedup.sh < round-N-findings.json
#
# Input schema (JSON array of objects):
#   [{"agent": "code-reviewer", "file": "foo.sh", "line": 42,
#     "category": "unchecked_error", "severity": "high",
#     "description": "...", "confidence": 8}, ...]
#
# Output schema: same array shape with cluster_id added per finding.
# Findings sharing a hash share a cluster_id. Singletons get a unique
# cluster_id (still useful — caller can flatten "1-finding clusters" for
# display).
#
# Exit codes:
#   0  — output emitted
#   1  — config read error / dedup_rules malformed
#   2  — stdin not valid JSON array

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
CONFIG="$REPO_ROOT/.claude/review-config.yml"

if [ ! -f "$CONFIG" ]; then
	echo "ERROR: review-config.yml not found at $CONFIG" >&2
	exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
	echo "ERROR: yq required for dedup (install: brew install yq)" >&2
	exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "ERROR: jq required for dedup" >&2
	exit 1
fi

# Read stdin into a variable — empty input is a no-op (emit empty array).
INPUT=$(cat)
if [ -z "$INPUT" ] || [ "$INPUT" = "null" ]; then
	echo "[]"
	exit 0
fi

# Validate stdin is a JSON array.
if ! echo "$INPUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
	echo "ERROR: stdin must be a JSON array of findings" >&2
	exit 2
fi

# Per-agent dedup_key field list (defaults to [file, line, category] if absent).
AGENT_KEYS=$(yq -o=json '.agents // {}' "$CONFIG")
# CR-in-CI #780: dedup_rules participate in clustering by mapping
# overlap-pair agents to a rule-canonical hash key (file+line only,
# omitting per-agent category differences). This way silent-failure-
# hunter (category: silent_failure) and code-reviewer (category:
# unchecked_error) at foo.sh:42 both cluster together via the
# silent-failure-vs-code-reviewer rule.
RULES=$(yq -o=json '.dedup_rules // []' "$CONFIG")

# Compute cluster_id from a hash key via sha256 (first 24 hex chars).
# CR-in-CI #780 r1: was a 12-char slice of the raw tuple — collision-
# prone for distinct hashes sharing a prefix. CR-in-CI #780 r2: bumped
# from 12-char sha256 prefix to 24-char per CR's "24+ chars" recommen-
# dation. 16^24 = 6.3e28 collision space (vs 2.8e14 at 12 chars) —
# overkill but cheap, and matches CR's exact ask.
_cluster_id() {
	local h
	h=$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')
	[ -z "$h" ] && h=$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}')
	# Fallback: if both shasum and sha256sum unavailable (extreme
	# minimal env), fall back to gsub-slice — better than empty.
	if [ -z "$h" ]; then
		h=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
	fi
	printf 'c-%s' "${h:0:24}"
}
export -f _cluster_id

# Advisory cluster algorithm (jq):
#   1. For each finding, compute dedup_hash from the agent's dedup_key fields.
#   2. If finding's agent is in a dedup_rule, replace hash with rule-canonical
#      hash (rule_name|file|line) — collapses agents with different
#      category fields onto one cluster.
#   3. Group findings by dedup_hash.
#   4. Pipe each group's hash to _cluster_id (sha256-based).
#   5. Emit ALL findings with cluster_id added. Never drop.
WITH_HASHES=$(echo "$INPUT" | jq -c --argjson agent_keys "$AGENT_KEYS" --argjson rules "$RULES" '
  # Derive dedup_key field list for a given agent name.
  def keys_for($agent):
    ($agent_keys[$agent].dedup_key // ["file", "line", "category"]);

  # Compute base hash string for a finding: pipe-joined key-field values.
  def base_hash_of($finding):
    (keys_for($finding.agent) | map(($finding[.] // "") | tostring) | join("|"));

  # Find first dedup_rule whose `agents` list contains this finding'\''s agent.
  # Returns the rule name if matched, null otherwise.
  def rule_for($agent):
    ($rules | map(select(.agents | index($agent))) | .[0].name // null);

  # Effective hash: rule-canonical (rule_name|file|line|category) if
  # agent is in a rule, else the agent'\''s base hash.
  # CR-in-CI #780 r3: appends category as per-finding discriminator so
  # two findings from the same rule-participating agent at same
  # file:line but DIFFERENT categories don'\''t over-merge into one
  # cluster. Cross-agent SAME-category overlap still clusters (which
  # is the actual rule semantic — operator-vetted overlap pairs).
  def hash_of($finding):
    rule_for($finding.agent) as $rname
    | if $rname != null then
        ($rname + "|" + ($finding.file // "" | tostring) + "|" + ($finding.line // "" | tostring) + "|" + ($finding.category // "" | tostring))
      else
        base_hash_of($finding)
      end;

  # Annotate each finding with its hash; group + emit.
  map(. + {_dedup_hash: hash_of(.)})
  | group_by(._dedup_hash)
  | map(. as $group | $group[0]._dedup_hash as $h | $group | map(. + {_cluster_hash: $h}))
  | flatten
')

# Map _cluster_hash → _cluster_id via _cluster_id() (sha256-based).
# Walk findings; for each unique hash, compute the cluster_id once.
echo "$WITH_HASHES" | jq -c '.[]' | while IFS= read -r line; do
	hash=$(printf '%s' "$line" | jq -r '._cluster_hash')
	cid=$(_cluster_id "$hash")
	printf '%s\n' "$line" | jq -c --arg cid "$cid" '. + {cluster_id: $cid} | del(._dedup_hash, ._cluster_hash)'
done | jq -c -s '.'
