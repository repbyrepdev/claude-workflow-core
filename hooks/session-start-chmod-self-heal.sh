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
# under hooks.SessionStart[].hooks[]. Auto-registration via install-hooks.sh
# is intentionally deferred to a follow-up issue under epic #186 (the
# settings.json edit logic deserves its own dogfood pass).

# Resolve repo root from script location (not git rev-parse) — same pattern
# install-hooks.sh uses. WHY: SessionStart fires before cwd is necessarily
# inside the repo (could be a subdir worktree, /tmp, etc.), so git rev-parse
# may fail or resolve the wrong repo. Capture cd failures explicitly — if
# the script's own dirname is broken (orphan symlink, deleted worktree),
# fail loud-but-non-blocking so the operator knows the self-heal no-op'd.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || SCRIPT_DIR=""
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
	echo "session-start-chmod-self-heal: cannot resolve script dir (broken symlink or worktree?) — skipping self-heal" >&2
	exit 0
fi
REPO_ROOT=$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd) || REPO_ROOT=""
# Sanity-check REPO_ROOT looks like the plugin repo — refuse to chmod inside
# / or a random parent dir if the cd somehow degraded.
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ] || [ ! -e "$REPO_ROOT/.claude" ]; then
	echo "session-start-chmod-self-heal: REPO_ROOT='$REPO_ROOT' missing .claude/ marker — refusing self-heal" >&2
	exit 0
fi
cd "$REPO_ROOT" || exit 0

shopt -s nullglob
fixed=()
failed=()
for d in hooks .claude/hooks; do
	[ -d "$d" ] || continue
	for h in "$d"/*.sh; do
		[ -f "$h" ] || continue
		if [ ! -x "$h" ]; then
			# Best-effort chmod. On failure (EPERM / EROFS / EIO / ENOSPC)
			# collect the path + error so the operator sees WHY the heal
			# didn't take. Never block SessionStart — exit 0 either way.
			if chmod_err=$(chmod +x "$h" 2>&1); then
				fixed+=("$h")
			else
				failed+=("$h: $chmod_err")
			fi
		fi
	done
done
shopt -u nullglob

if [ "${#fixed[@]}" -gt 0 ]; then
	printf 'session-start-chmod-self-heal: restored +x on %d hook(s):\n' "${#fixed[@]}" >&2
	printf '  %s\n' "${fixed[@]}" >&2
fi
if [ "${#failed[@]}" -gt 0 ]; then
	printf 'session-start-chmod-self-heal: FAILED to restore +x on %d hook(s):\n' "${#failed[@]}" >&2
	printf '  %s\n' "${failed[@]}" >&2
fi

exit 0
