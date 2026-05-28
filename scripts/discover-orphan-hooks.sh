#!/bin/bash
set -euo pipefail
# event: none
# auto-register: false
# v0.23.0 (#149) — discover hooks with `# auto-register: true` directive
# that are NOT yet registered in ~/.claude/settings.json.
#
# Complements scripts/register-hook.sh --check (which surfaces orphans
# inline as part of a broader parity check) by providing:
#   * Machine-readable --json output for CI integration
#   * --strict mode (exit 1 on any orphan, for pre-commit / pre-merge)
#   * --register-missing template stub generation for operator review
#
# The discovery signal is `# auto-register: true` in the .sh file header
# — the same sentinel scripts/register-hook.sh uses. Files without this
# directive (CLI tools, helpers, custom-event-firing scripts like
# post-merge-release-fire.sh which uses `git-post-merge`) are
# explicitly out of scope: this script does NOT decide what should be
# registered; it surfaces what the AUTHOR opted in.
#
# Usage:
#   scripts/discover-orphan-hooks.sh                       # text report
#   scripts/discover-orphan-hooks.sh --json                # machine-readable
#   scripts/discover-orphan-hooks.sh --strict              # exit 1 if any orphan
#   scripts/discover-orphan-hooks.sh --register-missing    # write stub for review
#   scripts/discover-orphan-hooks.sh --hooks-dir <path>    # explicit dir
#   scripts/discover-orphan-hooks.sh --settings <path>     # explicit settings.json
#   scripts/discover-orphan-hooks.sh --help
#
# Exit codes:
#   0 — no orphans (or report-only mode regardless of orphan count)
#   1 — orphans found AND --strict
#   2 — precondition error (missing settings.json, hooks dir, jq, etc.)

FORMAT=text
STRICT=0
REGISTER_MISSING=0
HOOKS_DIR=""
SETTINGS_JSON=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT=json
		shift
		;;
	--strict)
		STRICT=1
		shift
		;;
	--register-missing)
		REGISTER_MISSING=1
		shift
		;;
	--hooks-dir)
		[ "$#" -ge 2 ] || {
			echo "discover-orphan-hooks: --hooks-dir requires a path" >&2
			exit 2
		}
		HOOKS_DIR=$2
		shift 2
		;;
	--settings)
		[ "$#" -ge 2 ] || {
			echo "discover-orphan-hooks: --settings requires a path" >&2
			exit 2
		}
		SETTINGS_JSON=$2
		shift 2
		;;
	-h | --help)
		awk '
			NR == 1 { next }
			/^set / { next }
			/^# (event|auto-register):/ { next }
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }
			in_header { exit }
		' "$0"
		exit 0
		;;
	*)
		echo "discover-orphan-hooks: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [ -z "$HOOKS_DIR" ]; then
	if [ -d "$REPO_ROOT/hooks" ]; then
		HOOKS_DIR="$REPO_ROOT/hooks"
	elif [ -d "$REPO_ROOT/.claude/hooks" ]; then
		HOOKS_DIR="$REPO_ROOT/.claude/hooks"
	else
		echo "discover-orphan-hooks: no hooks/ or .claude/hooks/ found under $REPO_ROOT" >&2
		exit 2
	fi
fi
[ -d "$HOOKS_DIR" ] || {
	echo "discover-orphan-hooks: $HOOKS_DIR not a directory" >&2
	exit 2
}

if [ -z "$SETTINGS_JSON" ]; then
	SETTINGS_JSON="${HOME}/.claude/settings.json"
fi
[ -f "$SETTINGS_JSON" ] || {
	echo "discover-orphan-hooks: $SETTINGS_JSON not found" >&2
	exit 2
}

command -v jq >/dev/null 2>&1 || {
	echo "discover-orphan-hooks: jq required" >&2
	exit 2
}

# Initialize trap state BEFORE mktemp.
jq_err=""
stub_path=""
# shellcheck disable=SC2329,SC2317
_cleanup() {
	[ -n "$jq_err" ] && rm -f "$jq_err"
}
trap _cleanup EXIT INT TERM HUP

jq_err=$(mktemp -t orphan-hooks-jq.XXXXXX) || {
	echo "discover-orphan-hooks: mktemp failed" >&2
	exit 2
}

# Settings.json's `.hooks.*.hooks[].command` is the authoritative ref
# list. Extract every command value + normalize to basename (paths
# vary across machines + plugin-cache versions).
if ! registered_basenames=$(jq -r '.hooks // {} | .. | objects | select(.command) | .command' "$SETTINGS_JSON" 2>"$jq_err" |
	grep -oE '[^/]+\.sh$' | sort -u); then
	echo "discover-orphan-hooks: jq failed parsing $SETTINGS_JSON:" >&2
	cat "$jq_err" >&2
	exit 2
fi

orphans_json='[]'
orphans_count=0
auto_register_count=0

shopt -s nullglob 2>/dev/null || true
for f in "$HOOKS_DIR"/*.sh; do
	base=$(basename "$f")
	# Helper-name convention: never auto-register.
	[[ $base == _* ]] && continue

	# Read first 15 lines for directives (matches register-hook.sh).
	header=$(head -15 "$f")
	# Match `# auto-register: true` exactly — skip false / missing /
	# anything else. The first match wins (refresh-from-source.sh r3
	# pattern: stop at first hit).
	auto_register=$(printf '%s\n' "$header" | awk '/^# auto-register: / { sub(/^# auto-register: /, ""); print; exit }')
	[ "$auto_register" = "true" ] || continue

	auto_register_count=$((auto_register_count + 1))

	# Parse declared event for the registration template + diagnostic.
	event=$(printf '%s\n' "$header" | awk '/^# event: / { sub(/^# event: /, ""); print; exit }')
	matcher=$(printf '%s\n' "$header" | awk '/^# matcher: / { sub(/^# matcher: /, ""); print; exit }')

	if ! grep -Fxq "$base" <<<"$registered_basenames"; then
		orphans_count=$((orphans_count + 1))
		if ! orphans_json=$(jq --arg name "$base" --arg event "${event:-<missing>}" \
			--arg matcher "${matcher:-}" --arg path "$f" \
			'. + [{name:$name, event:$event, matcher:$matcher, path:$path}]' \
			<<<"$orphans_json" 2>"$jq_err"); then
			echo "discover-orphan-hooks: jq failed building orphan record for $base:" >&2
			cat "$jq_err" >&2
			exit 2
		fi
	fi
done

if [ "$REGISTER_MISSING" = "1" ] && [ "$orphans_count" -gt 0 ]; then
	# Write a parseable YAML stub for operator review. Operator copies
	# accepted entries into ~/.claude/settings.json OR runs:
	#   scripts/register-hook.sh --all-auto-register
	# (the existing canonical path) to register them.
	mkdir -p "$REPO_ROOT/.claude/discovery"
	stub_path="$REPO_ROOT/.claude/discovery/orphans-$(date -u +%Y%m%dT%H%M%S).yml"
	{
		printf '# Auto-generated by discover-orphan-hooks.sh --register-missing\n'
		printf '# Review each entry; to register them, run:\n'
		printf '#   scripts/register-hook.sh --all-auto-register\n'
		printf '# (or pass specific files: scripts/register-hook.sh hooks/X.sh ...)\n'
		printf 'orphans:\n'
		jq -r '.[] | "  - name: \"\(.name)\"\n    event: \"\(.event)\"\n    matcher: \"\(.matcher)\"\n    path: \"\(.path)\""' <<<"$orphans_json"
	} >"$stub_path"
fi

case "$FORMAT" in
json)
	printf '%s\n' "$orphans_json"
	;;
text)
	echo "=== Orphan auto-register hooks ($orphans_count) ==="
	echo "  hooks dir:           $HOOKS_DIR"
	echo "  settings.json:       $SETTINGS_JSON"
	echo "  total auto-register: $auto_register_count"
	echo
	if [ "$orphans_count" -eq 0 ]; then
		echo "(clean — every '# auto-register: true' hook is registered)"
	else
		printf '%-40s %-25s %s\n' "hook" "event" "matcher"
		printf '%-40s %-25s %s\n' "----" "-----" "-------"
		jq -r '.[] | [.name, .event, .matcher] | @tsv' <<<"$orphans_json" |
			while IFS=$'\t' read -r name event matcher; do
				printf '%-40s %-25s %s\n' "$name" "$event" "${matcher:-—}"
			done
		echo
		if [ -n "$stub_path" ]; then
			echo "Stub written: $stub_path"
		fi
		echo "Fix: scripts/register-hook.sh --all-auto-register"
		echo "  (idempotent; writes only the missing entries to ~/.claude/settings.json)"
	fi
	;;
esac

if [ "$STRICT" = "1" ] && [ "$orphans_count" -gt 0 ]; then
	exit 1
fi
exit 0
