#!/bin/bash
set -euo pipefail
# ship-pr-cycle skill wrapper.
#
# Wraps `scripts/ship-pr-cycle.sh` with SKILL_WRAPPER=1 exported so the
# underlying `gh` / `git push` calls don't get refused by skill-bypass-
# guard. Also normalizes the invocation surface so a Claude session
# triggering "ship-pr-cycle" via NL gets the same entry point regardless
# of how the call shape varies.
#
# Usage:
#   .claude/skills/ship-pr-cycle/run.sh start
#   .claude/skills/ship-pr-cycle/run.sh status
#   .claude/skills/ship-pr-cycle/run.sh next
#   .claude/skills/ship-pr-cycle/run.sh resume
#
# Args are passed verbatim to `scripts/ship-pr-cycle.sh`. Default = no-arg
# (prints usage block from the underlying script).
#
# Env (inherited via exec; documented here for visibility):
#   BASE_BRANCH                 — read by orchestrator (default 'main',
#                                 consumed in branch-ready stage)
#   SHIP_CYCLE_POST_COMMIT_SKIP — read by post-commit-ship-cycle.sh hook
# Env consumed elsewhere during the orchestrator's flow:
#   PIPELINE_GATE_SKIP          — read by .claude/hooks/pre-push-pipeline-gate.sh
#                                 when the orchestrator invokes git push;
#                                 NOT consumed by ship-pr-cycle.sh itself
#
# Exit codes: forwarded from `scripts/ship-pr-cycle.sh`:
#   0 — operation succeeded (state advanced or printed status)
#   1 — gate refused (e.g. phase0.5 not yet logged, no commits vs base)
#   2 — invocation error (missing tool, bad arg, real failure)

# Use ${BASH_SOURCE[0]} instead of $0 so resolution works whether the
# script is exec'd directly, sourced, or invoked via symlink.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || {
	echo "ship-pr-cycle skill: ERROR: cannot resolve skill dir from \${BASH_SOURCE[0]}=${BASH_SOURCE[0]:-<unset>}" >&2
	exit 2
}
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd) || {
	echo "ship-pr-cycle skill: ERROR: cannot resolve repo root from $SCRIPT_DIR" >&2
	exit 2
}
ORCHESTRATOR="$REPO_ROOT/scripts/ship-pr-cycle.sh"

if [ ! -x "$ORCHESTRATOR" ]; then
	echo "ship-pr-cycle skill: ERROR: $ORCHESTRATOR missing or not executable" >&2
	exit 2
fi

export SKILL_WRAPPER=1

exec "$ORCHESTRATOR" "$@"
