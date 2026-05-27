#!/bin/bash
set -euo pipefail
# Cross-repo parity gate: for files where byte-identical schema matters
# (ISSUE_TEMPLATE/*.yml in particular), assert the bootstrap heredoc
# body matches the live plugin file. Catches the bug class where a
# heredoc's quoting/whitespace drifts from the live ISSUE_TEMPLATE yml.
#
# Scope: deliberately narrow. Workflow files diverge intentionally
# (plugin runs production CI with history comments; heredoc is the
# slim consumer-ship variant). Only paths in PARITY_PATHS get checked.
#
# Bypass: BOOTSTRAP_HEREDOC_PARITY_SKIP=1 git commit ... (audit-logged).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SCRIPT="$REPO_ROOT/scripts/bootstrap-repo.sh"
MANIFEST="$REPO_ROOT/scripts/bootstrap-manifest.yml"

if [ "${BOOTSTRAP_HEREDOC_PARITY_SKIP:-0}" = "1" ]; then
	echo "bootstrap-heredoc-parity: BYPASS via BOOTSTRAP_HEREDOC_PARITY_SKIP=1" >&2
	exit 0
fi

if [ ! -f "$SCRIPT" ] || [ ! -f "$MANIFEST" ]; then
	# Not the plugin repo (or pre-bootstrap-manifest commit) — skip.
	exit 0
fi
if ! command -v yq >/dev/null 2>&1; then
	echo "bootstrap-heredoc-parity: yq not on PATH — skipping" >&2
	exit 0
fi

# Whitelist of paths where byte-parity matters. Adding a new entry here
# is the explicit knob — files NOT listed are allowed to diverge.
PARITY_PATHS=(
	".github/ISSUE_TEMPLATE/bug.yml"
	".github/ISSUE_TEMPLATE/feature.yml"
	".github/ISSUE_TEMPLATE/task.yml"
	".github/ISSUE_TEMPLATE/epic.yml"
	".github/ISSUE_TEMPLATE/brainstorm.yml"
	".github/pull_request_template.md"
)

# Only run when the commit touches the script, manifest, or any of the
# PARITY_PATHS files. Derived from PARITY_PATHS so future whitelist
# additions automatically widen the should_run trigger.
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
should_run=0
if [ -z "$STAGED" ]; then
	should_run=1
else
	while IFS= read -r f; do
		[ -z "$f" ] && continue
		case "$f" in
		scripts/bootstrap-repo.sh | scripts/bootstrap-manifest.yml)
			should_run=1
			break
			;;
		esac
		for p in "${PARITY_PATHS[@]}"; do
			[ "$f" = "$p" ] && {
				should_run=1
				break 2
			}
		done
	done <<<"$STAGED"
fi
[ "$should_run" -eq 0 ] && exit 0

drift=0
DIFF_TMP=$(mktemp -t bootstrap-heredoc-parity.XXXXXX)
trap 'rm -f "$DIFF_TMP"' EXIT

for path in "${PARITY_PATHS[@]}"; do
	live="$REPO_ROOT/$path"
	if [ ! -f "$live" ]; then
		echo "bootstrap-heredoc-parity: ✗ live file missing: $path" >&2
		drift=$((drift + 1))
		continue
	fi
	# Distinguish "no heredoc for this path" from "heredoc extraction
	# pattern broke". First check whether `_write <path> 644` exists
	# literally anywhere in the script.
	if ! grep -qF "_write $path 644" "$SCRIPT"; then
		echo "bootstrap-heredoc-parity: ✗ no heredoc found for: $path (no '_write $path 644' line)" >&2
		drift=$((drift + 1))
		continue
	fi
	# Extract heredoc body via awk. Pattern is anchored to start-of-line
	# + literal path + ' 644 <<' + single-quoted EOF; future delimiter
	# changes (<<-EOF, <<"EOF") would miss the extraction and fall to
	# the empty branch below, which is correctly reported as drift.
	heredoc=$(awk -v t="$path" 'BEGIN{ pat = "^_write " t " 644 <<'\''EOF'\''$" } $0 ~ pat,/^EOF$/' "$SCRIPT" | sed '1d;$d')
	if [ -z "$heredoc" ]; then
		echo "bootstrap-heredoc-parity: ✗ heredoc extraction empty for: $path (delimiter changed? <<-EOF or \"EOF\"?)" >&2
		drift=$((drift + 1))
		continue
	fi
	# Compare. Use diff -u for actionable output.
	if ! diff -u <(printf '%s\n' "$heredoc") "$live" >"$DIFF_TMP" 2>&1; then
		echo "bootstrap-heredoc-parity: ✗ drift in $path" >&2
		head -20 "$DIFF_TMP" >&2
		drift=$((drift + 1))
	fi
done

if [ "$drift" -gt 0 ]; then
	echo "" >&2
	echo "bootstrap-heredoc-parity: $drift file(s) drift between bootstrap heredoc and live .github/*" >&2
	echo "  reconcile in the same commit. Bypass: BOOTSTRAP_HEREDOC_PARITY_SKIP=1 git commit ..." >&2
	exit 1
fi
exit 0
