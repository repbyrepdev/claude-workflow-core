#!/bin/bash
set -u
# v4.24-I (#574) — pre-commit-msg hook: refuse commits whose message body
# lacks a `#NNN` issue reference unless the marker `[no-issue: <reason>]`
# is present.
#
# Why: the "code without tracking issue" regression flagged in #201 — a
# commit that doesn't reference an issue has no board lineage, can't be
# auto-closed, and drops out of project-tracking. Mechanical enforcement
# at commit-msg stage prevents it at the earliest possible point.
#
# Emergency bypass: `[no-issue: <reason>]` in the commit body. Logged to
# .claude/logs/no-issue-commits.jsonl for weekly audit.
#
# Registered in .pre-commit-config.yaml under stages: [commit-msg].

MSG_FILE="${1:-}"
[ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ] || {
	echo "commit-scope-to-issue: missing commit-msg file arg" >&2
	exit 0
}

MSG=$(cat "$MSG_FILE" 2>/dev/null)
[ -n "$MSG" ] || exit 0

# Exempt: revert commits, merge commits, release tag commits — these
# legitimately have no issue ref.
case "$MSG" in
"Revert "* | "Merge "* | "Release "*) exit 0 ;;
esac

# Look for #NNN in the message body (not trailers).
if printf '%s' "$MSG" | grep -qE '#[0-9]+'; then
	exit 0
fi

# Look for the explicit bypass marker.
if printf '%s' "$MSG" | grep -qE '\[no-issue:[[:space:]]*[^]]+\]'; then
	# Extract reason for the audit log.
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	if [ -n "$REPO_ROOT" ] && command -v jq >/dev/null 2>&1; then
		REASON=$(printf '%s' "$MSG" | grep -oE '\[no-issue:[[:space:]]*[^]]+\]' | head -1 | sed -E 's/^\[no-issue:[[:space:]]*//;s/\]$//')
		mkdir -p "$REPO_ROOT/.claude/logs" 2>/dev/null || true
		jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg reason "$REASON" \
			--arg subject "$(printf '%s' "$MSG" | head -1)" \
			'{ts:$ts, reason:$reason, subject:$subject}' \
			>>"$REPO_ROOT/.claude/logs/no-issue-commits.jsonl" 2>/dev/null || true
	fi
	echo "commit-scope-to-issue: [no-issue: ...] marker present — allowing (logged)" >&2
	exit 0
fi

{
	echo ""
	echo "✗ commit-scope-to-issue: commit message body has no \`#NNN\` issue reference"
	echo "  and no \`[no-issue: <reason>]\` bypass marker."
	echo ""
	echo "  Add one of:"
	echo "    - \`Closes #NNN\` / \`Fixes #NNN\` / \`Advances #NNN\` in the commit body"
	echo "    - \`[no-issue: <reason>]\` explicit marker (logged to .claude/logs/no-issue-commits.jsonl)"
	echo ""
	echo "  Why: the 'code without tracking issue' regression from #201 — every"
	echo "  commit should have board lineage."
} >&2
exit 1
