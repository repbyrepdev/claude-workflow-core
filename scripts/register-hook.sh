#!/bin/bash
set -euo pipefail
# v0.9.5 (#68 + #69) — register/unregister hooks in ~/.claude/settings.json.
#
# Idempotently writes hook entries into the user-scope settings.json so
# the plugin's hooks/X.sh files actually fire. The plugin can ship a
# hook (and consumers can pull it via `git clone $TAG`), but until that
# hook is referenced in settings.json it never runs. Today every plugin
# version bump that adds a new hook requires hand-editing — fragile,
# drift-prone, and the auto-mode classifier hard-blocks programmatic
# edits (see #72 for classifier-exemption strategy).
#
# Hook discovery (#69 — manifest baked into hooks themselves):
#   # event: <EventName>             — required (first 15 lines of the .sh)
#   # matcher: <pattern>             — optional (PreToolUse etc.)
#   # auto-register: true            — optional sentinel for --all-auto
#
# Usage:
#   register-hook.sh <hook-path>...        # register specific hooks
#   register-hook.sh --all-auto-register   # all hooks/*.sh with the sentinel
#   register-hook.sh --unregister <path>   # remove an entry (idempotent)
#   register-hook.sh --check               # parity: settings refs ↔ hook files
#   register-hook.sh --dry-run <args>      # print plan, no settings.json write
#   register-hook.sh --help
#
# Exit codes:
#   0 — registration/check succeeded (or --dry-run shows clean plan)
#   1 — --check found drift (orphan ref or unregistered hook)
#   2 — usage / precondition error
#   3 — settings.json malformed / jq failure / write failure
#
# Classifier note: writing to ~/.claude/settings.json is classifier-
# blocked when invoked by the agent today. Operators run this script
# directly. #72 lands the sanctioned wrapper path so the agent (or
# plugin install/upgrade) can also invoke it autonomously.

DRY_RUN=0
CHECK=0
UNREGISTER=""
ALL_AUTO=0
HOOK_PATHS=()

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--check)
		CHECK=1
		shift
		;;
	--all-auto-register)
		ALL_AUTO=1
		shift
		;;
	--unregister)
		if [ -z "${2:-}" ] || [[ ${2:-} == -* ]]; then
			echo "register-hook.sh: --unregister requires a hook path" >&2
			exit 2
		fi
		UNREGISTER=$2
		shift 2
		;;
	-h | --help)
		awk '
			NR == 1 { next }                              # shebang
			/^set / { next }                              # set -euo pipefail
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }
			in_header { exit }
		' "$0"
		exit 0
		;;
	-*)
		echo "register-hook.sh: unknown flag '$1'" >&2
		exit 2
		;;
	*)
		HOOK_PATHS+=("$1")
		shift
		;;
	esac
done

if ! command -v jq >/dev/null 2>&1; then
	echo "register-hook.sh: jq required but not installed" >&2
	exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "register-hook.sh: not in a git repo" >&2
	exit 2
}
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# --- Frontmatter parsing ---------------------------------------------

# Reads first 15 lines of $1 and prints `event=X matcher=Y` (matcher
# empty if absent). Returns 1 if event missing.
_parse_frontmatter() {
	local path=$1 event="" matcher=""
	if [ ! -f "$path" ]; then
		echo "register-hook.sh: hook file not found: $path" >&2
		return 1
	fi
	# event and matcher may appear in either order; for each key the
	# first occurrence wins (subsequent duplicates ignored). Strip CR
	# (windows endings) and trailing whitespace so silent-mismatch
	# bugs ('SessionStart\r' or 'SessionStart ') can't happen.
	while IFS= read -r line; do
		line=${line%$'\r'}
		case "$line" in
		'# event:'*)
			[ -z "$event" ] && event=$(printf '%s' "$line" | sed -E 's/^# event:[[:space:]]*//; s/[[:space:]]+$//')
			;;
		'# matcher:'*)
			[ -z "$matcher" ] && matcher=$(printf '%s' "$line" | sed -E 's/^# matcher:[[:space:]]*//; s/[[:space:]]+$//')
			;;
		esac
	done < <(head -15 "$path")
	if [ -z "$event" ]; then
		echo "register-hook.sh: $path has no '# event:' frontmatter line in first 15 lines" >&2
		return 1
	fi
	# Some hooks pack matcher into the event line (e.g. "PreToolUse Bash"
	# — see ship-cycle-director-gate.sh). Split on whitespace.
	if [ -z "$matcher" ] && [[ $event =~ [[:space:]] ]]; then
		matcher="${event#* }"
		event="${event%% *}"
	fi
	echo "event=$event"
	echo "matcher=$matcher"
}

_resolve_hook_command() {
	# Convert repo-relative path to absolute path the plugin cache
	# would use. Uses $PLUGIN_CACHE_DIR env if set (test mode); otherwise
	# falls back to $REPO_ROOT/$path (works during dev / when consumer
	# repo IS the plugin).
	local path=$1
	if [ -n "${PLUGIN_CACHE_DIR:-}" ]; then
		echo "$PLUGIN_CACHE_DIR/$path"
	else
		echo "$REPO_ROOT/$path"
	fi
}

# --- Settings.json manipulation ---------------------------------------

# Adds or replaces the matcher-scoped hook entry. Schema follows the
# Claude Code settings.json convention from ~/.claude/settings.json:
#   {"hooks": {"<event>": [{"matcher": "<pat>", "hooks": [{"type":"command", "command":"<abs-path>"}]}]}}
_register_one() {
	local settings_json=$1 event=$2 matcher=$3 command=$4
	# Build the new hook object
	local new_hook
	new_hook=$(jq -n --arg cmd "$command" '{type:"command", command:$cmd}')
	# Use jq to upsert: find existing matcher entry, append the hook
	# (de-duplicated by command); if no matcher entry exists, create one.
	printf '%s' "$settings_json" | jq \
		--arg ev "$event" --arg mt "$matcher" --argjson nh "$new_hook" '
		.hooks //= {} |
		.hooks[$ev] //= [] |
		# locate matcher entry by exact matcher string ("" === no matcher)
		(.hooks[$ev] | map(.matcher // "")) as $matchers |
		($matchers | index($mt)) as $idx |
		if $idx == null then
			# Omit "matcher" key when empty — keeps schema consistent
			# with hand-written settings entries that never carry
			# "matcher": "" on events like SessionStart.
			.hooks[$ev] += [(if $mt == "" then {hooks: [$nh]} else {matcher: $mt, hooks: [$nh]} end)]
		else
			.hooks[$ev][$idx].hooks |= (if any(.command == $nh.command) then . else . + [$nh] end)
		end
	'
}

_unregister_one() {
	local settings_json=$1 command=$2
	printf '%s' "$settings_json" | jq --arg cmd "$command" '
		if (.hooks // {}) == {} then
			.
		else
			.hooks |= with_entries(
				.value |= map(
					.hooks |= map(select(.command != $cmd))
				) | .value |= map(select(.hooks | length > 0))
			)
		end
	'
}

# --- Main flows -------------------------------------------------------

_load_settings() {
	if [ ! -f "$SETTINGS" ]; then
		# Create with empty hooks object — safer than failing for
		# fresh-machine first-run.
		echo '{"hooks": {}}'
	else
		if ! jq empty "$SETTINGS" 2>/dev/null; then
			echo "register-hook.sh: $SETTINGS is malformed JSON" >&2
			exit 3
		fi
		cat "$SETTINGS"
	fi
}

_write_settings() {
	local new_json=$1
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] would write $SETTINGS:" >&2
		printf '%s\n' "$new_json" | jq . >&2
		return 0
	fi
	# Atomic write (tmp + rename) — prevents partial settings.json on
	# crash/SIGKILL mid-write. mkdir -p the parent so fresh-machine
	# first-run actually works (the _load_settings synthesis claim).
	local parent
	parent=$(dirname "$SETTINGS")
	if ! mkdir -p "$parent"; then
		echo "register-hook.sh: failed to create $parent — check permissions" >&2
		exit 3
	fi
	local tmp
	tmp=$(mktemp "$parent/.settings.XXXXXX") || {
		echo "register-hook.sh: cannot create tmp file in $parent — permission denied?" >&2
		exit 3
	}
	# Clean up tmp on any failure path (success after mv leaves nothing to clean).
	trap 'rm -f "$tmp"' EXIT
	if ! printf '%s\n' "$new_json" | jq . >"$tmp"; then
		echo "register-hook.sh: jq failed to format settings — refusing to overwrite $SETTINGS" >&2
		exit 3
	fi
	# Post-write validation: refuse to clobber settings.json with invalid JSON.
	if ! jq empty "$tmp" 2>/dev/null; then
		echo "register-hook.sh: post-write validation failed — refusing to overwrite $SETTINGS" >&2
		exit 3
	fi
	if ! mv "$tmp" "$SETTINGS"; then
		echo "register-hook.sh: mv failed ($tmp → $SETTINGS) — possibly cross-filesystem" >&2
		exit 3
	fi
	trap - EXIT
}

# Discover all auto-register hooks if --all-auto-register.
# Restricted to first 15 lines per the frontmatter contract — _parse_frontmatter
# only trusts that window, so discovery must too (a later heredoc/comment
# containing `# auto-register: true` shouldn't make a hook auto-register).
# Use while-read array build (portable across bash 3.2 + bash 4+); mapfile is bash 4+.
if [ "$ALL_AUTO" = "1" ]; then
	while IFS= read -r h; do
		[ -z "$h" ] && continue
		rel=${h#"$REPO_ROOT/"}
		HOOK_PATHS+=("$rel")
	done < <(
		for f in "$REPO_ROOT"/hooks/*.sh; do
			[ -f "$f" ] || continue
			head -15 "$f" | grep -q '^# auto-register: true' && printf '%s\n' "$f"
		done
	)
fi

# --check mode: bidirectional drift between settings.json refs ↔ hook files
if [ "$CHECK" = "1" ]; then
	settings=$(_load_settings)
	settings_refs=$(printf '%s' "$settings" | jq -r '
		[.hooks // {} | to_entries[] |
		  .value[] | (.hooks // [])[] |
		  select(.command | test("/hooks/[^/]+\\.sh$"))
		  | .command | capture("/hooks/(?<f>[^/]+\\.sh)$").f
		] | unique | .[]
	')
	# Hooks on disk with frontmatter — separately track sentinel hooks
	# (those declaring `# auto-register: true`) so the reverse-direction
	# check only flags hooks that SHOULD be registered.
	# Frontmatter-window-restricted discovery (matches _parse_frontmatter's
	# 15-line contract): a later heredoc/comment doesn't accidentally
	# pull a hook into either list.
	hook_files=""
	sentinel_files=""
	if [ -d "$REPO_ROOT/hooks" ]; then
		for f in "$REPO_ROOT"/hooks/*.sh; do
			[ -f "$f" ] || continue
			bn=$(basename "$f")
			window=$(head -15 "$f")
			if printf '%s\n' "$window" | grep -qE '^# event:'; then
				hook_files=$(printf '%s\n%s' "${hook_files}" "$bn")
			fi
			if printf '%s\n' "$window" | grep -qE '^# auto-register: true'; then
				sentinel_files=$(printf '%s\n%s' "${sentinel_files}" "$bn")
			fi
		done
		hook_files=$(printf '%s' "$hook_files" | sed '/^$/d' | sort -u || true)
		sentinel_files=$(printf '%s' "$sentinel_files" | sed '/^$/d' | sort -u || true)
	fi
	drift=0
	# Direction 1: orphan refs (settings ref → hook file missing)
	while IFS= read -r r; do
		[ -z "$r" ] && continue
		if [ -z "$hook_files" ] || ! printf '%s\n' "$hook_files" | grep -qFx "$r"; then
			echo "  ✗ settings.json refs hooks/$r but file does not exist" >&2
			drift=1
		fi
	done <<<"$settings_refs"
	# Direction 2: unregistered sentinel hooks (file with auto-register → not in settings)
	while IFS= read -r h; do
		[ -z "$h" ] && continue
		if [ -z "$settings_refs" ] || ! printf '%s\n' "$settings_refs" | grep -qFx "$h"; then
			echo "  ✗ hooks/$h has '# auto-register: true' but is not in settings.json" >&2
			drift=1
		fi
	done <<<"$sentinel_files"
	echo "register-hook.sh: --check complete (drift=$drift)"
	exit "$drift"
fi

# --unregister mode: drop a specific hook from settings
if [ -n "$UNREGISTER" ]; then
	cmd_path=$(_resolve_hook_command "$UNREGISTER")
	settings=$(_load_settings)
	new=$(_unregister_one "$settings" "$cmd_path")
	if [ "$settings" = "$new" ]; then
		echo "  ✓ $UNREGISTER not referenced in $SETTINGS (no-op)"
	else
		_write_settings "$new"
		echo "  ✓ unregistered $UNREGISTER from $SETTINGS"
	fi
	exit 0
fi

# Register mode (default): each HOOK_PATHS entry gets registered
if [ "${#HOOK_PATHS[@]}" -eq 0 ]; then
	echo "register-hook.sh: no hook paths supplied (try --all-auto-register or pass hooks/X.sh)" >&2
	exit 2
fi

settings=$(_load_settings)
for hook in "${HOOK_PATHS[@]}"; do
	# Normalize to repo-relative if user passed absolute
	rel=${hook#"$REPO_ROOT/"}
	abs="$REPO_ROOT/$rel"
	if [ ! -f "$abs" ]; then
		echo "register-hook.sh: hook file not found: $hook" >&2
		exit 2
	fi
	# Parse frontmatter
	fm=$(_parse_frontmatter "$abs") || exit 2
	event=$(printf '%s' "$fm" | grep '^event=' | sed 's/^event=//')
	matcher=$(printf '%s' "$fm" | grep '^matcher=' | sed 's/^matcher=//')
	command=$(_resolve_hook_command "$rel")
	echo "  registering $rel → event=$event matcher=${matcher:-<none>} command=$command"
	settings=$(_register_one "$settings" "$event" "$matcher" "$command")
done

_write_settings "$settings"
if [ "$DRY_RUN" != "1" ]; then
	echo "register-hook.sh: ${#HOOK_PATHS[@]} hook(s) registered in $SETTINGS"
fi
exit 0
