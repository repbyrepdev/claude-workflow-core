#!/bin/bash
set -euo pipefail
# v4.28-B1 (#648): one-time seed for .claude/logs/dogfood-runs.jsonl.
#
# WHY: when the registry expands (e.g., this PR's 6→20 entries), every
# newly-registered file's existing content has no log entry, so the
# dogfood-gate would refuse the next commit touching any of those files
# until each target ran once. Running every target manually after a
# registry expansion is tedious and error-prone — this helper does it
# in one shot.
#
# Idempotent: re-running just appends fresh entries (each new entry
# bumps the ts so the gate's 1h window stays satisfied).
#
# Usage:
#   .claude/scripts/dogfood/seed-log.sh           # run every registered target
#   .claude/scripts/dogfood/seed-log.sh --check   # just report which targets would be seeded
#
# Exit codes:
#   0 — every target ran (seed PASSED for all OR seed-known-failures
#       documented in stderr; the log entry is still written so future
#       commits can see the staged_fp regardless)
#   1 — at least one unrecoverable invocation error (registry parse fail,
#       yq missing, etc.)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null) || {
	echo "seed-log: not in a git repo" >&2
	exit 1
}
cd "$REPO_ROOT"

CHECK_ONLY=0
for arg in "$@"; do
	case "$arg" in
	--check)
		CHECK_ONLY=1
		;;
	*)
		echo "seed-log: unknown flag: $arg" >&2
		exit 1
		;;
	esac
done

if ! command -v yq >/dev/null 2>&1; then
	echo "seed-log: yq required" >&2
	exit 1
fi

REGISTRY=".claude/dogfood-registry.yml"
[ -f "$REGISTRY" ] || {
	echo "seed-log: $REGISTRY missing" >&2
	exit 1
}

TARGETS=()
# Capture yq output + rc explicitly. Process substitution
# `done < <(yq ...)` would swallow yq's rc, so a registry parse
# failure would yield an empty TARGETS array silently and the
# script would exit 0 having "seeded 0 targets" — fail-closed
# requires checking the rc here.
target_output=$(yq '.targets[].name' "$REGISTRY" 2>&1) || {
	echo "seed-log: failed to parse registry: $target_output" >&2
	exit 1
}
while IFS= read -r t; do
	[ -n "$t" ] && TARGETS+=("$t")
done <<<"$target_output"

echo "seed-log: ${#TARGETS[@]} target(s) in registry"
[ "${#TARGETS[@]}" -gt 0 ] || {
	echo "seed-log: registry has no targets — nothing to seed" >&2
	exit 1
}

if [ "$CHECK_ONLY" = "1" ]; then
	for t in "${TARGETS[@]}"; do
		echo "  would seed: $t"
	done
	exit 0
fi

# scripts/dogfood.sh handles the JSONL append + staged_fp computation.
# We just iterate through all targets; failures are documented but
# don't abort the seed (the entry still gets written with status=fail
# so the operator can see what's broken).
PASS=0
FAIL=0
INVOCATION_ERROR=0
for t in "${TARGETS[@]}"; do
	echo ""
	echo "── seeding: $t ──"
	rc=0
	scripts/dogfood.sh --target "$t" || rc=$?
	if [ "$rc" -eq 0 ]; then
		PASS=$((PASS + 1))
	elif [ "$rc" -eq 2 ]; then
		# rc=2 from dogfood.sh = invocation error (registry parse,
		# missing target, fp-computation failure, missing sha256 tool).
		# These are tooling-broken-not-wire-broken — fail loud + break
		# the loop so caller sees the seeding never finished. Folding
		# into FAIL would let `seed-log: 19 passed, 1 failed` masquerade
		# as success-with-known-issue.
		echo "seed-log: unrecoverable invocation error while seeding $t (rc=2)" >&2
		INVOCATION_ERROR=1
		break
	else
		FAIL=$((FAIL + 1))
	fi
done

echo ""
echo "seed-log: $PASS passed, $FAIL failed (entries written to .claude/logs/dogfood-runs.jsonl)"
# Hard fail-loud on invocation errors (rc=2 from dogfood.sh = tooling
# broken). Without this, automation sees rc=0 + "$FAIL failed" message
# and proceeds as if seeding succeeded — which is the silent-failure
# pattern this PR is meant to eliminate.
if [ "$INVOCATION_ERROR" -eq 1 ]; then
	echo "seed-log: aborted due to invocation error — log may be incomplete" >&2
	exit 1
fi
# Intentional: exit 0 even when FAIL > 0. Per the docstring contract,
# seed-log's job is "ran every target + wrote log entries." status=fail
# entries ARE written (the gate just won't accept them — caller sees the
# "$FAIL failed" count above and decides what to investigate). Returning
# rc=1 here would conflict with CI/automation that treats rc as
# "tooling broke" vs "tooling worked, content needs review." For
# strict-mode use cases, gate against the printed counts instead of rc,
# OR add a --strict flag in a v4.28-B1 follow-up if the contract changes.
exit 0
