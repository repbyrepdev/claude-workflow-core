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
#   # event: <EventName>             — required (first 10 lines of the .sh)
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
	# Match `# event: <name>` and `# matcher: <pattern>`. Order
	# doesn't matter; only first occurrence wins.
	while IFS= read -r line; do
		case "$line" in
		'# event:'*)
			[ -z "$event" ] && event=$(printf '%s' "$line" | sed -E 's/^# event:[[:space:]]*//')
			;;
		'# matcher:'*)
			[ -z "$matcher" ] && matcher=$(printf '%s' "$line" | sed -E 's/^# matcher:[[:space:]]*//')
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
			.hooks[$ev] += [({matcher: $mt} + {hooks: [$nh]})]
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
	# Atomic write: tmp + mv in same dir
	local tmp
	tmp=$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX")
	printf '%s\n' "$new_json" | jq . >"$tmp"
	mv "$tmp" "$SETTINGS"
}

# Discover all auto-register hooks if --all-auto-register.
# Use while-read array build (portable across bash 3.2 macOS + bash 4+ Linux);
# `mapfile` is bash 4+.
if [ "$ALL_AUTO" = "1" ]; then
	while IFS= read -r h; do
		[ -z "$h" ] && continue
		rel=${h#"$REPO_ROOT/"}
		HOOK_PATHS+=("$rel")
	done < <(grep -l '^# auto-register: true' "$REPO_ROOT/hooks"/*.sh 2>/dev/null || true)
fi

# --check mode: report drift between settings.json refs and on-disk hooks
if [ "$CHECK" = "1" ]; then
	settings=$(_load_settings)
	# Collect settings refs to hooks/ paths
	settings_refs=$(printf '%s' "$settings" | jq -r '
		[.hooks // {} | to_entries[] |
		  .value[] | (.hooks // [])[] |
		  select(.command | test("/hooks/[^/]+\\.sh$"))
		  | .command | capture("/hooks/(?<f>[^/]+\\.sh)$").f
		] | unique | .[]
	' 2>/dev/null || true)
	# Collect hooks/ files that declare event frontmatter
	hook_files=$(grep -lE '^# event:' "$REPO_ROOT/hooks"/*.sh 2>/dev/null | awk -F/ '{print $NF}' | sort -u || true)
	drift=0
	for r in $settings_refs; do
		if ! grep -qFx "$r" <<<"$hook_files"; then
			echo "  ✗ settings.json refs hooks/$r but file does not exist" >&2
			drift=1
		fi
	done
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
