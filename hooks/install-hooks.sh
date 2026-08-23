#!/bin/bash
set -euo pipefail
# v4.28 (#638) — frontmatter-scanning hook installer.
#
# Replaces install-v4.27-hooks.sh (deleted in this PR). Reads each hook
# script's header for `# event:` / `# matcher:` / `# auto-register:`
# directives and registers in ~/.claude/settings.json idempotently.
#
# Frontmatter format (in the first 30 lines of each hook, AFTER `set -u*`):
#   # event: PreToolUse | PostToolUse | SessionStart | PreCompact | Stop | UserPromptSubmit
#   # matcher: Bash | Edit | Write | "Edit|Write" | (omit for matcherless events)
#   # auto-register: true | false  (default: true if # event: is present)
#
# Filename-based skips (independent of frontmatter):
#   `_*.sh`         — helpers called by other hooks, by convention
#   `install-*.sh`  — installer scripts
#
# Hooks WITHOUT a `# event:` header are treated as helpers and skipped.
#
# Behavior: ADDITIVE-ONLY. New hooks get registered; existing settings.json
# entries are PRESERVED unchanged. Renaming or deleting a hook does NOT
# auto-prune the stale entry from settings.json — manual cleanup is required
# until a prune phase is added (tracked as v4.28 follow-up under #635).
# Idempotent: re-running with no new hooks is a no-op.
#
# All-or-nothing transactional WITHIN A RUN: preflight every hook (exists +
# executable + parseable frontmatter), accumulate edits in a WORKING tempfile,
# atomic mv only if every step succeeds.
#
# Exit codes:
#   0 — success (installation complete, possibly no-op)
#   1 — preflight failure (missing/non-executable hook, malformed frontmatter)
#   2 — usage error / settings.json missing

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOOKS_DIR="$SCRIPT_DIR"
USER_SETTINGS="$HOME/.claude/settings.json"

# Per-hook timeout (seconds) inserted into every settings.json entry.
# Override via env: HOOK_TIMEOUT=10 .claude/hooks/install-hooks.sh
HOOK_TIMEOUT="${HOOK_TIMEOUT:-5}"

# Source the shared frontmatter library — same SSOT used by the pre-commit
# event-frontmatter-check.sh gate. Renaming the helper convention or adding
# a 7th event is a one-file edit.
# shellcheck source=../_lib/event-frontmatter.sh
. "$SCRIPT_DIR/../_lib/event-frontmatter.sh"

# (#2536) Version-agnostic launcher resolution. Best-effort: without it the
# registration loop below falls back to version-pinned paths, which still work
# until the referenced cache version is pruned.
# Try BOTH supported layouts (../_lib and ../../_lib) before giving up — the
# same candidate list the phase1 guards use. A single hardcoded hop silently
# fell through to version-pinned registration in the other layout, which is the
# exact dangling-ref failure #2536 exists to end (CR-in-CI #2540).
_IH_LIB=""
for _ih_c in "$SCRIPT_DIR/../_lib/plugin-cache-resolve.sh" "$SCRIPT_DIR/../../_lib/plugin-cache-resolve.sh"; do
	[ -r "$_ih_c" ] && {
		_IH_LIB="$_ih_c"
		break
	}
done
if [ -n "$_IH_LIB" ]; then
	# shellcheck source=../_lib/plugin-cache-resolve.sh
	. "$_IH_LIB" ||
		echo "install-hooks: WARN: plugin-cache-resolve.sh failed to source — registrations will be version-pinned" >&2
else
	echo "install-hooks: WARN: plugin-cache-resolve.sh not found in either layout — registrations will be version-pinned" >&2
fi

# ---- preflight -----------------------------------------------------------

[ -f "$USER_SETTINGS" ] || {
	echo "install-hooks: $USER_SETTINGS not found" >&2
	exit 2
}

command -v jq >/dev/null 2>&1 || {
	echo "install-hooks: jq required but not found — install with 'brew install jq'" >&2
	exit 2
}

# ---- collect register-targets -------------------------------------------

# Parallel arrays — index aligned. Avoids packing event|matcher|hook into a
# single string, which breaks when matcher contains `|` (e.g. "Edit|Write").
declare -a TGT_EVENT=()
declare -a TGT_MATCHER=()
declare -a TGT_HOOK=()

# nullglob: empty `*.sh` glob expands to nothing instead of the literal pattern.
# Restored after the loop so we don't leak the option to callers/tests.
shopt -s nullglob
for hook in "$HOOKS_DIR"/*.sh; do
	[ -f "$hook" ] || continue # belt-and-suspenders for non-file matches
	# Skip helpers (`_*`) and installers (`install-*`) — shared lib decides.
	base=$(basename "$hook")
	if event_frontmatter_skip_basename "$base"; then
		continue
	fi

	# Read line-by-line into an array — preserves empty fields (which bash
	# `read -r` with tab-IFS would collapse). bash 3.2 portable: avoids
	# `mapfile` (4.0+) and `readarray` aliases.
	# Capture event_frontmatter_parse's stdout + rc explicitly: process-
	# substitution `done < <(parse)` swallowed the rc, so a parse error
	# read as "no frontmatter = helper, skip" rather than failing loudly.
	_parsed=()
	if ! _parse_out=$(event_frontmatter_parse "$hook"); then
		echo "install-hooks: failed to parse frontmatter in $base" >&2
		exit 1
	fi
	while IFS= read -r _line; do
		_parsed+=("$_line")
	done <<<"$_parse_out"
	event="${_parsed[0]:-}"
	matcher="${_parsed[1]:-}"
	auto_register="${_parsed[2]:-true}"
	[ -z "$event" ] && continue # no frontmatter = helper, skip
	[ "$auto_register" = "false" ] && continue

	# Validate event name is one we know — shared lib defines the canonical set.
	if ! event_frontmatter_event_valid "$event"; then
		echo "install-hooks: unknown event '$event' in $base — add to .claude/_lib/event-frontmatter.sh" >&2
		exit 1
	fi

	# Validate matcher pairing. Matcherless events (UserPromptSubmit, Stop)
	# must NOT have a matcher; matcher-supporting events (PreToolUse, etc)
	# MUST have one. Catches typos like `# matcher: Startup` on PreToolUse
	# or `# matcher: Bash` on UserPromptSubmit before they get persisted to
	# settings.json (where Claude Code silently ignores them).
	if ! event_frontmatter_matcher_valid "$event" "$matcher"; then
		echo "install-hooks: invalid matcher '$matcher' for event '$event' in $base — see .claude/_lib/event-frontmatter.sh EVENT_FRONTMATTER_MATCHERLESS_EVENTS" >&2
		exit 1
	fi

	# Preflight: hook must be executable.
	[ -x "$hook" ] || {
		echo "install-hooks: $base is not executable (chmod +x required)" >&2
		exit 1
	}

	TGT_EVENT+=("$event")
	TGT_MATCHER+=("$matcher")
	# (#2536) Register the version-agnostic LAUNCHER when one exists, not this
	# file's own absolute path. $hook is derived from $BASH_SOURCE, so when this
	# installer runs from the plugin cache it resolves to
	# .../claude-workflow-core/<version>/hooks/<name>.sh — a version-pinned path
	# that 404s once that version is GC'd, and silently runs a stale build until
	# then. That is how 51 registrations ended up frozen at 0.34.108 while the
	# cache had advanced to 0.34.121. A launcher re-resolves at RUN TIME instead.
	# Falls back to $hook when no launcher is present (fresh install before
	# install-hook-launchers.sh has run) — version-pinned, but registered.
	_reg="$hook"
	if declare -f pcr_launcher_path >/dev/null 2>&1; then
		_cand=$(pcr_launcher_path "$base")
		[ -x "$_cand" ] && _reg="$_cand"
	fi
	TGT_HOOK+=("$_reg")
done
shopt -u nullglob

# ---- merge into ~/.claude/settings.json (idempotent, transactional) -----

WORKING=$(mktemp -t claude-settings.XXXXXX)
# Cleanup trap: remove tempfiles if the script exits early (set -e). The trap
# is cleared just before the final atomic mv so the destination isn't deleted.
trap 'rm -f "$WORKING" "${WORKING}.next" 2>/dev/null || true' EXIT
cp "$USER_SETTINGS" "$WORKING"

NEW_COUNT=0

for i in "${!TGT_HOOK[@]}"; do
	event="${TGT_EVENT[$i]}"
	matcher="${TGT_MATCHER[$i]}"
	hook="${TGT_HOOK[$i]}"

	# Idempotency check: is this exact (event, matcher, command) already there?
	# Matcher-isolated: matcherless hooks ONLY match groups that ALSO have no
	# matcher field. Without the `select(has("matcher") | not)`, a matcherless
	# event check would falsely "find" the command in a matcher-scoped group.
	if [ -n "$matcher" ]; then
		exists=$(jq --arg e "$event" --arg m "$matcher" --arg c "$hook" \
			'[.hooks[$e][]? | select(.matcher == $m) | .hooks[]? | select(.command == $c)] | length > 0' \
			"$WORKING")
	else
		exists=$(jq --arg e "$event" --arg c "$hook" \
			'[.hooks[$e][]? | select(has("matcher") | not) | .hooks[]? | select(.command == $c)] | length > 0' \
			"$WORKING")
	fi

	if [ "$exists" = "true" ]; then
		echo "✓ already registered: $event${matcher:+ $matcher} → $(basename "$hook")"
		continue
	fi

	# First-match-only insertion — append to existing matcher group OR create new group.
	if [ -n "$matcher" ]; then
		jq --arg e "$event" --arg m "$matcher" --arg c "$hook" --argjson t "$HOOK_TIMEOUT" '
			. as $root |
			if (.hooks[$e] // [] | map(select(.matcher == $m)) | length) > 0 then
				reduce range(0; .hooks[$e] | length) as $i (
					{ root: $root, done: false };
					if .done or (.root.hooks[$e][$i].matcher != $m) then .
					else
						.root.hooks[$e][$i].hooks //= []
						| .root.hooks[$e][$i].hooks += [{type:"command", command:$c, timeout:$t}]
						| .done = true
					end
				) | .root
			else
				.hooks //= {}
				| .hooks[$e] //= []
				| .hooks[$e] += [{matcher:$m, hooks:[{type:"command", command:$c, timeout:$t}]}]
			end
		' "$WORKING" >"$WORKING.next"
	else
		# Matcherless insert: only target groups WITHOUT a matcher field, so
		# a matcherless hook never lands inside a matcher-scoped group.
		jq --arg e "$event" --arg c "$hook" --argjson t "$HOOK_TIMEOUT" '
			. as $root |
			if (.hooks[$e] // [] | map(select(has("matcher") | not)) | length) > 0 then
				reduce range(0; .hooks[$e] | length) as $i (
					{ root: $root, done: false };
					if .done or (.root.hooks[$e][$i] | has("matcher")) then .
					else
						.root.hooks[$e][$i].hooks //= []
						| .root.hooks[$e][$i].hooks += [{type:"command", command:$c, timeout:$t}]
						| .done = true
					end
				) | .root
			else
				.hooks //= {}
				| .hooks[$e] //= []
				| .hooks[$e] += [{hooks:[{type:"command", command:$c, timeout:$t}]}]
			end
		' "$WORKING" >"$WORKING.next"
	fi

	mv "$WORKING.next" "$WORKING"
	NEW_COUNT=$((NEW_COUNT + 1))
	echo "+ registered: $event${matcher:+ $matcher} → $(basename "$hook")"
done

# ---- atomic commit ------------------------------------------------------

if [ "$NEW_COUNT" -gt 0 ]; then
	mv "$WORKING" "$USER_SETTINGS"
	# Clear the cleanup trap so the EXIT handler can't delete the moved file.
	trap - EXIT
	echo
	echo "install-hooks complete: $NEW_COUNT new registration(s)"
else
	rm -f "$WORKING"
	trap - EXIT
	echo
	echo "install-hooks complete: 0 new registration(s) (already up to date)"
fi
