#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.30.D #800: batch hook-ack acknowledgment.
#
# Reads the sentinel + every per-entry diagnostic file so the operator
# gets all pending hook output in a single tool-call cycle. PostToolUse
# Read clear (hook-ack-clear.sh) detects when the Read target IS the
# sentinel and truncates it — clearing all listed entries at once.

# CR PR #801 r2 MAJOR: skill-wrapper contract — export SKILL_WRAPPER=1
# so internal git calls pass skill-bypass-guard. --help prints usage
# and exits 0.
export SKILL_WRAPPER=1

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
	cat <<'HELP'
Usage: /ack
Summarize pending hook-ack entries and show the sentinel to Read for bulk-clear.
HELP
	exit 0
fi

if [ "$#" -gt 0 ]; then
	echo "ack: this command takes no arguments (use --help)" >&2
	exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "ack: not in a git repo" >&2
	exit 1
}
SENTINEL="$REPO_ROOT/.claude/.session-state/hook-output-pending.txt"

if [ ! -f "$SENTINEL" ] || [ ! -s "$SENTINEL" ]; then
	echo "ack: no pending acks"
	exit 0
fi

echo "=== Pending hook-ack entries ==="
echo ""
line_no=0
while IFS=$'\t' read -r ts hook reason file_path; do
	line_no=$((line_no + 1))
	printf '%d. [%s] %s — %s\n' "$line_no" "$hook" "$reason" "$ts"
	if [ -n "$file_path" ]; then
		# CR PR #801 r2 MAJOR: resolve relative diagnostic paths against
		# repo root before reading. Hooks may write either absolute paths
		# (per-instance diagnostic files) or repo-relative paths (e.g.
		# bats-gate writes ".claude/hooks/foo.sh"). Without resolving,
		# the -f check fails for relative paths even when the file exists
		# at $REPO_ROOT/<rel>, weakening the diagnostic-preview goal.
		diag_path="$file_path"
		case "$diag_path" in
		/*) ;;
		*) diag_path="$REPO_ROOT/$file_path" ;;
		esac
		if [ -f "$diag_path" ]; then
			printf '   file: %s\n' "$diag_path"
			# Show first 3 lines of diagnostic body for at-a-glance context.
			head -n 3 "$diag_path" 2>/dev/null | sed 's/^/   | /'
		fi
	fi
	echo ""
done <"$SENTINEL"

echo "=== Next: read the sentinel itself to bulk-clear (v4.30.D #800) ==="
echo "  Read $SENTINEL"
echo ""
echo "(This will surface ALL ack content to context + trigger PostToolUse"
echo " hook-ack-clear.sh which truncates the sentinel.)"
