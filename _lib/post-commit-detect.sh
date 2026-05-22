#!/bin/bash
# auto-register: false
set -u
# v4.28-W4 #851 r1 (#705 Phase 2) — shared post-commit detection lib.
#
# Two PostToolUse Bash hooks (phase0.5-post-commit-rerun.sh,
# post-commit-template-lint.sh) had near-identical "is this a successful
# git commit invocation" boilerplate copy-pasted. SSOT-first: extracted
# here so a future schema bump (e.g. exit_code field rename, wrapper
# pattern change) is a one-file fix.
#
# Public API:
#
#   post_commit_detect_init
#     Reads stdin (Claude Code Bash payload JSON), extracts CMD +
#     EXIT_CODE, sources cmd-anchor.sh, runs match_git_commit_or_wrapper.
#     Returns 0 IFF the invocation is a successful `git commit` (direct
#     OR via the git-commit skill wrapper). Returns 1 otherwise.
#
#     On success, exports these vars for the caller:
#       PAYLOAD   — the raw stdin JSON (callers may need it for other
#                   tool_response fields)
#       CMD       — the extracted .tool_input.command string
#       EXIT_CODE — the extracted .tool_response.exit_code (default "1"
#                   if missing, so unknown→skip is the safe path)
#
# This is a sourced library — uses `set -u` only (NOT -e/-o pipefail,
# which would propagate to the sourcing hook's flow control).

post_commit_detect_init() {
	# Read Claude Code hook payload from stdin. fall-back-to-{} preserves
	# the existing per-hook behavior — empty/broken stdin = no-op skip.
	PAYLOAD=$(cat 2>/dev/null || echo "{}")
	export PAYLOAD

	CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
	export CMD
	[ -z "$CMD" ] && return 1

	# Source cmd-anchor.sh for match_git_commit_or_wrapper. Path is
	# relative to THIS lib (.claude/_lib/post-commit-detect.sh), which
	# is co-located with cmd-anchor.sh.
	local _self_dir
	_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	# shellcheck source=cmd-anchor.sh
	. "$_self_dir/cmd-anchor.sh"

	if ! match_git_commit_or_wrapper "$CMD"; then
		return 1
	fi

	# Only continue on a SUCCESSFUL commit. Unknown / failed (rc != 0)
	# means the commit didn't land — prior phase-0.5 / template-lint
	# work has nothing to do, and the pre-commit gate will surface any
	# real failure.
	EXIT_CODE=$(printf '%s' "$PAYLOAD" | jq -r '.tool_response.exit_code // .tool_response.exitCode // 1' 2>/dev/null || echo "1")
	export EXIT_CODE
	[ "$EXIT_CODE" = "0" ] || return 1

	return 0
}
