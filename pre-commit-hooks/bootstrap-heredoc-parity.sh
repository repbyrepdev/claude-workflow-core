#!/bin/bash
set -uo pipefail
# Cross-repo parity gate (#63): for files where byte-identical schema
# matters (ISSUE_TEMPLATE/*.yml in particular), assert the bootstrap
# heredoc body matches the live plugin file. Catches the original bug
# class: heredoc writes `labels: [epic, enhancement]` (unquoted) while
# the plugin's own epic.yml has `["epic", "enhancement"]` (quoted).
#
# Scope: deliberately narrow. Workflow files diverge intentionally
# (plugin runs production CI with history comments; heredoc is the
# slim consumer-ship variant). Only files in PARITY_PATHS get checked.
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

# Only run when the commit touches the script or one of the matching live files.
# Gracefully fall back to full check if not a git context.
STAGED=$(git diff --cached --name-only 2>/dev/null || true)
should_run=0
if [ -z "$STAGED" ]; then
	should_run=1
else
	while IFS= read -r f; do
		case "$f" in
		scripts/bootstrap-repo.sh | scripts/bootstrap-manifest.yml | .github/*)
			should_run=1
			break
			;;
		esac
	done <<<"$STAGED"
fi
[ "$should_run" -eq 0 ] && exit 0

drift=0
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

for path in "${PARITY_PATHS[@]}"; do
	live="$REPO_ROOT/$path"
	if [ ! -f "$live" ]; then
		echo "bootstrap-heredoc-parity: ✗ live file missing: $path" >&2
		drift=$((drift + 1))
		continue
	fi
	# Extract heredoc body via awk; pattern uses the raw path (escape only inside awk).
	heredoc=$(awk -v t="$path" 'BEGIN{ pat = "^_write " t " 644 <<'\''EOF'\''$" } $0 ~ pat,/^EOF$/' "$SCRIPT" | sed '1d;$d')
	if [ -z "$heredoc" ]; then
		echo "bootstrap-heredoc-parity: ✗ heredoc not found in script for: $path" >&2
		drift=$((drift + 1))
		continue
	fi
	# Compare. Use diff -u for actionable output.
	if ! diff -u <(printf '%s\n' "$heredoc") "$live" >/tmp/bootstrap-heredoc-parity-diff.$$ 2>&1; then
		echo "bootstrap-heredoc-parity: ✗ drift in $path" >&2
		head -20 /tmp/bootstrap-heredoc-parity-diff.$$ >&2
		drift=$((drift + 1))
	fi
	rm -f /tmp/bootstrap-heredoc-parity-diff.$$
done

if [ "$drift" -gt 0 ]; then
	echo "" >&2
	echo "bootstrap-heredoc-parity: $drift file(s) drift between bootstrap heredoc and live .github/*" >&2
	echo "  reconcile in the same commit. Bypass: BOOTSTRAP_HEREDOC_PARITY_SKIP=1 git commit ..." >&2
	exit 1
fi
exit 0
