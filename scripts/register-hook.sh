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
#   register-hook.sh --check-permissions   # (#72) classifier-allowlist readiness
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
# blocked by default. To authorize autonomous invocation by the agent
# or plugin install/upgrade flows, the operator runs the sibling
# `install-register-hook-permissions.sh` once at machine bootstrap and
# pastes its output into permissions.allow. Then this script runs
# without classifier prompts. Use `--check-permissions` to verify the
# allowlist is in place before relying on autonomous invocation.

DRY_RUN=0
CHECK=0
CHECK_PERMS=0
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
	--check-permissions)
		# Delegates to install-register-hook-permissions.sh (sibling
		# script). #72 sanctioned wrapper path — operators run this
		# once at machine bootstrap to verify ~/.claude/settings.json
		# permissions.allow contains the classifier-exemption patterns
		# that authorize autonomous register-hook.sh invocation.
		CHECK_PERMS=1
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

# --check-permissions short-circuits before any of register-hook.sh's
# own preconditions (jq, git-repo, settings.json). Operators at machine
# bootstrap legitimately run this from $HOME (no git repo) — the
# delegated installer has its own jq + settings checks with clearer
# diagnostics, so we don't gate on ours first.
if [ "$CHECK_PERMS" = "1" ]; then
	# --check-permissions is an exclusive mode. If callers combine it
	# with action flags or hook paths, those args would be silently
	# discarded by the exec — making a bad invocation look successful
	# even though nothing was registered/unregistered.
	if [ "$DRY_RUN" = "1" ] || [ "$CHECK" = "1" ] || [ "$ALL_AUTO" = "1" ] ||
		[ -n "$UNREGISTER" ] || [ "${#HOOK_PATHS[@]}" -gt 0 ]; then
		echo "register-hook.sh: --check-permissions is exclusive — cannot combine with other flags or paths" >&2
		exit 2
	fi
	installer="$(dirname "$0")/install-register-hook-permissions.sh"
	if [ ! -x "$installer" ]; then
		echo "register-hook.sh: sibling installer not found or not executable: $installer" >&2
		echo "  Reinstall the plugin or check file mode (chmod +x)." >&2
		exit 2
	fi
	exec "$installer" --check
fi

if ! command -v jq >/dev/null 2>&1; then
	echo "register-hook.sh: jq required but not installed" >&2
	exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "register-hook.sh: not in a git repo" >&2
	exit 2
}
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

# (#2536) Version-agnostic launcher resolution. Best-effort source: if the lib
# is unavailable, _resolve_hook_command below falls back to its prior behavior —
# version-pinned but still functional. A missing lib must never stop a hook from
# registering at all.
# Resolve relative to THIS script's real location (BASH_SOURCE), not $0 — a
# `bash register-hook.sh` invocation or a symlink makes $0 unreliable.
_RH_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../_lib/plugin-cache-resolve.sh"
if [ -r "$_RH_LIB" ]; then
	# shellcheck source=../_lib/plugin-cache-resolve.sh
	. "$_RH_LIB" ||
		echo "register-hook.sh: WARN: plugin-cache-resolve.sh failed to source — new registrations will be version-pinned" >&2
fi

# The program-token/basename jq SSOT (CR-in-CI #2540). --check's settings_refs
# and --unregister both key on a hook's basename regardless of whether the ref is
# a legacy `…/hooks/foo.sh` path or a version-agnostic `<launcher-dir>/foo.sh`
# one; both reuse this so the rule can't drift. Prefer the lib's copy; fall back
# to an inline duplicate only when the lib failed to source.
_progtoken_jq() {
	if declare -f pcr_progtoken_jq >/dev/null 2>&1; then
		pcr_progtoken_jq
	else
		cat <<'JQ'
  def progpath: split(" ")[0];
  def _tail: (split("/hooks/") | (if length > 1 then (.[1:] | join("/hooks/")) else .[0] end));
  def progtoken: _tail | split(" ")[0];
  def progargs:  _tail | (split(" ")[1:] | join(" "));
  def progbasename: progtoken | (split("/") | .[-1]);
JQ
	fi
}

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
	done <"$path"
	if [ -z "$event" ]; then
		echo "register-hook.sh: $path has no '# event:' frontmatter line" >&2
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
	# The command string baked into settings.json for this hook.
	#
	# (#2536) PREFER the version-agnostic launcher. The two fallbacks below both
	# bake an ABSOLUTE, version-pinned path, which is what left 51 registrations
	# pointing at a pruned cache version on the operator's machine — 404'ing
	# after GC, and silently running a stale build before it. A launcher
	# re-resolves the newest cache version containing this hook at RUN TIME, so
	# a cache bump plus GC has nothing to dangle.
	#
	# Falls through to the prior behavior when no launcher exists (fresh install
	# before install-hook-launchers.sh has run, or the lib failed to source):
	# version-pinned is worse, but it is better than refusing to register.
	local path=$1
	# Separate `local`: a same-statement `base=${path##*/}` reads the OUTER
	# `path`, not the one being assigned beside it (SC2318).
	local base=${path##*/}
	local launcher
	if declare -f pcr_launcher_path >/dev/null 2>&1; then
		launcher=$(pcr_launcher_path "$base")
		if [ -x "$launcher" ]; then
			printf '%s' "$launcher"
			return 0
		fi
	fi
	# Uses $PLUGIN_CACHE_DIR env if set (test mode); otherwise falls back to
	# $REPO_ROOT/$path (works during dev / when the consumer repo IS the plugin).
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
	# Match by hook BASENAME (program token), NOT a resolved command path.
	# _resolve_hook_command returns a version-pinned FALLBACK once the launcher
	# has been GC'd, so a path-equality match would silently no-op and leave the
	# launcher registration active (CR-in-CI #2540). Reuse --check's rule: take
	# the program token (a registration may carry args), then its basename, and
	# drop every entry whose basename equals the target — legacy `/hooks/…` path
	# OR version-agnostic launcher alike. `and` short-circuits so `_basename` is
	# never applied to a non-string command.
	# SCOPE the basename match to paths we actually own (CR-in-CI #2540 phase2).
	# Basename alone over-matches: an unrelated registration that merely shares a
	# filename — e.g. an operator's own ~/my-hooks/review-log.sh — would be
	# deleted from the global settings.json by an unregister aimed at ours. That
	# is a destructive edit to a file we do not own, so the match additionally
	# requires the program path to be under the launcher dir OR contain a
	# `/hooks/` segment (the legacy pinned shape). Both are ours; anything else
	# is left alone.
	local settings_json=$1 base=$2 ldir=""
	if declare -f pcr_launcher_dir >/dev/null 2>&1; then ldir=$(pcr_launcher_dir); fi
	printf '%s' "$settings_json" | jq --arg base "$base" --arg ld "$ldir" "$(_progtoken_jq)"'
		if (.hooks // {}) == {} then
			.
		else
			.hooks |= with_entries(
				.value |= map(
					# Shape-guard the nested iteration: an entry whose `hooks` is
					# missing/null or not an array must pass through UNCHANGED —
					# `null | map(...)` is a jq error that aborts the WHOLE rewrite
					# (and unregister then silently no-ops). Mirrors the defensive
					# object/has("hooks") check the migrate path uses (CR-in-CI #2540).
					if (type == "object" and (.hooks | type) == "array")
					then .hooks |= map(
						if (.command | type) == "string"
						   and ((.command | progbasename) == $base)
						   # …AND the path is one of ours: under the launcher dir,
						   # or a legacy `…/hooks/<name>.sh` pinned path.
						   and ((.command | progpath) as $p
						        | (($ld != "") and ($p | startswith($ld + "/")))
						          or ($p | test("/hooks/[^/]+$")))
						then empty else . end
					)
					else . end
				)
				# Drop only entries we actually emptied; anything without a hooks
				# ARRAY is left alone rather than being pruned as "length 0".
				| .value |= map(select((.hooks | type) != "array" or (.hooks | length > 0)))
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
		echo "  If you are invoking this script via the agent and see classifier blocks, run:" >&2
		echo "    $(dirname "$0")/install-register-hook-permissions.sh" >&2
		echo "  to print the one-time allowlist entries the operator adds to settings.json." >&2
		exit 3
	fi
	trap - EXIT
}

# Discover all auto-register hooks if --all-auto-register.
# Full-file scan (SSOT semantic shared with discover-orphan-hooks.sh +
# migrate-settings.sh as of v0.24.0 #150). Hooks with long license/
# provenance headers can push the directive past any line cap.
# Use while-read array build (portable across bash 3.2 + bash 4+); mapfile is bash 4+.
if [ "$ALL_AUTO" = "1" ]; then
	while IFS= read -r h; do
		[ -z "$h" ] && continue
		rel=${h#"$REPO_ROOT/"}
		HOOK_PATHS+=("$rel")
	done < <(
		for f in "$REPO_ROOT"/hooks/*.sh; do
			[ -f "$f" ] || continue
			# Full-file scan (SSOT semantic shared with discover-orphan-hooks.sh
			# + migrate-settings.sh). Hooks with long license/provenance
			# headers can push the directive past any line cap.
			grep -q '^# auto-register: true' "$f" && printf '%s\n' "$f"
		done
	)
fi

# --check mode: bidirectional drift between settings.json refs ↔ hook files
if [ "$CHECK" = "1" ]; then
	settings=$(_load_settings)
	# (#2536) A registration is now EITHER a legacy `…/hooks/<name>.sh` path or a
	# version-agnostic launcher `<launcher-dir>/<name>.sh`. The old pattern
	# required a literal `/hooks/` segment immediately before the filename, which
	# a launcher path does not have — so after the launcher migration --check saw
	# ZERO registrations and reported every auto-register hook as unregistered.
	# Accept both shapes and key on the basename, which is identical either way.
	_check_ld=""
	if declare -f pcr_launcher_dir >/dev/null 2>&1; then _check_ld=$(pcr_launcher_dir); fi
	settings_refs=$(printf '%s' "$settings" | jq -r --arg ld "$_check_ld" "$(_progtoken_jq)"'
		[.hooks // {} | to_entries[] |
		  .value[] | (.hooks // [])[] | .command |
		  select(type == "string") |
		  # Keep only hook refs — a legacy `…/hooks/foo.sh` path OR a
		  # version-agnostic `<launcher-dir>/foo.sh` one — testing the PROGRAM
		  # token (a registration may carry arguments like "… --strict", and the
		  # trailing-$ anchor would otherwise never match, so --check saw zero
		  # registrations for every arg-bearing hook and cried drift).
		  select(progpath | (test("/hooks/[^/]+\\.sh$") or (($ld != "") and startswith($ld + "/"))))
		  # Basename via the shared SSOT (progbasename) — identical for both the
		  # /hooks/ and launcher-dir shapes, and the SAME rule --unregister uses.
		  | progbasename
		] | unique | .[]
	')
	# Hooks on disk with frontmatter — separately track sentinel hooks
	# (those declaring `# auto-register: true`) so the reverse-direction
	# check only flags hooks that SHOULD be registered.
	# Full-file scan: SSOT semantic shared with discover-orphan-hooks.sh
	# + migrate-settings.sh (v0.24.0 #150). Prior head -15 cap could miss
	# directives placed after long license/provenance headers.
	hook_files=""
	sentinel_files=""
	if [ -d "$REPO_ROOT/hooks" ]; then
		for f in "$REPO_ROOT"/hooks/*.sh; do
			[ -f "$f" ] || continue
			bn=$(basename "$f")
			if grep -qE '^# event:' "$f"; then
				hook_files=$(printf '%s\n%s' "${hook_files}" "$bn")
			fi
			if grep -qE '^# auto-register: true' "$f"; then
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
	# Pass the BASENAME, not a resolved path — _unregister_one matches on it, so
	# a GC'd launcher no longer makes unregister a silent no-op (CR-in-CI #2540).
	unreg_base=${UNREGISTER##*/}
	settings=$(_load_settings)
	new=$(_unregister_one "$settings" "$unreg_base")
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
