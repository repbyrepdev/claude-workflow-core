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
#   0 — listed (or --behind found no laggards = clean)
#   2 — precondition error (consumers.yml missing, yq/jq missing, schema invalid)

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
		shift 2
		;;
	-h | --help)
		awk '
			NR == 1 { next }
			/^set / { next }
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
	echo "list-consumers: $REGISTRY missing — Sub 3 (#141) hasn't shipped yet?" >&2
	exit 2
fi

for cmd in yq jq; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "list-consumers: $cmd required" >&2
		exit 2
	}
done

# Validate schema_version. The validator pre-commit hook owns the full
# schema check; here we just ensure we're parsing a version we understand.
# mikefarah yq v4: `// empty` is path-alt not value-default; use direct
# path + null check below.
schema_version=$(yq -r '.schema_version' "$REGISTRY" 2>/dev/null)
if [ "$schema_version" != "1" ]; then
	echo "list-consumers: $REGISTRY schema_version=$schema_version not supported (expected 1)" >&2
	exit 2
fi

# Convert YAML → JSON once; everything downstream is jq.
consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>/dev/null) || {
	echo "list-consumers: failed to parse consumers list from $REGISTRY" >&2
	exit 2
}

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
