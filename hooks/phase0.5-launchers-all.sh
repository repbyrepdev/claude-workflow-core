#!/bin/bash
set -euo pipefail
# auto-register: false
# v4.28-W4 (#661) — Phase 0.5 multi-agent parallel orchestrator.
#
# Fires all 3 free-tier CLI prefilters in parallel:
#   - phase0.5-copilot-prefilter.sh (Copilot, gpt-4.1)
#   - phase0.5-codex-prefilter.sh   (Codex, gpt-5.3-codex)
#   - phase0.5-gemini-prefilter.sh  (Gemini, gemini-pro)
#
# Each launcher fail-soft on missing CLI / auth failure — at least one
# completing with findings is sufficient for the phase0.5-before-cr gate.
# Stdout: merged JSON array of findings from all CLIs (deduped).
# Stderr: per-CLI status lines.
#
# Usage:
#   .claude/hooks/phase0.5-launchers-all.sh [--base main]
#
# Exit:
#   0 = at least one launcher ran (findings may be present)
#   1 = all 3 launchers errored
#   2 = arg / setup error

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$REPO_ROOT" ] || {
	echo "phase0.5-all: must be run inside a git repo" >&2
	exit 2
}
cd "$REPO_ROOT" || exit 2

BASE="main"
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		[ "$#" -ge 2 ] || {
			echo "phase0.5-all: --base requires value" >&2
			exit 2
		}
		BASE="$2"
		shift 2
		;;
	-h | --help)
		sed -n '4,20p' "$0"
		exit 0
		;;
	*)
		echo "phase0.5-all: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

HOOKS_DIR="$REPO_ROOT/.claude/hooks"
LAUNCHERS=(
	"$HOOKS_DIR/phase0.5-copilot-prefilter.sh"
	"$HOOKS_DIR/phase0.5-codex-prefilter.sh"
	"$HOOKS_DIR/phase0.5-gemini-prefilter.sh"
)

# Run all 3 in parallel, capture each output to a temp file. Track which
# completed successfully so we can merge findings + report which errored.
TMPDIR=$(mktemp -d -t phase0.5-all.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PIDS=()
NAMES=()
# CR Phase 3 Major: fail-closed if any launcher script is missing or not
# executable. Prior "skipping" silently degraded multi-CLI coverage to
# whatever subset happened to be present — operator wouldn't notice that
# Codex or Gemini stopped running because they got renamed/deleted.
# Better to refuse the orchestrator run + force operator to see the gap.
for launcher in "${LAUNCHERS[@]}"; do
	[ -x "$launcher" ] || {
		echo "phase0.5-all: launcher missing or not executable: $launcher" >&2
		echo "phase0.5-all: refusing to run with degraded launcher set — restore launcher or remove from LAUNCHERS array" >&2
		exit 2
	}
	name=$(basename "$launcher" | sed -E 's/^phase0\.5-//; s/-prefilter\.sh$//')
	out="$TMPDIR/$name.out"
	err="$TMPDIR/$name.err"
	"$launcher" --base "$BASE" >"$out" 2>"$err" &
	PIDS+=($!)
	NAMES+=("$name")
done

# Wait for all + collect rcs.
RCS=()
i=0
for pid in "${PIDS[@]}"; do
	rc=0
	wait "$pid" || rc=$?
	RCS+=("$rc")
	name=${NAMES[$i]}
	if [ "$rc" -eq 0 ]; then
		echo "phase0.5-all: $name OK" >&2
	else
		echo "phase0.5-all: $name FAILED (rc=$rc) — see stderr below:" >&2
		head -10 "$TMPDIR/$name.err" >&2
	fi
	i=$((i + 1))
done

# Merge all successful outputs into a single JSON array.
ALL_FINDINGS="[]"
i=0
ANY_OK=0
# Phase 1 r1 silent-failure-hunter conf-9: capture jq merge stderr +
# warn loud on parse failure. Prior `2>/dev/null) || merged=""` silently
# dropped successful launcher's findings if any other launcher emitted
# malformed JSON (or one's output corrupted). Now: per-launcher merge
# rc captured + stderr surfaced + audit log entry on failure so we never
# silently lose findings.
LAUNCHER_AUDIT_LOG="$REPO_ROOT/.claude/logs/phase0.5-run.jsonl"
mkdir -p "$(dirname "$LAUNCHER_AUDIT_LOG")"
for name in "${NAMES[@]}"; do
	rc=${RCS[$i]}
	if [ "$rc" -eq 0 ]; then
		out_file="$TMPDIR/$name.out"
		# CR Phase 3 r2 Major: ANY_OK=1 ONLY after stdout contract validated.
		# Prior order set ANY_OK=1 before validation — a launcher that exited
		# 0 with empty/malformed stdout would still flip ANY_OK + script
		# would exit 0 with [], hiding the broken contract.
		# Empty stdout → CONTRACT VIOLATION (rc=0 but no JSON array emitted).
		if [ ! -s "$out_file" ]; then
			echo "phase0.5-all: WARN: $name exited 0 but emitted empty stdout — contract violation, findings indeterminate" >&2
			# CR Phase 3 r2 Major: drop `|| true` on audit-log writes —
			# disk-full / perm-error must not be silently masked. Audit log
			# is the only breadcrumb when a launcher violates the contract.
			jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				--arg cli "$name" \
				'{ts:$ts, phase:"0.5-orchestrator", cli:$cli, status:"errored-empty-stdout"}' \
				>>"$LAUNCHER_AUDIT_LOG"
			i=$((i + 1))
			continue
		fi
		# Pre-check: is it a JSON array?
		if ! jq -e 'type == "array"' "$out_file" >/dev/null 2>&1; then
			echo "phase0.5-all: WARN: $name emitted non-JSON-array stdout (rc=0); findings dropped — see $TMPDIR/$name.out" >&2
			jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				--arg cli "$name" \
				'{ts:$ts, phase:"0.5-orchestrator", cli:$cli, status:"errored-malformed-stdout"}' \
				>>"$LAUNCHER_AUDIT_LOG"
			i=$((i + 1))
			continue
		fi
		# Stdout contract valid → flip ANY_OK + merge.
		ANY_OK=1
		jq_err=$(mktemp)
		jq_rc=0
		merged=$(jq -nc --slurpfile b "$out_file" --argjson a "$ALL_FINDINGS" \
			'$a + $b[0]' 2>"$jq_err") || jq_rc=$?
		if [ "$jq_rc" -ne 0 ]; then
			echo "phase0.5-all: WARN: jq merge failed for $name (rc=$jq_rc):" >&2
			cat "$jq_err" >&2
			jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				--arg cli "$name" --argjson rc "$jq_rc" \
				'{ts:$ts, phase:"0.5-orchestrator", cli:$cli, status:"errored-jq-merge", merge_rc:$rc}' \
				>>"$LAUNCHER_AUDIT_LOG"
		else
			ALL_FINDINGS="$merged"
		fi
		rm -f "$jq_err"
	fi
	i=$((i + 1))
done

# Final dedup across all 3 CLIs (advisory clustering — never drops).
DEDUP_HOOK="$HOOKS_DIR/phase1-dedup.sh"
if [ -x "$DEDUP_HOOK" ] && [ "$ALL_FINDINGS" != "[]" ]; then
	echo "$ALL_FINDINGS" | "$DEDUP_HOOK"
else
	echo "$ALL_FINDINGS"
fi

[ "$ANY_OK" = "1" ] || exit 1
exit 0
