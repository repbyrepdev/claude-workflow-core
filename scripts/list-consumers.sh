#!/bin/bash
set -euo pipefail
# event: none
# auto-register: false
# v0.18.2 (#141) — operator-facing inventory of plugin consumers.
#
# Reads .github/consumers.yml and emits a table of every registered
# consumer + their pin. Use cases:
#   * Session-start sanity check ("who's still behind v0.18?")
#   * Pre-cascade preview before scripts/refresh-from-source.sh --all
#   * Documentation generation
#
# Usage:
#   scripts/list-consumers.sh                # text table (default)
#   scripts/list-consumers.sh --json         # machine-readable
#   scripts/list-consumers.sh --behind <ver> # only consumers older than <ver>
#   scripts/list-consumers.sh --help
#
# Exit codes:
#   0 — listed (or --behind found no laggards = clean; the absence-of-output
#       does NOT mean "all consumers current" — pipe --json to `jq length`
#       for a programmatic count if you need that signal)
#   2 — precondition error (consumers.yml missing, yq/jq missing, schema
#       invalid, yq parse failure, --behind arg not X.Y.Z, unknown arg)

FORMAT=text
BEHIND_VERSION=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT=json
		shift
		;;
	--behind)
		[ "$#" -ge 2 ] || {
			echo "list-consumers: --behind requires a version" >&2
			exit 2
		}
		BEHIND_VERSION=$2
		# Validate same X.Y.Z shape the schema gate enforces on stored
		# pinned_version — otherwise typos like `--behind v0.18.2` or
		# `--behind latest` get treated as a version that sorts after
		# every numeric pin (digits < letters under sort -V), so every
		# consumer reports as "behind" — silent miscompare, not error.
		# Code-reviewer Phase 1 finding + type-design-analyzer dup.
		if ! [[ $BEHIND_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "list-consumers: --behind requires X.Y.Z semver (got: '$BEHIND_VERSION')" >&2
			exit 2
		fi
		shift 2
		;;
	-h | --help)
		# Emit the leading comment header as usage text. Skips shebang
		# + the `set -euo pipefail` line + the loader-frontmatter
		# directives (event:, auto-register:) which are framework
		# metadata, not user-facing help. Code-reviewer + type-design-
		# analyzer dup finding: prior awk leaked the directives.
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
		echo "list-consumers: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/.github/consumers.yml"

if [ ! -f "$REGISTRY" ]; then
	echo "list-consumers: $REGISTRY missing — check cwd or restore from git history" >&2
	exit 2
fi

for cmd in yq jq; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "list-consumers: $cmd required" >&2
		exit 2
	}
done

# Fail-loud yq parse pattern — mirrors check-ssot-drift.sh:56-62 and the
# pre-commit-hooks/consumers-schema-check.sh helper. The prior
# `2>/dev/null` swallowed yq errors as "schema_version=$schema_version
# not supported" — a corrupt YAML file blamed operator content instead
# of surfacing parse failure. Capture stderr explicitly.
yq_err=$(mktemp -t list-cons-yq.XXXXXX) || {
	echo "list-consumers: mktemp failed — cannot stage yq error buffer" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

# Validate schema_version. The validator pre-commit hook owns the full
# schema check; here we just ensure we're parsing a version we understand.
# mikefarah yq v4: `// empty` is path-alt not value-default; use direct
# path + null check below.
if ! schema_version=$(yq -r '.schema_version' "$REGISTRY" 2>"$yq_err"); then
	echo "list-consumers: yq failed parsing $REGISTRY:" >&2
	cat "$yq_err" >&2
	exit 2
fi
if [ "$schema_version" != "1" ]; then
	echo "list-consumers: $REGISTRY schema_version=$schema_version not supported (expected 1)" >&2
	exit 2
fi

# Convert YAML → JSON once; everything downstream is jq.
if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
	echo "list-consumers: yq failed extracting .consumers from $REGISTRY:" >&2
	cat "$yq_err" >&2
	exit 2
fi

# Guard against `consumers: null` or absent .consumers — yq emits the
# literal string "null" in that case; downstream `jq -r '.[]'` would
# throw "Cannot iterate over null" under set -e + exit with rc=1 +
# SIGPIPE noise instead of the documented rc=2 precondition error.
# Code-reviewer Phase 1 finding #2.
if [ "$consumers_json" = "null" ] || [ -z "$consumers_json" ]; then
	echo "list-consumers: $REGISTRY .consumers is null or empty" >&2
	exit 2
fi

# CR-in-CI r1: also reject non-array shapes (e.g. `consumers: {foo: 1}`
# or `consumers: "x"`). Without this, jq -r '.[]' below errors with
# "Cannot iterate over <type>" under set -e instead of the documented
# rc=2 precondition error. The schema validator gate prevents this at
# commit-time, but list-consumers runs against arbitrary working-copy
# or fetched-branch state — it must self-guard.
if ! jq -e 'type == "array"' >/dev/null <<<"$consumers_json"; then
	consumers_type=$(jq -r 'type' <<<"$consumers_json")
	echo "list-consumers: $REGISTRY .consumers must be an array (got '$consumers_type')" >&2
	exit 2
fi

# --behind filter — keep entries whose pinned_version sorts strictly less
# than the requested version (semver-aware via sort -V).
if [ -n "$BEHIND_VERSION" ]; then
	filtered='[]'
	while IFS=$'\t' read -r name pin; do
		[ -n "$name" ] || continue
		# Skip when pinned == BEHIND_VERSION (not "behind")
		[ "$pin" = "$BEHIND_VERSION" ] && continue
		# Sort the pair; if pin sorts first AND isn't equal, pin is older.
		first=$(printf '%s\n%s\n' "$pin" "$BEHIND_VERSION" | sort -V | head -1)
		if [ "$first" = "$pin" ]; then
			filtered=$(jq --arg n "$name" '. + [$n]' <<<"$filtered")
		fi
	done < <(jq -r '.[] | "\(.name)\t\(.pinned_version)"' <<<"$consumers_json")
	# Restrict the consumers_json to only the filtered names.
	consumers_json=$(jq --argjson keep "$filtered" '[.[] | select(.name as $n | $keep | index($n))]' <<<"$consumers_json")
fi

case "$FORMAT" in
json)
	printf '%s\n' "$consumers_json"
	;;
text)
	count=$(jq 'length' <<<"$consumers_json")
	if [ -n "$BEHIND_VERSION" ]; then
		echo "=== Consumers behind v$BEHIND_VERSION ($count) ==="
	else
		echo "=== Consumers ($count) ==="
	fi
	echo
	printf '%-28s %-12s %-44s %s\n' "name" "pin" "repo" "path"
	printf '%-28s %-12s %-44s %s\n' "----" "---" "----" "----"
	jq -r '.[] | [.name, .pinned_version, .repo, .local_path] | @tsv' <<<"$consumers_json" |
		while IFS=$'\t' read -r name pin repo path; do
			printf '%-28s %-12s %-44s %s\n' "$name" "$pin" "$repo" "$path"
		done
	;;
esac
