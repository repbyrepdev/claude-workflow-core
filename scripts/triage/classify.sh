#!/bin/bash
set -euo pipefail
# v4.21 (#520): user-facing CLI wrapper for ai-triage. Delegates to the
# existing `.claude/local-backups/ai-triage.sh` (which reads the
# workflow prompt from `.github/workflows/ai-triage.yml` as SSOT +
# invokes Claude + applies labels) but exposes it under the tidy
# `scripts/` namespace + adds dry-run + JSON-output support for piping.
#
# Usage:
#   .claude/scripts/triage/classify.sh <issue-num>           # apply labels
#   .claude/scripts/triage/classify.sh <issue-num> --dry-run # print what would be applied
#   .claude/scripts/triage/classify.sh <issue-num> --json    # machine-readable result
#
# Why a wrapper: the underlying ai-triage.sh is ~200 lines of workflow-
# conversion logic (yq parses prompt, gh issue view feeds context,
# Claude returns labels, gh issue edit applies). Users shouldn't need
# to remember which is the "real" script — this is the single front
# door mirroring the skill-wrappers pattern.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

BACKING="$REPO_ROOT/.claude/local-backups/ai-triage.sh"

SCM_DRY_RUN=0
FORMAT="text"
ARGS=()
for arg in "$@"; do
	case "$arg" in
	--dry-run) SCM_DRY_RUN=1 ;;
	--json) FORMAT="json" ;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*) ARGS+=("$arg") ;;
	esac
done

[ "${#ARGS[@]}" -eq 1 ] || scm_fail "usage: $0 <issue-num> [--dry-run] [--json]"
ISSUE="${ARGS[0]}"
[[ "$ISSUE" =~ ^[0-9]+$ ]] || scm_fail "issue must be numeric; got '$ISSUE'"

[ -x "$BACKING" ] || scm_fail "backing script missing/not executable: $BACKING"

BACKING_ARGS=()
[ "$SCM_DRY_RUN" = "1" ] && BACKING_ARGS=(--dry-run)

# Capture backing script stdout + stderr SEPARATELY. Merging with 2>&1
# would let stderr noise (warnings, deprecation notices) match the
# `(priority|area|type):[a-z0-9-]+` regex in --json mode and pollute
# the output with spurious label entries.
TMPERR=$(mktemp)
trap 'rm -f "$TMPERR"' EXIT
if [ "$SCM_DRY_RUN" = "1" ]; then
	OUT=$("$BACKING" "${BACKING_ARGS[@]+"${BACKING_ARGS[@]}"}" "$ISSUE" 2>"$TMPERR") ||
		scm_fail "ai-triage.sh failed (dry-run): $(cat "$TMPERR")"
else
	OUT=$("$BACKING" "$ISSUE" 2>"$TMPERR") ||
		scm_fail "ai-triage.sh failed: $(cat "$TMPERR")"
fi

case "$FORMAT" in
json)
	# Extract proposed labels (and actual applied ones on non-dry-run)
	# from the backing script's output. Labels lines match `label:*` or
	# `priority:*` or `area:*` conventions.
	labels=$(printf '%s\n' "$OUT" | grep -oE '(priority|area|type):[a-z0-9-]+' | sort -u | jq -R . | jq -s . 2>/dev/null || echo '[]')
	jq -nc --argjson issue "$ISSUE" --arg mode "$([ "$SCM_DRY_RUN" = "1" ] && echo dry-run || echo applied)" --argjson labels "$labels" \
		'{issue: $issue, mode: $mode, labels: $labels}'
	;;
text)
	printf '%s\n' "$OUT"
	;;
esac

# --arg for ISSUE (string): `--argjson 007` would fail jq numeric parse.
# ISSUE passes `^[0-9]+$` validation above so both forms are safe today,
# but string form avoids the leading-zero edge case.
scm_log triage-classify "$(jq -nc --arg issue "$ISSUE" --argjson dry "$SCM_DRY_RUN" \
	'{issue: ($issue | tonumber), dry_run: $dry}')"
