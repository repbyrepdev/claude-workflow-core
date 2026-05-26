#!/bin/bash
set -euo pipefail
# v0.9.1 (#47): install-hooks — wire pre-commit + git pre-push gates for
# the plugin repo itself so plugin's own pushes go through the same gates
# consumer repos do.
#
# Idempotent. Safe to re-run.
#
# Usage:
#   scripts/install-hooks.sh           # install everything
#   scripts/install-hooks.sh --check   # verify install, exit 1 if drift
#   scripts/install-hooks.sh --help

CHECK_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--check)
		CHECK_ONLY=1
		shift
		;;
	-h | --help)
		grep '^#' "$0" | head -15
		exit 0
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 2
		;;
	esac
done

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "install-hooks: must be run inside a git repo" >&2
	exit 2
}
cd "$REPO_ROOT"

_log() { echo "[install-hooks] $*" >&2; }

# --- 1. pre-commit framework hooks --------------------------------------
if [ "$CHECK_ONLY" = "1" ]; then
	if [ ! -x .git/hooks/pre-commit ]; then
		_log "DRIFT: .git/hooks/pre-commit not installed"
		exit 1
	fi
	if ! grep -q "pre-commit" .git/hooks/pre-commit 2>/dev/null; then
		_log "DRIFT: .git/hooks/pre-commit not managed by pre-commit framework"
		exit 1
	fi
else
	if ! command -v pre-commit >/dev/null 2>&1; then
		_log "error: pre-commit not in PATH — install with: brew install pre-commit"
		exit 3
	fi
	_log "installing pre-commit hooks..."
	pre-commit install --install-hooks
fi

# --- 2. git pre-push gate (pipeline gate) -------------------------------
# Symlink hooks/pre-push-pipeline-gate.sh → .git/hooks/pre-push so the
# in-tree script is the source of truth (symlink survives plugin updates
# without re-running install).
GATE_SRC="hooks/pre-push-pipeline-gate.sh"
GATE_DST=".git/hooks/pre-push"

if [ ! -x "$GATE_SRC" ]; then
	_log "error: gate script missing at $GATE_SRC"
	exit 2
fi

if [ "$CHECK_ONLY" = "1" ]; then
	if [ ! -L "$GATE_DST" ]; then
		_log "DRIFT: $GATE_DST is not a symlink"
		exit 1
	fi
	# macOS readlink (no -f), use BSD-compatible flag.
	target=$(readlink "$GATE_DST" 2>/dev/null || true)
	expected_abs="$REPO_ROOT/$GATE_SRC"
	# Symlink target may be relative or absolute; resolve both to absolute
	# via the symlink's directory for comparison.
	case "$target" in
	/*) target_abs="$target" ;;
	*) target_abs="$REPO_ROOT/.git/hooks/$target" ;;
	esac
	# Use `cd ... && pwd` to canonicalize without requiring GNU readlink -f.
	target_canon=$(cd "$(dirname "$target_abs")" 2>/dev/null && pwd)/$(basename "$target_abs")
	expected_canon=$(cd "$(dirname "$expected_abs")" && pwd)/$(basename "$expected_abs")
	if [ "$target_canon" != "$expected_canon" ]; then
		_log "DRIFT: $GATE_DST → $target (expected $GATE_SRC)"
		exit 1
	fi
else
	_log "installing pre-push gate at $GATE_DST..."
	# Use relative path so the symlink stays valid if the repo moves.
	rel_target="../../$GATE_SRC"
	if [ -e "$GATE_DST" ] || [ -L "$GATE_DST" ]; then
		rm -f "$GATE_DST"
	fi
	ln -s "$rel_target" "$GATE_DST"
fi

# --- 3. Summary ----------------------------------------------------------
if [ "$CHECK_ONLY" = "1" ]; then
	_log "✓ all hooks installed + match expected layout"
else
	_log "✓ install complete:"
	_log "    .git/hooks/pre-commit   → managed by pre-commit framework"
	_log "    .git/hooks/pre-push     → symlink to $GATE_SRC"
	_log ""
	_log "Verify with: scripts/install-hooks.sh --check"
fi
