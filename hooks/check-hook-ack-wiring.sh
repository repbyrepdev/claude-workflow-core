#!/bin/bash
set -euo pipefail
# event: SessionStart
# v4.28-W3-C r5 (#683): SessionStart advisory — scans every hook in
# .claude/hooks/ via the shared event-frontmatter SSOT and warns to
# stderr if any hook with `# event:` frontmatter is NOT registered in
# the operator's user-scope ~/.claude/settings.json.
#
# Why advisory: the bodies live in-repo but the wiring is per-machine
# (~/.claude/settings.json is operator-local, not committed). On a fresh
# clone or a teammate's box, `install-hooks.sh` must be run before any
# hook fires. This advisory surfaces missing wiring at session start so
# the operator runs the installer instead of silently shipping with
# paper-tiger gates.
#
# Single-pane behavior: appends to the universal hook-ack sentinel
# (.claude/.session-state/hook-output-pending.txt) so the
# stale-state-gate also nudges on the next Bash if the session-start
# message scrolled away.
#
# Bypass: HOOK_ACK_WIRING_CHECK_SKIP=1 (operator-explicit; non-blocking
# anyway, this just silences the warning).

if [ "${HOOK_ACK_WIRING_CHECK_SKIP:-0}" = "1" ]; then
	exit 0
fi

# shellcheck disable=SC2034  # REPO_ROOT may be referenced by sourced libs

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SETTINGS="${HOME}/.claude/settings.json"
LIB_FRONTMATTER="$(dirname "$0")/../_lib/event-frontmatter.sh"
LIB_HOOK_ACK="$(dirname "$0")/../_lib/hook-ack.sh"

# v0.31 #228: scan the REPO's source hooks dir (resolved via REPO_ROOT), NOT
# $(dirname "$0") — which, wired via the pinned plugin-cache path, is the FROZEN
# cache copy, blind to source-only hooks added after the pin.
# #228 r1 (silent-failure-hunter): disambiguate plugin vs consumer by the PLUGIN
# MARKER (.claude-plugin/plugin.json at the repo root), NOT mere presence of a
# top-level hooks/ — a consumer with an unrelated top-level hooks/ dir must scan
# .claude/hooks/, never be shadowed by it. NOTE: discover-orphan-hooks.sh
# resolves its hooks dir DIFFERENTLY by design — it derives REPO_ROOT
# script-relative ($SCRIPT_DIR/..), so its parent is already .claude/ in a
# consumer and it is immune to this top-level-hooks shadow; this hook is a
# cache-wired SessionStart hook so it must use git-toplevel + the plugin marker.
if [ -f "$REPO_ROOT/.claude-plugin/plugin.json" ] && [ -d "$REPO_ROOT/hooks" ]; then
	HOOKS_DIR="$REPO_ROOT/hooks" # plugin source layout
elif [ -d "$REPO_ROOT/.claude/hooks" ]; then
	HOOKS_DIR="$REPO_ROOT/.claude/hooks" # consumer layout
elif [ -d "$REPO_ROOT/hooks" ]; then
	HOOKS_DIR="$REPO_ROOT/hooks" # non-plugin repo with a top-level hooks/
else
	HOOKS_DIR="$(dirname "$0")" # out-of-repo fallback
	case "$HOOKS_DIR" in
	*/plugins/cache/*)
		echo "check-hook-ack-wiring: not inside a source repo (cwd=$(pwd)); scanning the pinned cache copy — source-only hooks added after the pin are NOT visible. cd into the plugin source for a full scan." >&2
		;;
	esac
fi

[ -f "$SETTINGS" ] || exit 0
[ -f "$LIB_FRONTMATTER" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# shellcheck source=../_lib/event-frontmatter.sh
source "$LIB_FRONTMATTER"

# Collect (event, matcher, basename) triples from every hook with valid
# frontmatter. event_frontmatter_parse emits 4 lines: event, matcher,
# auto_register, enforcement (#2547) — this consumer reads the first 3;
# auto_register==false means operator opted out of automatic
# registration → don't warn.
missing=""
for hook in "$HOOKS_DIR/"*.sh; do
	[ -f "$hook" ] || continue
	base=${hook##*/}
	event_frontmatter_skip_basename "$base" && continue
	parsed=$(event_frontmatter_parse "$hook" 2>/dev/null) || continue
	event=$(printf '%s\n' "$parsed" | sed -n '1p')
	matcher=$(printf '%s\n' "$parsed" | sed -n '2p')
	auto_register=$(printf '%s\n' "$parsed" | sed -n '3p')
	[ -z "$event" ] && continue
	[ "$auto_register" = "false" ] && continue
	event_frontmatter_event_valid "$event" || continue
	# Check settings.json for this (event, matcher) → basename presence.
	hit=$(jq --arg ev "$event" --arg mt "$matcher" --arg bn "$base" '
		(.hooks[$ev] // [])
		| map(select((.matcher // "") == $mt))
		| map(.hooks // []) | flatten
		| map(.command // "") | map(split("/") | last)
		| any(. == $bn)
	' "$SETTINGS" 2>/dev/null || echo false)
	if [ "$hit" != "true" ]; then
		missing="${missing}
  - $event ${matcher:-(no matcher)} → $base"
	fi
done

[ -z "$missing" ] && exit 0

{
	echo "⚠ hook wiring incomplete in $SETTINGS:$missing"
	echo "  → Run: .claude/hooks/install-hooks.sh"
	echo "  → Bypass advisory: HOOK_ACK_WIRING_CHECK_SKIP=1"
} >&2

# Append to the universal sentinel so the stale-state-gate nudges the
# operator on next Bash too. Best-effort: failures here don't fail the
# advisory.
if [ -f "$LIB_HOOK_ACK" ]; then
	# shellcheck source=../_lib/hook-ack.sh
	source "$LIB_HOOK_ACK"
	if command -v hook_ack_append >/dev/null 2>&1; then
		hook_ack_append "check-hook-ack-wiring" "wiring-incomplete" "$SETTINGS"
	fi
fi

exit 0
