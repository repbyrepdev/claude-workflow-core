#!/bin/bash
# v4.7.F (#413): safe reader for .claude/mode.conf. Other scripts dot-source
# or call this helper to get ACTIONS_MODE without exec'ing arbitrary code
# — the file is gitignored + machine-local, but any process can write to
# it, so treat the contents as untrusted and grep-parse instead of
# sourcing.
#
# Usage:
#   ACTIONS_MODE=$(.claude/hooks/_read-actions-mode.sh)
# Output:
#   prints `local` or `remote` on stdout, nothing else. Defaults to
#   `local` if file missing, unparseable, or holds any other value.
#   Exit 0 always (caller acts on the output, not the exit code).
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$(dirname "$0")/../.." && pwd; })
FILE="$REPO_ROOT/.claude/mode.conf"

mode=local
if [ -f "$FILE" ]; then
	# Only accept exactly `ACTIONS_MODE=local` or `ACTIONS_MODE=remote`
	# (trailing whitespace allowed). Ignore everything else — comments,
	# other vars, shell syntax. No source; no exec. The `|| true` keeps
	# grep's rc=1 (no match) from aborting under set -e pipefail.
	m=$( (grep -E '^ACTIONS_MODE=(local|remote)[[:space:]]*$' "$FILE" || true) | tail -1 | sed -E 's/^ACTIONS_MODE=([a-z]+).*/\1/')
	case "$m" in
	local | remote) mode="$m" ;;
	*) mode=local ;;
	esac
fi

printf '%s\n' "$mode"
