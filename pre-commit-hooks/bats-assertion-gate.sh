#!/bin/bash
set -euo pipefail
# (#2631 follow-up) Refuse NEW bats assertions that cannot fail.
#
# bats reports failure through an ERR trap. On bash 3.2 — what macOS ships
# at /bin/bash, frozen since 2007 because bash 4.0 relicensed to GPLv3 — a
# failing `[[ ]]` fires neither that trap nor `set -e`, so the test passes
# anyway. A bare `[[ ]]` therefore only fails a test when it happens to be
# the LAST command in the block. An assertion whose enforcement depends on
# its position is not an assertion.
#
# GRANDFATHERED, deliberately. 749 such no-ops across 96 files existed when
# this was found; refusing all of them at once would block every commit
# touching a test file and convert a real finding into a reason to disable
# the gate. This hook compares each STAGED .bats file against its recorded
# baseline and refuses only an INCREASE. Files absent from the baseline get
# 0 — so a new suite must be clean from the start.
#
# Lower a baseline by fixing assertions and re-running:
#   scripts/refresh-bats-assertion-baseline.sh
#
# Exit: 0 clean · 2 refused.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASELINE="$REPO_ROOT/.claude/bats-assertion-baseline.tsv"

# shellcheck source=../_lib/bats-assertion-check.sh
. "$REPO_ROOT/_lib/bats-assertion-check.sh"

if [ "${BATS_ASSERTION_GATE_SKIP:-0}" = "1" ]; then
	echo "bats-assertion-gate: SKIPPED via BATS_ASSERTION_GATE_SKIP=1" >&2
	mkdir -p "$REPO_ROOT/.claude/logs" 2>/dev/null || true
	printf '{"ts":"%s","kind":"bats-assertion-gate-skip","reason":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BATS_ASSERTION_GATE_SKIP_REASON:-unstated}" \
		>>"$REPO_ROOT/.claude/logs/pipeline-skip.jsonl" 2>/dev/null || true
	exit 0
fi

staged=$(git diff --cached --name-only --diff-filter=ACMR -- '*.bats' 2>/dev/null || true)
[ -n "$staged" ] || exit 0

_baseline_for() { # $1 = repo-relative path
	[ -r "$BASELINE" ] || {
		echo 0
		return
	}
	awk -F'\t' -v p="$1" '$1 == p { print $2; found = 1 } END { if (!found) print 0 }' \
		"$BASELINE" | head -1
}

violations=0
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	[ -f "$REPO_ROOT/$rel" ] || continue
	found=$(bats_assertion_scan "$REPO_ROOT/$rel")
	count=0
	[ -n "$found" ] && count=$(printf '%s\n' "$found" | wc -l | tr -d ' ')
	base=$(_baseline_for "$rel")
	if [ "$count" -gt "$base" ]; then
		echo "" >&2
		echo "bats-assertion-gate: $rel has $count assertion(s) that cannot fail (baseline $base)" >&2
		echo "" >&2
		printf '%s\n' "$found" | while IFS= read -r hit; do
			[ -n "$hit" ] && echo "  line ${hit}" >&2
		done
		violations=$((violations + 1))
	fi
done <<EOF
$staged
EOF

if [ "$violations" -gt 0 ]; then
	echo "" >&2
	echo '  A bare `[[ ]]` does not fail a bats test on bash 3.2 unless it is the' >&2
	echo "  block's LAST command. Use a form that fails wherever it sits:" >&2
	echo "" >&2
	echo '      [ "$status" -eq 0 ]                      single-bracket builtin' >&2
	echo '      [[ $output == *x* ]] || return 1          the `||` supplies it' >&2
	echo '      case "$output" in *x*) ;; *) return 1 ;; esac' >&2
	echo '      assert_output_contains "x"                helper returning non-zero' >&2
	echo "" >&2
	echo "  See _lib/bats-assertion-check.sh for the one-line demonstration." >&2
	echo "  Bypass (audit-logged): BATS_ASSERTION_GATE_SKIP=1 git commit ..." >&2
	exit 2
fi
exit 0
