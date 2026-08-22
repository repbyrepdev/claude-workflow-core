#!/usr/bin/env bash
set -euo pipefail
# v0.34.122 (#2536): install version-agnostic hook launchers, and migrate any
# version-pinned hook registrations in settings.json onto them.
#
# THE BUG: register-hook.sh and hooks/install-hooks.sh both baked an ABSOLUTE,
# version-pinned path into the operator's global settings.json. A cache bump
# plus GC of the old version dir left every registration 404'ing — and, before
# the GC, silently executing a stale build. Observed live 2026-08-22: 58 refs
# pinned to 0.34.108 while the repo was 0.34.121, which is what made the phase-1
# guard run a copy predating its own escape hatches (#2531).
#
# THE FIX: settings.json points at a stable launcher dir OUTSIDE the versioned
# cache. Each launcher re-resolves the newest cache version containing its own
# hook AT RUN TIME (see _lib/plugin-cache-resolve.sh). Nothing is pinned, so
# nothing can dangle, and a `/reload` propagates everywhere with no migration.
#
# Usage:
#   install-hook-launchers.sh [--generate] [--migrate] [--check] [--dry-run]
#     --generate  (default) write/refresh a launcher per auto-register hook
#     --migrate   rewrite version-pinned settings.json refs onto the launchers
#     --check     report drift only; rc 1 if anything would change
#     --dry-run   print the plan, change nothing
#
# Exit codes: 0 ok · 1 drift found (--check) · 2 usage/precondition · 3 write failure

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../_lib/plugin-cache-resolve.sh
. "$SCRIPT_DIR/../_lib/plugin-cache-resolve.sh"
# shellcheck source=../_lib/event-frontmatter.sh
. "$SCRIPT_DIR/../_lib/event-frontmatter.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
LAUNCHER_DIR=$(pcr_launcher_dir)

DO_GENERATE=1 DO_MIGRATE=0 CHECK_ONLY=0 DRY_RUN=0
while [ $# -gt 0 ]; do
	case "$1" in
	--generate) DO_GENERATE=1 ;;
	--migrate) DO_MIGRATE=1 ;;
	--check)
		CHECK_ONLY=1
		DO_MIGRATE=1
		;;
	--dry-run) DRY_RUN=1 ;;
	-h | --help)
		sed -n '4,26p' "$0"
		exit 0
		;;
	*)
		echo "install-hook-launchers: unknown arg: $1" >&2
		exit 2
		;;
	esac
	shift
done

command -v jq >/dev/null 2>&1 || {
	echo "install-hook-launchers: jq required but not found" >&2
	exit 2
}

_log() { echo "[install-hook-launchers] $*" >&2; }

# ---- 1. generate launchers ------------------------------------------------
# One launcher per auto-register hook. Idempotent: a launcher whose content is
# already byte-correct is left alone, so re-running is a no-op and mtimes stay
# meaningful.
drift=0
if [ "$DO_GENERATE" -eq 1 ]; then
	if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
		mkdir -p "$LAUNCHER_DIR" || {
			echo "install-hook-launchers: cannot create $LAUNCHER_DIR" >&2
			exit 3
		}
	fi
	shopt -s nullglob
	for hook in "$HOOKS_DIR"/*.sh; do
		base=${hook##*/}
		event_frontmatter_skip_basename "$base" && continue
		# Only hooks that opt in to auto-registration get a launcher.
		grep -qE '^#[[:space:]]*auto-register:[[:space:]]*true' "$hook" || continue
		want=$(pcr_launcher_body "$base")
		target="$LAUNCHER_DIR/$base"
		if [ -f "$target" ] && [ "$(cat "$target")" = "$want" ] && [ -x "$target" ]; then
			continue
		fi
		drift=1
		if [ "$CHECK_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
			_log "would write launcher: $target"
			continue
		fi
		# Atomic: write to a mktemp sibling then mv, so a concurrent hook
		# invocation never reads a half-written launcher.
		tmp=$(mktemp "$LAUNCHER_DIR/.${base}.XXXXXX") || {
			echo "install-hook-launchers: mktemp failed in $LAUNCHER_DIR" >&2
			exit 3
		}
		printf '%s\n' "$want" >"$tmp" || {
			rm -f "$tmp"
			echo "install-hook-launchers: write failed for $target" >&2
			exit 3
		}
		chmod 755 "$tmp" || {
			rm -f "$tmp"
			echo "install-hook-launchers: chmod failed for $target" >&2
			exit 3
		}
		mv -f "$tmp" "$target" || {
			rm -f "$tmp"
			echo "install-hook-launchers: mv failed for $target" >&2
			exit 3
		}
		_log "installed launcher: $base"
	done
	shopt -u nullglob
fi

# ---- 2. migrate settings.json --------------------------------------------
[ "$DO_MIGRATE" -eq 1 ] || {
	[ "$drift" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ] && exit 1
	exit 0
}

[ -f "$SETTINGS" ] || {
	_log "NOTE: $SETTINGS not found — nothing to migrate"
	exit 0
}
jq empty "$SETTINGS" 2>/dev/null || {
	echo "install-hook-launchers: $SETTINGS is not valid JSON — refusing to touch it" >&2
	exit 3
}

# Enumerate EVERY referenced version, not just the newest. A settings.json that
# accumulated refs across upgrades is mixed-version, and healing only the max
# while reporting success was defect #2 of the reverted first attempt.
pinned_json=$(jq -r '
  [.. | strings
   | select(test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/hooks/"))]
  | unique
' "$SETTINGS" 2>/dev/null) || {
	echo "install-hook-launchers: jq failed enumerating pinned refs — refusing to migrate (fail-closed)" >&2
	exit 3
}
pinned_count=$(printf '%s' "$pinned_json" | jq -r 'length' 2>/dev/null) || pinned_count=""
# FAIL CLOSED on an unusable count. The reverted attempt ran its verification
# inside a heredoc command substitution, so a jq error produced empty output,
# the verify loop body never ran, and it "verified" zero paths and healed
# anyway. An unreadable enumeration must abort, never proceed.
case "$pinned_count" in '' | *[!0-9]*)
	echo "install-hook-launchers: could not count pinned refs — refusing to migrate (fail-closed)" >&2
	exit 3
	;;
esac
if [ "$pinned_count" -eq 0 ]; then
	_log "no version-pinned hook refs in $SETTINGS — already launcher-based or never registered"
	[ "$drift" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ] && exit 1
	exit 0
fi

# Report per-version so a mixed-version settings.json is visible, not averaged.
_log "found $pinned_count version-pinned hook ref(s) across version(s):"
printf '%s' "$pinned_json" |
	jq -r '.[] | capture("claude-workflow-core/claude-workflow-core/(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)/").v' |
	sort | uniq -c | while read -r n v; do _log "    v$v — $n ref(s)"; done

# Only migrate a ref whose basename has a launcher we actually installed —
# otherwise the rewrite would point at a file that does not exist. This is the
# completeness guard, and it is enforced per-ref rather than per-version.
missing=0
have_list=""
while IFS= read -r ref; do
	[ -n "$ref" ] || continue
	b=${ref##*/}
	if [ -f "$LAUNCHER_DIR/$b" ]; then
		have_list="$have_list$b"$'\n'
	else
		_log "WARN: no launcher for $b — leaving its ref pinned (rewriting it would dangle)"
		missing=$((missing + 1))
	fi
done < <(printf '%s' "$pinned_json" | jq -r '.[]')
# The exact set the jq rewrite below is allowed to touch. Built from real `-f`
# probes so the gate ENFORCES what the warning above claims — before this, the
# walk rewrote every matching ref including the ones it had just warned it would
# leave alone, which would have pointed settings.json at a nonexistent file.
have_json=$(printf '%s' "$have_list" | jq -Rsc 'split("\n") | map(select(length > 0))') || {
	echo "install-hook-launchers: could not build the launcher allowlist — refusing to migrate (fail-closed)" >&2
	exit 3
}

if [ "$CHECK_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
	_log "would rewrite $((pinned_count - missing)) ref(s) onto $LAUNCHER_DIR"
	exit 1
fi

# Serialize against concurrent sessions. settings.json is a global mutable file
# that every session, install-hooks.sh, and migrate-settings.sh may rewrite; the
# reverted attempt had no lock at all, so two sessions starting together could
# lose one another's writes. mkdir is the portable atomic test-and-set (macOS
# has no flock(1)).
LOCK="$LAUNCHER_DIR/.settings-migrate.lock"
_lock_held=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if mkdir "$LOCK" 2>/dev/null; then
		_lock_held=1
		break
	fi
	sleep 0.3
done
[ "$_lock_held" -eq 1 ] || {
	echo "install-hook-launchers: could not acquire $LOCK after ~3s — another migration is running; not touching $SETTINGS" >&2
	exit 3
}
# shellcheck disable=SC2064  # intentional: expand LOCK now, at trap-set time
trap "rmdir '$LOCK' 2>/dev/null || true" EXIT

# Backup, without ever clobbering an existing one. A deterministic name plus an
# unconditional cp (the reverted attempt) overwrites the pristine backup with
# the already-mutated file on a second run — destroying the only rollback
# artifact exactly when it is needed. mktemp gives a fresh name every time.
bak=$(mktemp "${SETTINGS}.bak-launchers.XXXXXX") || {
	echo "install-hook-launchers: mktemp for backup failed — not touching $SETTINGS" >&2
	exit 3
}
cp "$SETTINGS" "$bak" || {
	echo "install-hook-launchers: backup copy to $bak failed — not touching $SETTINGS" >&2
	exit 3
}

tmp=$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX") || {
	echo "install-hook-launchers: mktemp for rewrite failed (backup at $bak) — $SETTINGS unchanged" >&2
	exit 3
}
# Named per-step failures below: the reverted attempt wrapped every step in
# `2>/dev/null` and emitted one message that could not say which step failed,
# and asserted "settings left untouched" without knowing whether mv had run.
if ! jq --arg dir "$LAUNCHER_DIR" --argjson have "$have_json" '
  def relaunch:
    if type == "string" and test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/hooks/")
    then (split("/hooks/") | .[-1]) as $b
         # Rewrite ONLY when a launcher for this basename actually exists.
         # Without this membership gate the walk relaunched every matching ref,
         # including ones the completeness check had just warned it would leave
         # pinned — the warning was true prose over a false action. Caught by
         # dogfooding: review-log.sh has no launcher (not auto-register) yet was
         # still rewritten, which would have pointed settings.json at a file that
         # does not exist. Leaving it pinned is strictly safer than dangling it.
         | (if ($have | index($b)) then ($dir + "/" + $b) else . end)
    else . end;
  walk(relaunch)
' "$SETTINGS" >"$tmp" 2>/dev/null; then
	rm -f "$tmp"
	echo "install-hook-launchers: STEP=rewrite jq failed — $SETTINGS unchanged, backup at $bak" >&2
	exit 3
fi
if ! jq empty "$tmp" 2>/dev/null; then
	rm -f "$tmp"
	echo "install-hook-launchers: STEP=revalidate produced invalid JSON — $SETTINGS unchanged, backup at $bak" >&2
	exit 3
fi
# Preserve mode/owner. `mv` replaces the inode, so a temp created at the ambient
# umask silently changes settings.json's permissions — this file has already
# drifted that way once (its .bak siblings are 600 while it is 644).
if ! chmod --reference="$SETTINGS" "$tmp" 2>/dev/null; then
	_mode=$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || stat -c '%a' "$SETTINGS" 2>/dev/null || echo "")
	if [ -n "$_mode" ]; then
		chmod "$_mode" "$tmp" 2>/dev/null ||
			_log "WARN: STEP=preserve-mode could not apply mode $_mode — continuing"
	else
		_log "WARN: STEP=preserve-mode could not read original mode — continuing"
	fi
fi
if ! mv -f "$tmp" "$SETTINGS"; then
	rm -f "$tmp"
	echo "install-hook-launchers: STEP=replace mv failed — $SETTINGS unchanged, backup at $bak" >&2
	exit 3
fi

_log "✓ migrated $((pinned_count - missing)) hook ref(s) to $LAUNCHER_DIR (backup: $bak)"
_log "  these are now version-agnostic — a cache bump + GC can no longer dangle them"
exit 0
