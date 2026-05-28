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

# Initialize trap state BEFORE mktemp (unbound-scalar safety) and
# include stub_path cleanup so a mid-write failure on --register-missing
# doesn't leak a half-written YAML file (r1 silent-failure-hunter HIGH).
jq_err=""
stub_path=""
stub_complete=0
# shellcheck disable=SC2329,SC2317
_cleanup() {
	# Use if/then/fi not `[ A ] && B` — under set -e the test returning
	# rc=1 propagates as the trap's final rc (r1 silent-failure-hunter
	# LOW: exit 2 documented but trap would override to 1).
	if [ -n "$jq_err" ]; then
		rm -f "$jq_err"
	fi
	# Only remove stub if it was created AND the write didn't complete
	# successfully — partial writes are useless to the operator.
	if [ -n "$stub_path" ] && [ -f "$stub_path" ] && [ "$stub_complete" != "1" ]; then
		rm -f "$stub_path"
	fi
}
trap _cleanup EXIT INT TERM HUP

jq_err=$(mktemp -t orphan-hooks-jq.XXXXXX) || {
	echo "discover-orphan-hooks: mktemp failed" >&2
	exit 2
}

# r1 fix (code-reviewer CRITICAL + silent-failure-hunter CRITICAL):
# Settings.json's authoritative ref list lives at `.hooks.*.hooks[].command`.
# Narrowed from the prior `.. | objects | select(.command)` recursive
# descent which could accidentally match non-hook objects (mcp/env/
# custom plugin sections with stray .command fields). Type-guard
# `.command` to string so future spec changes (array-form command vector)
# surface visibly instead of silently misclassifying.
# Capture jq + grep separately so a zero-match grep (legitimate when
# settings.json has no .sh hooks yet — fresh install) doesn't trigger
# the misleading "jq failed" error.
if ! raw_commands=$(jq -r '.hooks // {} | to_entries[]? | .value[]? | .hooks[]? | .command | select(type == "string")' "$SETTINGS_JSON" 2>"$jq_err"); then
	echo "discover-orphan-hooks: jq failed parsing $SETTINGS_JSON:" >&2
	cat "$jq_err" >&2
	exit 2
fi
# grep -oE no-match exits 1 under set -e — capture with || true so an
# empty registered set is operationally valid (zero registered hooks).
registered_basenames=$(printf '%s\n' "$raw_commands" | grep -oE '[^/]+\.sh$' | sort -u || true)

orphans_json='[]'
orphans_count=0
auto_register_count=0

shopt -s nullglob
for f in "$HOOKS_DIR"/*.sh; do
	base=$(basename "$f")
	# Helper-name convention: never auto-register.
	[[ $base == _* ]] && continue

	# r1 silent-failure-hunter HIGH: drop the head -15 cap so directives
	# past line 15 (long license headers, multi-line provenance blocks)
	# aren't silently misclassified. Hooks are small; scanning the full
	# file is cheap. First-match awk still wins on duplicates.
	# r1 code-reviewer HIGH: match the same semantic as scripts/register-
	# hook.sh: anchored `^# auto-register: true` (whitespace-tolerant via
	# rtrim) so a trailing space or accidental copy-paste of the same
	# directive doesn't diverge the two scripts' opt-in decision.
	auto_register=$(awk '
		/^# auto-register: / {
			sub(/^# auto-register: /, "")
			sub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$f")
	[ "$auto_register" = "true" ] || continue

	auto_register_count=$((auto_register_count + 1))

	# Parse declared event + matcher for the registration template +
	# diagnostic. Scan full file (consistent with auto-register above).
	event=$(awk '/^# event: / { sub(/^# event: /, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$f")
	matcher=$(awk '/^# matcher: / { sub(/^# matcher: /, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$f")

	# grep -Fxq on empty registered_basenames returns 1 under set -e;
	# guard via `|| true` since "zero registered hooks = every auto-
	# register hook is orphan" is the correct semantic.
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
	# r1 silent-failure-hunter MEDIUM: tests need to redirect stub
	# output away from the real repo (otherwise the test leaves artifacts
	# in .claude/discovery/ on every run). Operators leave this env unset
	# to get the canonical path.
	OUT_DIR="${DISCOVERY_OUT_DIR:-$REPO_ROOT/.claude/discovery}"
	# Write a parseable YAML stub for operator review. Atomic write
	# pattern: build into a tmp file, mv only when complete. If the
	# build fails the trap removes the partial stub (stub_complete=0).
	mkdir -p "$OUT_DIR" || {
		echo "discover-orphan-hooks: failed to create $OUT_DIR" >&2
		exit 2
	}
	# r1 silent-failure-hunter HIGH: mktemp gives us per-process
	# uniqueness so concurrent --register-missing runs don't collide.
	stub_path=$(mktemp -t "orphans-$(date -u +%Y%m%dT%H%M%S)-XXXXXX") || {
		echo "discover-orphan-hooks: mktemp for stub failed" >&2
		exit 2
	}
	{
		printf '# Auto-generated by discover-orphan-hooks.sh --register-missing\n'
		printf '# Review each entry; to register them, run:\n'
		printf '#   scripts/register-hook.sh --all-auto-register\n'
		printf '# (or pass specific files: scripts/register-hook.sh hooks/X.sh ...)\n'
		printf 'orphans:\n'
		# r1 HIGH: @json filter for proper YAML escape — naked
		# interpolation would corrupt the stub on matchers / paths
		# containing `"` or `\` (YAML 1.2 is a JSON superset so
		# JSON-encoded strings parse cleanly).
		if ! jq -r '.[] | "  - name: \(.name|@json)\n    event: \(.event|@json)\n    matcher: \(.matcher|@json)\n    path: \(.path|@json)"' <<<"$orphans_json" 2>"$jq_err"; then
			echo "discover-orphan-hooks: jq failed rendering stub:" >&2
			cat "$jq_err" >&2
			exit 2
		fi
	} >"$stub_path"
	# Promote to the canonical name under .claude/discovery/. Atomic mv
	# replaces any prior same-second stub silently — that's intended:
	# two operators within the same second running --register-missing
	# get the same orphan set, so overwriting is fine here (mktemp
	# already prevented mid-write collision).
	final_path="$OUT_DIR/$(basename "$stub_path").yml"
	if ! mv "$stub_path" "$final_path"; then
		echo "discover-orphan-hooks: failed to promote stub to $final_path" >&2
		exit 2
	fi
	stub_path=$final_path
	stub_complete=1
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
		# r1 silent-failure-hunter MEDIUM: capture jq output BEFORE the
		# while-read so a jq parse error surfaces as a clear diagnostic
		# rather than printing a blank table with no rows.
		if ! tsv=$(jq -r '.[] | [.name, .event, .matcher] | @tsv' <<<"$orphans_json" 2>"$jq_err"); then
			echo "discover-orphan-hooks: jq failed rendering text table:" >&2
			cat "$jq_err" >&2
			exit 2
		fi
		while IFS=$'\t' read -r name event matcher; do
			printf '%-40s %-25s %s\n' "$name" "$event" "${matcher:-—}"
		done <<<"$tsv"
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
