#!/bin/bash
set -euo pipefail
# (#2631 follow-up) Regenerate .claude/bats-assertion-baseline.tsv.
#
# The baseline records, per .bats file, how many assertions currently cannot
# fail (bare mid-test `[[ ]]` — see _lib/bats-assertion-check.sh for why).
# pre-commit-hooks/bats-assertion-gate.sh refuses any INCREASE, so the
# number is a ratchet: it may fall, never rise.
#
# Run this after FIXING assertions, to lock in the lower number. Running it
# after adding new ones would launder them into the baseline, so the hook
# stays the authority — this script only ever writes what is on disk now.
#
# Usage: scripts/refresh-bats-assertion-baseline.sh [--check]
#   --check  print what would change and exit 1 if the file is stale

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASELINE="$REPO_ROOT/.claude/bats-assertion-baseline.tsv"
# shellcheck source=../_lib/bats-assertion-check.sh
. "$REPO_ROOT/_lib/bats-assertion-check.sh"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

tmp=$(mktemp) || exit 2
trap 'rm -f "$tmp"' EXIT

total=0
files=0
while IFS= read -r f; do
	rel=${f#"$REPO_ROOT"/}
	found=$(bats_assertion_scan "$f")
	count=0
	[ -n "$found" ] && count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
	[ "$count" -gt 0 ] || continue
	printf '%s\t%s\n' "$rel" "$count" >>"$tmp"
	total=$((total + count))
	files=$((files + 1))
done < <(find "$REPO_ROOT/.claude/tests" -name '*.bats' -type f | sort)

if [ "$CHECK" = "1" ]; then
	if [ -r "$BASELINE" ] && diff -q "$BASELINE" "$tmp" >/dev/null 2>&1; then
		echo "bats-assertion-baseline: current ($files files, $total assertions)"
		exit 0
	fi
	echo "bats-assertion-baseline: STALE — re-run without --check" >&2
	diff -u "${BASELINE:-/dev/null}" "$tmp" 2>/dev/null | head -40 >&2 || true
	exit 1
fi

mkdir -p "$(dirname "$BASELINE")"
cp "$tmp" "$BASELINE"
echo "bats-assertion-baseline: wrote $files file(s), $total assertion(s) that cannot fail"
echo "  → $BASELINE"
echo "  The gate refuses any increase. Fix assertions, re-run this to ratchet down."
