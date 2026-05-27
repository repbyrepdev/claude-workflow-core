#!/bin/bash
set -euo pipefail
# meta-bootstrap.sh — single entry point for every setup target.
#
# Replaces the fragmented "I forgot step X" failure mode by routing
# every target through one verified pipeline.
#
# Targets:
#   machine         — new dev machine setup
#   repo            — new consumer repo setup
#   plugin          — plugin release / cache prep
#   feature-branch  — pre-work SSOT prereq check
#
# Per-target logic lands in follow-up sub-issues; this skeleton handles
# flag parsing + dispatch. Unimplemented targets return rc=69 (per
# sysexits EX_UNAVAILABLE) with a tracking-issue pointer.
#
# Exit codes (stable contract):
#   0   success
#   2   argparse error (missing/invalid --target, unknown flag)
#   69  unimplemented target (matches sysexits EX_UNAVAILABLE; distinct
#       from the repo's rc=3 "refused due to malformed precondition"
#       used by register-hook.sh / ship-pr-cycle.sh / etc.)
#   70  internal dispatch-table bug (should be unreachable; defense in
#       depth in case a future TARGET addition skips the case statement)
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

# Dispatch — per-target functions land in follow-up sub-issues. While
# unimplemented, each target returns rc=69 (EX_UNAVAILABLE) with a
# tracking-issue pointer in the log line so a caller can grep the
# tracker if they hit it. Tracking refs are intentional in the
# user-facing message (operators need to know where the work is).
_dispatch_machine() {
	_log "ERROR: --target machine not yet implemented (tracking: meta-bootstrap machine flow, sub-issue of #78)"
	return 69
}
_dispatch_repo() {
	_log "ERROR: --target repo not yet implemented (tracking: meta-bootstrap repo flow, sub-issue of #78)"
	return 69
}
_dispatch_plugin() {
	_log "ERROR: --target plugin not yet implemented (tracking: meta-bootstrap plugin flow, sub-issue of #78)"
	return 69
}
_dispatch_feature_branch() {
	_log "ERROR: --target feature-branch not yet implemented (tracking: meta-bootstrap feature-branch flow, sub-issue of #78)"
	return 69
}

# --verify-only currently has no per-target hook — refuse explicitly
# so callers don't get silent mutation when sub-issues land mutating
# logic without honoring the flag. When a target wires verify-only,
# replace this guard with the per-target verify dispatch.
if [ "$VERIFY_ONLY" = "1" ]; then
	_log "ERROR: --verify-only not yet wired for any target (skeleton; sub-issue of #78 implements per-target verify hooks)"
	exit 69
fi

_log "running target: $TARGET"

# set -u-safe expansion: when EXTRA_ARGS is empty pass zero args, not
# one empty-string. Future dispatchers will rely on arg-count accuracy.
case "$TARGET" in
machine) _dispatch_machine ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
repo) _dispatch_repo ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
plugin) _dispatch_plugin ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
feature-branch) _dispatch_feature_branch ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ;;
*)
	# Defense in depth — unreachable given the validator above, but
	# catches a future case-label drift that skipped the validator
	# update.
	_log "ERROR: dispatch table missing case for $TARGET (internal bug)"
	exit 70
	;;
esac
