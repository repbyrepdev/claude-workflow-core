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
#   scripts/install-hooks.sh --check   # verify install (rc=0 clean,
#                                      # rc=1 drift, rc=4 absent)
#   scripts/install-hooks.sh --help

usage() {
	cat <<'EOF'
Usage: scripts/install-hooks.sh [--check] [--help]

Installs pre-commit framework hooks AND the git pre-push gate for the
plugin repo. Idempotent — safe to re-run.

Options:
  --check    Verify install without modifying anything.
  --help     Show this help.

Exit codes:
  0  Install/check succeeded (or --check found clean install).
  1  --check detected DRIFT (installed but misconfigured).
  2  Usage error or repo precondition failed.
  3  Required dependency missing (e.g. pre-commit not in PATH).
  4  --check detected ABSENT install (operator needs to run install).
EOF
}

CHECK_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--check)
		CHECK_ONLY=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown arg: $1" >&2
		usage
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

# Worktree-safe hook dir: git rev-parse --git-path resolves the per-
# worktree hooks dir (.git/hooks for plain clones, .git/worktrees/<name>/
# hooks for `git worktree add` checkouts, .git/modules/<name>/hooks for
# submodules). Avoid the ../../ hardcode that Phase 1 code-reviewer
# flagged (#47 sub-issue 1 r1).
HOOKS_DIR=$(git rev-parse --git-path hooks)

# --- 1. pre-commit framework hooks --------------------------------------
PRECOMMIT_HOOK="$HOOKS_DIR/pre-commit"

if [ "$CHECK_ONLY" = "1" ]; then
	if [ ! -x "$PRECOMMIT_HOOK" ]; then
		_log "ABSENT: $PRECOMMIT_HOOK not installed — run 'scripts/install-hooks.sh' first"
		exit 4
	fi
	if ! grep -q "pre-commit" "$PRECOMMIT_HOOK" 2>/dev/null; then
		_log "DRIFT: $PRECOMMIT_HOOK not managed by pre-commit framework"
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
# Symlink hooks/pre-push-pipeline-gate.sh → $HOOKS_DIR/pre-push so the
# in-tree script is the source of truth (in-place edits to the target
# script take effect immediately without re-running install).
GATE_SRC="hooks/pre-push-pipeline-gate.sh"
GATE_DST="$HOOKS_DIR/pre-push"

if [ ! -x "$GATE_SRC" ]; then
	_log "error: gate script missing at $GATE_SRC"
	exit 2
fi

if [ "$CHECK_ONLY" = "1" ]; then
	if [ ! -L "$GATE_DST" ]; then
		if [ ! -e "$GATE_DST" ]; then
			_log "ABSENT: $GATE_DST not installed — run 'scripts/install-hooks.sh' first"
			exit 4
		fi
		_log "DRIFT: $GATE_DST exists but is not a symlink"
		exit 1
	fi
	# macOS readlink lacks -f; use flagless form which works on BSD + GNU
	# and returns the raw symlink target.
	target=$(readlink "$GATE_DST")
	expected_abs="$REPO_ROOT/$GATE_SRC"
	# Symlink target may be relative or absolute; resolve both to absolute
	# via the symlink's directory for comparison.
	case "$target" in
	/*) target_abs="$target" ;;
	*) target_abs="$HOOKS_DIR/$target" ;;
	esac
	# Canonicalize both sides for comparison. Do NOT suppress cd stderr —
	# if the symlink target's parent dir is missing/unreadable, the
	# operator needs the real error, not a generic DRIFT message
	# (Phase 1 silent-failure-hunter finding).
	if ! target_dir=$(cd "$(dirname "$target_abs")" && pwd); then
		_log "error: cannot resolve symlink target dir for $target_abs"
		exit 1
	fi
	target_canon="$target_dir/$(basename "$target_abs")"
	expected_canon=$(cd "$(dirname "$expected_abs")" && pwd)/$(basename "$expected_abs")
	if [ "$target_canon" != "$expected_canon" ]; then
		_log "DRIFT: $GATE_DST → $target (expected $GATE_SRC)"
		exit 1
	fi
else
	_log "installing pre-push gate at $GATE_DST..."
	# Compute symlink target relative to the hook's directory so it
	# survives repo moves AND works in git worktrees (where $HOOKS_DIR
	# isn't .git/hooks but .git/worktrees/<name>/hooks).
	if ! _hook_dir_abs=$(cd "$HOOKS_DIR" && pwd); then
		_log "error: cannot resolve hooks dir at $HOOKS_DIR"
		exit 2
	fi
	gate_abs="$REPO_ROOT/$GATE_SRC"
	# Build relative path from hook dir to gate via python3 (works on
	# macOS + Linux without GNU coreutils). Fall back to absolute path
	# if python3 unavailable.
	if command -v python3 >/dev/null 2>&1; then
		rel_target=$(python3 -c "import os.path,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$gate_abs" "$_hook_dir_abs")
	else
		_log "note: python3 unavailable — using absolute symlink target"
		rel_target="$gate_abs"
	fi
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
	_log "    $PRECOMMIT_HOOK → managed by pre-commit framework"
	_log "    $GATE_DST → symlink to $GATE_SRC"
	_log ""
	_log "Verify with: scripts/install-hooks.sh --check"
fi
