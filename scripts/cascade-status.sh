#!/bin/bash
set -euo pipefail
# event: none
# auto-register: false
# v0.22.0 (#152) — cascade-status snapshot.
#
# For each consumer in .github/consumers.yml, report:
#   - pinned plugin version vs current plugin version
#   - whether an open auto:plugin-release-cascade issue is outstanding
# Used by session-start to surface "N consumers behind plugin" without
# the operator having to remember which ones.
#
# Usage:
#   scripts/cascade-status.sh             # text table
#   scripts/cascade-status.sh --json      # machine-readable
#   scripts/cascade-status.sh --quiet     # silent unless behind > 0; exit 0 clean, 1 behind
#   scripts/cascade-status.sh --help
#
# Exit codes:
#   0 — clean (all consumers current OR --quiet with behind == 0)
#   1 — at least one consumer behind (--quiet only — text/json modes
#       always return 0 since the report itself IS the output)
#   2 — precondition error (consumers.yml/plugin.json missing, yq/jq/gh
#       missing, schema invalid, unknown arg)

FORMAT=text
QUIET=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--json)
		FORMAT=json
		shift
		;;
	--quiet)
		QUIET=1
		shift
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
		echo "cascade-status: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ "$QUIET" = "1" ] && [ "$FORMAT" = "json" ]; then
	echo "cascade-status: --quiet and --json are mutually exclusive" >&2
	exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/.github/consumers.yml"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

[ -f "$REGISTRY" ] || {
	echo "cascade-status: $REGISTRY missing" >&2
	exit 2
}
[ -f "$PLUGIN_JSON" ] || {
	echo "cascade-status: $PLUGIN_JSON missing" >&2
	exit 2
}

for cmd in yq jq gh; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "cascade-status: $cmd required" >&2
		exit 2
	}
done

yq_err=""
# shellcheck disable=SC2329,SC2317
_cleanup() { [ -n "$yq_err" ] && rm -f "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

yq_err=$(mktemp -t cascade-status-yq.XXXXXX) || {
	echo "cascade-status: mktemp failed" >&2
	exit 2
}

if ! current_ver=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>"$yq_err"); then
	echo "cascade-status: jq failed parsing $PLUGIN_JSON:" >&2
	cat "$yq_err" >&2
	exit 2
fi
if [ -z "$current_ver" ] || [ "$current_ver" = "null" ]; then
	echo "cascade-status: $PLUGIN_JSON has no .version field" >&2
	exit 2
fi

if ! schema_version=$(yq -r '.schema_version' "$REGISTRY" 2>"$yq_err"); then
	echo "cascade-status: yq failed parsing $REGISTRY:" >&2
	cat "$yq_err" >&2
	exit 2
fi
if [ "$schema_version" != "1" ]; then
	echo "cascade-status: $REGISTRY schema_version=$schema_version not supported (expected 1)" >&2
	exit 2
fi

if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
	echo "cascade-status: yq failed extracting .consumers:" >&2
	cat "$yq_err" >&2
	exit 2
fi
# r2 silent-failure-hunter LOW: zero consumers is operationally valid
# (fresh plugin, no consumers yet) — don't crash the session-start hook
# on every boot. cascade-to-consumers.sh treats it as an error (operator
# explicitly asked to cascade an empty set = mistake); cascade-status.sh
# is a passive read so empty is fine.
if [ "$consumers_json" = "null" ] || [ -z "$consumers_json" ]; then
	# Render zero-consumer empty snapshot per requested format and exit clean.
	case "$FORMAT" in
	json) printf '[]\n' ;;
	text) [ "$QUIET" != "1" ] && echo "=== Cascade status (plugin v$current_ver) === (no consumers registered)" ;;
	esac
	exit 0
fi
if ! jq -e 'type == "array"' >/dev/null <<<"$consumers_json"; then
	consumers_type=$(jq -r 'type' <<<"$consumers_json")
	echo "cascade-status: $REGISTRY .consumers must be an array (got '$consumers_type')" >&2
	exit 2
fi

# Build status records per consumer. Output is an array of:
#   { name, repo, pinned, current, is_behind, open_cascade_issue }
# r2 silent-failure-hunter MEDIUM: every jq call guarded with explicit
# error capture; partial gh failures tracked separately so --quiet can
# surface a "detection unreliable" stderr signal.
status_json='[]'
gh_failures=0
if ! n=$(jq 'length' <<<"$consumers_json" 2>"$yq_err"); then
	echo "cascade-status: jq failed counting consumers:" >&2
	cat "$yq_err" >&2
	exit 2
fi
for ((i = 0; i < n; i++)); do
	if ! entry=$(jq -c ".[$i]" <<<"$consumers_json" 2>"$yq_err"); then
		echo "cascade-status: jq failed extracting consumer[$i]:" >&2
		cat "$yq_err" >&2
		continue
	fi
	name=$(jq -r '.name // empty' <<<"$entry")
	repo=$(jq -r '.repo // empty' <<<"$entry")
	pinned=$(jq -r '.pinned_version // empty' <<<"$entry")
	if [ -z "$name" ] || [ -z "$repo" ] || [ -z "$pinned" ]; then
		echo "cascade-status: consumer[$i] missing required field — skipping" >&2
		continue
	fi

	# r2 code-simplifier LOW: compute is_behind inside jq instead of via
	# bash ternary intermediate ($([ A != B ] && echo true || echo false)
	# is a known footgun + extra subshell per consumer).

	# Query open cascade issue. Drop --search (GitHub tokenizer
	# fragments colons/parens/dots and may false-miss). Use --label
	# filter + take first open — cascade-to-consumers.sh creates ONE
	# per version per consumer so "any open" is the right semantic.
	issue_num=""
	if [ "$pinned" != "$current_ver" ]; then
		if ! issue_num=$(gh issue list --repo "$repo" \
			--state open \
			--label auto:plugin-release-cascade \
			--json number 2>"$yq_err" |
			jq -r '.[0].number // empty' 2>>"$yq_err"); then
			# Best-effort: track gh failure count so --quiet can warn,
			# but don't abort the whole sweep on one consumer's failure.
			issue_num="?"
			gh_failures=$((gh_failures + 1))
		fi
	fi

	if ! status_json=$(jq --arg n "$name" --arg r "$repo" --arg p "$pinned" \
		--arg c "$current_ver" --arg i "$issue_num" \
		'. + [{name:$n, repo:$r, pinned:$p, current:$c, is_behind:($p != $c), open_cascade_issue:$i}]' \
		<<<"$status_json" 2>"$yq_err"); then
		echo "cascade-status: jq failed appending status for consumer[$i]:" >&2
		cat "$yq_err" >&2
		continue
	fi
done

if ! behind=$(jq '[.[] | select(.is_behind == true)] | length' <<<"$status_json" 2>"$yq_err"); then
	echo "cascade-status: jq failed counting behind consumers:" >&2
	cat "$yq_err" >&2
	exit 2
fi

case "$FORMAT" in
json)
	printf '%s\n' "$status_json"
	;;
text)
	if [ "$QUIET" = "1" ] && [ "$behind" -eq 0 ]; then
		exit 0
	fi
	if [ "$QUIET" = "1" ]; then
		echo "cascade-status: $behind consumer(s) behind plugin v$current_ver (run 'scripts/cascade-status.sh' for details)" >&2
		# r2 silent-failure-hunter MEDIUM: surface gh detection failures
		# so operator knows the issue-existence side of the count is
		# unreliable. Without this, an operator firing cascade-to-
		# consumers.sh based on the laggard count would create duplicates
		# when the idempotency check there hits the same gh failure.
		if [ "$gh_failures" -gt 0 ]; then
			echo "cascade-status: WARNING: $gh_failures consumer(s) had gh failures — issue-detection unreliable; recheck before cascading" >&2
		fi
		exit 1
	fi
	echo "=== Cascade status (plugin v$current_ver) ==="
	echo
	printf '%-28s %-12s %-44s %s\n' "name" "pinned" "repo" "open-cascade"
	printf '%-28s %-12s %-44s %s\n' "----" "------" "----" "------------"
	jq -r '.[] | [.name, .pinned, .repo, (if .is_behind then (if .open_cascade_issue == "" then "(no open issue — run cascade)" elif .open_cascade_issue == "?" then "?" else "#" + .open_cascade_issue end) else "current" end)] | @tsv' <<<"$status_json" |
		while IFS=$'\t' read -r name pinned repo state; do
			printf '%-28s %-12s %-44s %s\n' "$name" "$pinned" "$repo" "$state"
		done
	echo
	echo "$behind consumer(s) behind."
	# Use `if` not `[ A ] && B` — under set -e, the test returning rc=1
	# would propagate as the script's final exit code (false-fail).
	if [ "$gh_failures" -gt 0 ]; then
		echo "WARNING: $gh_failures consumer(s) had gh failures — issue-detection unreliable" >&2
	fi
	;;
esac
