#!/bin/bash
set -euo pipefail
# event: SessionStart
# v0.30.A (#187): SessionStart chmod self-heal.
#
# Why: Layer 5 (chmod loop in scripts/install-hooks.sh) only fires on
# explicit invocation, not at SessionStart. When plugin updates / worktree
# migrations / file shuffles strip the +x bit from a hook, the next
# SessionStart surfaces it as "Permission denied" and blocks the hook from
# firing — but only AFTER session boot, so the user is already in a broken
# session by the time they see it. Anchor case: hooks/cr-auto-parse-poll.sh
# lost +x between sessions (cause unknown — likely a plugin cache shuffle),
# surfaced at SessionStart 2026-05-29.
#
# This hook re-asserts +x on every *.sh under hooks/ and .claude/hooks/
# at session start. Idempotent. Silent on healthy state. Emits a single
# stderr notice only when it actually fixed something so SessionStart
# output stays clean.
#
# Registration: append this hook's absolute path to ~/.claude/settings.json
# under hooks.SessionStart[].hooks[]. See README §Install for an idempotent
# jq snippet (or run scripts/install-hooks.sh --register-session-hooks once
# v0.30.A ships).

# Resolve repo root from script location (not git rev-parse) — the same
# pattern install-hooks.sh uses, so it works inside worktrees / submodules
# without conflating cwd with the plugin repo.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Exit cleanly if the path is broken — never block SessionStart.
[ -d "$REPO_ROOT" ] || exit 0
cd "$REPO_ROOT" || exit 0

shopt -s nullglob
fixed=()
for d in hooks .claude/hooks; do
	[ -d "$d" ] || continue
	for h in "$d"/*.sh; do
		[ -f "$h" ] || continue
		if [ ! -x "$h" ]; then
			# Best-effort chmod. If we can't write (rare — e.g., read-only
			# mount, EPERM in a restricted shell), skip silently rather than
			# failing the SessionStart. Logged for diagnostics.
			if chmod +x "$h" 2>/dev/null; then
				fixed+=("$h")
			fi
		fi
	done
done
shopt -u nullglob

if [ "${#fixed[@]}" -gt 0 ]; then
	printf 'session-start-chmod-self-heal: restored +x on %d hook(s):\n' "${#fixed[@]}" >&2
	printf '  %s\n' "${fixed[@]}" >&2
fi

exit 0
