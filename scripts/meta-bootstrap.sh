#!/bin/bash
set -euo pipefail
# meta-bootstrap.sh — single entry point for every setup target.
#
# Replaces the fragmented "I forgot step X" failure mode by routing
# every target through one verified pipeline.
#
# Targets:
#   machine         — new dev machine setup (subs 2 #110)
#   repo            — new consumer repo setup (sub 3 #111)
#   plugin          — plugin release / cache prep (sub 4 #112)
#   feature-branch  — pre-work SSOT prereq check (sub 5 #113)
#
# Per-target logic lands in sub-issues; this skeleton handles flag
# parsing + dispatch. Unimplemented targets return rc=3 with a
# helpful "not yet implemented in sub-N" pointer.
#
# Usage:
#   scripts/meta-bootstrap.sh --target <machine|repo|plugin|feature-branch> [args...]
#   scripts/meta-bootstrap.sh --target X --verify-only
#   scripts/meta-bootstrap.sh --help

TARGET=""
VERIFY_ONLY=0
EXTRA_ARGS=()

_log() { echo "[meta-bootstrap] $*" >&2; }

_usage() {
	cat <<USAGE
usage: scripts/meta-bootstrap.sh --target <TARGET> [--verify-only] [-- <args>]

Targets:
  machine         New dev machine setup
  repo            New consumer repo bootstrap
  plugin          Plugin release / cache packaging
  feature-branch  Pre-work SSOT prereq check

Flags:
  --target T     Required. One of {machine, repo, plugin, feature-branch}.
  --verify-only  Run verification rules only; no mutation.
  --help, -h     Show this help.

Anything after \`--\` is forwarded to the target's underlying script.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		if [ $# -lt 2 ]; then
			echo "error: --target requires a value (machine|repo|plugin|feature-branch)" >&2
			exit 2
		fi
		TARGET="$2"
		shift 2
		;;
	--verify-only)
		VERIFY_ONLY=1
		shift
		;;
	-h | --help)
		_usage
		exit 0
		;;
	--)
		shift
		EXTRA_ARGS+=("$@")
		break
		;;
	-*)
		echo "error: unknown flag: $1" >&2
		_usage >&2
		exit 2
		;;
	*)
		EXTRA_ARGS+=("$1")
		shift
		;;
	esac
done

if [ -z "$TARGET" ]; then
	echo "error: --target is required" >&2
	_usage >&2
	exit 2
fi

case "$TARGET" in
machine | repo | plugin | feature-branch) ;;
*)
	echo "error: invalid --target: $TARGET (expected machine|repo|plugin|feature-branch)" >&2
	exit 2
	;;
esac

# Dispatch — per-target functions land in sub-issues #110-#113.
# Skeleton returns rc=3 (unimplemented) with the tracking sub-issue.
_dispatch_machine() {
	_log "ERROR: --target machine not yet implemented (tracking: sub-issue #110)"
	return 3
}
_dispatch_repo() {
	_log "ERROR: --target repo not yet implemented (tracking: sub-issue #111)"
	return 3
}
_dispatch_plugin() {
	_log "ERROR: --target plugin not yet implemented (tracking: sub-issue #112)"
	return 3
}
_dispatch_feature_branch() {
	_log "ERROR: --target feature-branch not yet implemented (tracking: sub-issue #113)"
	return 3
}

if [ "$VERIFY_ONLY" = "1" ]; then
	_log "verify-only mode: $TARGET"
else
	_log "running target: $TARGET"
fi

case "$TARGET" in
machine) _dispatch_machine "${EXTRA_ARGS[@]:-}" ;;
repo) _dispatch_repo "${EXTRA_ARGS[@]:-}" ;;
plugin) _dispatch_plugin "${EXTRA_ARGS[@]:-}" ;;
feature-branch) _dispatch_feature_branch "${EXTRA_ARGS[@]:-}" ;;
esac
