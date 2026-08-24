#!/usr/bin/env bash
set -u
# #2545 (phase1 r1, code-simplifier + silent-failure-hunter): the ONE writer
# for .claude/logs/pipeline-skip.jsonl. Two near-verbatim copies existed —
# hooks/pre-push-pipeline-gate.sh and the phase2 round-cap override — and had
# already drifted (the cap copy added a `gate` field the hook's lacked, so
# one log carried two row shapes). Both producers now call this; every row
# carries `gate` so consumers (hooks/session-start-report.sh) can segment
# cap overrides from push bypasses instead of conflating them in one count.
#
# pipeline_skip_log <gate-name>
#   Reads PIPELINE_GATE_SKIP_REASON from the environment (empty string when
#   unset — the log row records that a reason was NOT given, which is itself
#   signal). Appends one JSONL row. Honors $SKIP_LOG as the target override
#   (the pre-push hook's existing test seam).
#
#   FAILURE IS LOUD, rc 1: the override this call audits must not be blocked
#   by a broken audit trail (jq missing, unwritable log, disk full), but it
#   must never be SILENT either — "(audit-logged)" while the append died was
#   the silent-failure-hunter finding. Callers `|| true` under set -e; the
#   stderr line is the visibility.
pipeline_skip_log() {
	local gate="${1:?pipeline_skip_log: gate name required}"
	local repo_root skip_log branch sha
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	skip_log="${SKIP_LOG:-$repo_root/.claude/logs/pipeline-skip.jsonl}"
	mkdir -p "$(dirname "$skip_log")" 2>/dev/null || true
	branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
	sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
	# `2>&1 >>"$skip_log"`: jq's stderr is captured for the diagnostic while
	# its stdout appends to the log — the failure message reports the ACTUAL
	# error instead of guessed causes (phase2 r1 on this branch).
	local _psl_err
	_psl_err=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$sha" \
		--arg branch "$branch" --arg reason "${PIPELINE_GATE_SKIP_REASON:-}" \
		--arg gate "$gate" \
		'{ts: $ts, sha: $sha, branch: $branch, reason: $reason, gate: $gate}' \
		2>&1 >>"$skip_log") || {
		echo "pipeline_skip_log: audit append FAILED for gate=$gate — override proceeding UNLOGGED (target=$skip_log): ${_psl_err:-<no stderr>}" >&2
		return 1
	}
}
