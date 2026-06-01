#!/bin/bash
set -euo pipefail
# Pre-commit: validate memory/ directory integrity.
#   1. Every memory file must have MEMORY.md index entry
#   2. MEMORY.md entries must point to files that exist
#   3. feedback_*.md must have "**Why:**" and "**How to apply:**" lines
#   4. All memory files must have valid YAML frontmatter (name, description, type)
#
# Part of v3.19 meta-learning infrastructure (#239).

MEM_DIR="${MEMORY_DIR:-$HOME/.claude/projects/-Users-adamsfamily/memory}"
INDEX="$MEM_DIR/MEMORY.md"

# Run on any .claude/ staged change (the common case where memory rules matter
# because CLAUDE.md / hooks / skills are being touched). The v3.19 version gated
# on MEMORY_CHECK=1 env var — meant the hook never ran on real commits, silently
# skipping all validation. Now runs unconditionally on .claude/ changes; operator
# can force-run via MEMORY_CHECK=1 for a global check, or skip via SKIP=memory-index-valid.
staged=$(git diff --cached --name-only 2>/dev/null || true)
if [ "${MEMORY_CHECK:-0}" != "1" ] && ! echo "$staged" | grep -q "^\.claude/"; then
	exit 0
fi

[ -d "$MEM_DIR" ] || {
	echo "(no memory dir — skipping)"
	exit 0
}
[ -f "$INDEX" ] || {
	echo "✗ MEMORY.md not found in $MEM_DIR" >&2
	exit 1
}

errs=0
report=""

# 1. Every non-index memory file must appear in MEMORY.md index
while IFS= read -r mf; do
	base=$(basename "$mf")
	[ "$base" = "MEMORY.md" ] && continue
	if ! grep -qF "($base)" "$INDEX"; then
		report="$report
  ✗ orphan memory: $base not indexed in MEMORY.md"
		errs=$((errs + 1))
	fi
done < <(find "$MEM_DIR" -maxdepth 1 -type f -name "*.md")

# 2. MEMORY.md entries must point to existing files
while IFS= read -r ref; do
	if [ ! -f "$MEM_DIR/$ref" ]; then
		report="$report
  ✗ dead pointer: MEMORY.md references $ref (does not exist)"
		errs=$((errs + 1))
	fi
done < <(grep -oE '\([a-z0-9_-]+\.md\)' "$INDEX" 2>/dev/null | tr -d '()' | sort -u)

# 3. feedback_*.md must have a Why section + How to apply section.
# Loose match — any `**Why...**` and `**How to apply...**` heading counts
# (e.g. `**Why this matters:**`, `**How to apply (by type):**` both OK).
while IFS= read -r mf; do
	if ! grep -q "^\*\*Why" "$mf"; then
		report="$report
  ✗ $(basename "$mf"): missing '**Why...**' section (required for feedback memories — explain the motivation)"
		errs=$((errs + 1))
	fi
	if ! grep -q "^\*\*How to apply" "$mf"; then
		report="$report
  ✗ $(basename "$mf"): missing '**How to apply...**' section (required for feedback memories — explain when/where to use)"
		errs=$((errs + 1))
	fi
done < <(find "$MEM_DIR" -maxdepth 1 -type f -name "feedback_*.md")

# 4. Frontmatter validity. #251: accept each key top-level OR indented under a
# `metadata:` block — the harness memory subsystem normalizes frontmatter to
# `metadata:\n  type: <t>` (+ node_type), so a strict `^type:` rejected every
# normalized memory. `^[[:space:]]*type:` matches both (and not `node_type:`).
while IFS= read -r mf; do
	base=$(basename "$mf")
	[ "$base" = "MEMORY.md" ] && continue
	head -10 "$mf" | grep -qE "^[[:space:]]*name:" || {
		report="$report
  ✗ $base: missing 'name:' frontmatter"
		errs=$((errs + 1))
	}
	head -10 "$mf" | grep -qE "^[[:space:]]*description:" || {
		report="$report
  ✗ $base: missing 'description:' frontmatter"
		errs=$((errs + 1))
	}
	head -10 "$mf" | grep -qE "^[[:space:]]*type:" || {
		report="$report
  ✗ $base: missing 'type:' frontmatter"
		errs=$((errs + 1))
	}
done < <(find "$MEM_DIR" -maxdepth 1 -type f -name "*.md")

# 5. MEMORY.md line-count cap (v3.20 #241). Claude Code auto-loads MEMORY.md
# and truncates at 200 lines per the system prompt. 150 gives us buffer.
MEMORY_MD_CAP="${MEMORY_MD_CAP:-150}"
if [ -f "$INDEX" ]; then
	lines=$(wc -l <"$INDEX" | tr -d ' ')
	if [ "$lines" -gt "$MEMORY_MD_CAP" ]; then
		report="$report
  ✗ MEMORY.md is $lines lines (cap $MEMORY_MD_CAP). Run memory-consolidate skill OR raise cap via MEMORY_MD_CAP env var."
		errs=$((errs + 1))
	fi
fi

# 6. Per-memory-file line-count cap (v3.20 #242). Forces concise memories —
# long rambling feedback rarely gets applied because the rule is buried.
PER_FILE_CAP="${MEMORY_FILE_CAP:-100}"
while IFS= read -r mf; do
	lines=$(wc -l <"$mf" | tr -d ' ')
	if [ "$lines" -gt "$PER_FILE_CAP" ]; then
		report="$report
  ✗ $(basename "$mf") is $lines lines (cap $PER_FILE_CAP). Trim or split — memories should be tight rules, not essays."
		errs=$((errs + 1))
	fi
done < <(find "$MEM_DIR" -maxdepth 1 -type f -name "feedback_*.md")

if [ "$errs" -eq 0 ]; then
	echo "✓ memory index valid ($(find "$MEM_DIR" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ') files)"
	exit 0
else
	echo "✗ memory integrity: $errs finding(s)$report" >&2
	exit 1
fi
