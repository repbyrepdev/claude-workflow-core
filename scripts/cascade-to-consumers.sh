#!/bin/bash
set -euo pipefail
# event: post-release
# auto-register: false
# v0.22.0 (#152) — producer-side post-release cascade.
#
# After a plugin release tags + cache-populates, this script iterates
# .github/consumers.yml and opens a tracking issue in each consumer
# saying "v<NEW> available — run refresh-from-source.sh". Wired
# automatically into scripts/release.sh after the gh release create
# step succeeds; can also be invoked manually.
#
# Idempotent: skips consumers whose pinned_version == NEW; skips
# consumers that already have an open auto:plugin-release-cascade
# issue with this exact (NEW, OLD) pair (search via gh issue list).
#
# Usage:
#   scripts/cascade-to-consumers.sh                # cascade all consumers, version from plugin.json
#   scripts/cascade-to-consumers.sh --dry-run      # preview without creating issues
#   scripts/cascade-to-consumers.sh --version 0.22.0    # override the cascade version
#   scripts/cascade-to-consumers.sh --consumer <name>   # single consumer
#   scripts/cascade-to-consumers.sh --all-consumers     # explicit default
#   scripts/cascade-to-consumers.sh --help
#
# Exit codes:
#   0 — every targeted consumer had a cascade issue opened, skipped
#       (already current OR existing-issue idempotency), or dry-runned
#       cleanly
#   2 — precondition error (consumers.yml/plugin.json missing, yq/jq/gh
#       missing, schema invalid, --version not X.Y.Z, --consumer not
#       found, unknown arg)
#   3 — partial failure: at least one consumer's gh issue create OR gh
#       issue list (idempotency check) failed; worst rc across all
#       consumers, not last. Audit log records per-consumer status.

DRY_RUN=0
VERSION_OVERRIDE=""
SINGLE_CONSUMER=""
ALL_CONSUMERS=0

while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--version)
		[ "$#" -ge 2 ] || {
			echo "cascade-to-consumers: --version requires X.Y.Z" >&2
			exit 2
		}
		VERSION_OVERRIDE=$2
		if ! [[ $VERSION_OVERRIDE =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "cascade-to-consumers: --version requires X.Y.Z semver (got: '$VERSION_OVERRIDE')" >&2
			exit 2
		fi
		shift 2
		;;
	--consumer)
		[ "$#" -ge 2 ] || {
			echo "cascade-to-consumers: --consumer requires a name" >&2
			exit 2
		}
		SINGLE_CONSUMER=$2
		shift 2
		;;
	--all-consumers)
		ALL_CONSUMERS=1
		shift
		;;
	-h | --help)
		# Mirror list-consumers.sh + refresh-from-source.sh — skip the
		# shebang + `set -*` + frontmatter directives, dump the rest of
		# the comment header verbatim. No hardcoded line numbers (drifts).
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
		echo "cascade-to-consumers: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ -n "$SINGLE_CONSUMER" ] && [ "$ALL_CONSUMERS" = "1" ]; then
	echo "cascade-to-consumers: --consumer and --all-consumers are mutually exclusive" >&2
	exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$REPO_ROOT/.github/consumers.yml"
PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$REGISTRY" ]; then
	echo "cascade-to-consumers: $REGISTRY missing" >&2
	exit 2
fi
if [ ! -f "$PLUGIN_JSON" ]; then
	echo "cascade-to-consumers: $PLUGIN_JSON missing" >&2
	exit 2
fi

for cmd in yq jq gh; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "cascade-to-consumers: $cmd required" >&2
		exit 2
	}
done

# Initialize trap state BEFORE mktemp so a mktemp failure under set -u
# doesn't crash the cleanup with unbound-array. Same hardening pattern
# as refresh-from-source.sh r3 silent-failure-hunter finding.
yq_err=""

# shellcheck disable=SC2329,SC2317
_cleanup() {
	[ -n "$yq_err" ] && rm -f "$yq_err"
}
trap _cleanup EXIT INT TERM HUP

yq_err=$(mktemp -t cascade-yq.XXXXXX) || {
	echo "cascade-to-consumers: mktemp failed — cannot stage yq error buffer" >&2
	exit 2
}

# Resolve cascade version. Plugin manifest is the canonical source;
# --version override is for testing + manual cascade of historical tags.
if [ -n "$VERSION_OVERRIDE" ]; then
	NEW_VER=$VERSION_OVERRIDE
else
	if ! NEW_VER=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>"$yq_err"); then
		echo "cascade-to-consumers: jq failed parsing $PLUGIN_JSON:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	if [ -z "$NEW_VER" ] || [ "$NEW_VER" = "null" ]; then
		echo "cascade-to-consumers: $PLUGIN_JSON has no .version field" >&2
		exit 2
	fi
	if ! [[ $NEW_VER =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "cascade-to-consumers: $PLUGIN_JSON .version='$NEW_VER' not X.Y.Z" >&2
		exit 2
	fi
fi

# Schema version sanity (mirror list-consumers.sh).
if ! schema_version=$(yq -r '.schema_version' "$REGISTRY" 2>"$yq_err"); then
	echo "cascade-to-consumers: yq failed parsing $REGISTRY:" >&2
	cat "$yq_err" >&2
	exit 2
fi
if [ "$schema_version" != "1" ]; then
	echo "cascade-to-consumers: $REGISTRY schema_version=$schema_version not supported (expected 1)" >&2
	exit 2
fi

if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
	echo "cascade-to-consumers: yq failed extracting .consumers:" >&2
	cat "$yq_err" >&2
	exit 2
fi
if [ "$consumers_json" = "null" ] || [ -z "$consumers_json" ]; then
	echo "cascade-to-consumers: $REGISTRY .consumers is null or empty" >&2
	exit 2
fi
if ! jq -e 'type == "array"' >/dev/null <<<"$consumers_json"; then
	consumers_type=$(jq -r 'type' <<<"$consumers_json")
	echo "cascade-to-consumers: $REGISTRY .consumers must be an array (got '$consumers_type')" >&2
	exit 2
fi

# Filter to single consumer if requested.
if [ -n "$SINGLE_CONSUMER" ]; then
	if ! jq -e --arg n "$SINGLE_CONSUMER" 'map(select(.name == $n)) | length > 0' >/dev/null <<<"$consumers_json"; then
		echo "cascade-to-consumers: --consumer '$SINGLE_CONSUMER' not found in $REGISTRY" >&2
		exit 2
	fi
	consumers_json=$(jq --arg n "$SINGLE_CONSUMER" 'map(select(.name == $n))' <<<"$consumers_json")
fi

LOG_DIR="$REPO_ROOT/.claude/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cascade.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

_log() {
	# JSONL via jq for proper escaping. Args: consumer repo old_ver action [issue_num] [err].
	local consumer=$1 repo=$2 old_ver=$3 action=$4 issue_num=${5:-} err=${6:-}
	if [ -n "$issue_num" ]; then
		jq -cn --arg ts "$TS" --arg consumer "$consumer" --arg repo "$repo" \
			--arg from "$old_ver" --arg to "$NEW_VER" --arg action "$action" \
			--argjson issue "$issue_num" \
			'{ts:$ts,consumer:$consumer,repo:$repo,from:$from,to:$to,action:$action,issue:$issue}' \
			>>"$LOG_FILE"
	elif [ -n "$err" ]; then
		jq -cn --arg ts "$TS" --arg consumer "$consumer" --arg repo "$repo" \
			--arg from "$old_ver" --arg to "$NEW_VER" --arg action "$action" \
			--arg err "$err" \
			'{ts:$ts,consumer:$consumer,repo:$repo,from:$from,to:$to,action:$action,error:$err}' \
			>>"$LOG_FILE"
	else
		jq -cn --arg ts "$TS" --arg consumer "$consumer" --arg repo "$repo" \
			--arg from "$old_ver" --arg to "$NEW_VER" --arg action "$action" \
			'{ts:$ts,consumer:$consumer,repo:$repo,from:$from,to:$to,action:$action}' \
			>>"$LOG_FILE"
	fi
}

# Render the issue body for a consumer. Args: consumer_name old_ver.
# Heredoc indirection via printf so callers can pipe directly into
# `gh issue create --body-file -` without intermediate tmp files
# leaking under signals.
_render_body() {
	local name=$1 old=$2
	cat <<EOF
**Area:** Infrastructure

claude-workflow-core has released **v$NEW_VER** (previously pinned: v$old).

Run on this machine to refresh:

\`\`\`bash
~/claude-workflow-core/scripts/refresh-from-source.sh --consumer $name
\`\`\`

This will:
- Replicate updated SSOT files (labels, templates, workflows) into this repo
- Honor entries in \`.claude/local-overrides.yml\`
- Audit-log replacements to \`.claude/logs/refresh-from-source.jsonl\`

After running locally, commit + push the result via ship-pr-cycle.

[Plugin release notes](https://github.com/repbyrepdev/claude-workflow-core/releases/tag/v$NEW_VER)

---

Auto-opened by plugin post-release cascade (epic #138 Sub 14).
EOF
}

# Track worst rc across consumers — partial failure surfaces as rc=3
# without aborting downstream consumers. Same shape as
# refresh-from-source.sh.
worst_rc=0
total=0
created=0
skipped_current=0
skipped_exists=0
failed=0

# Iterate via length+index — set -e + jq -c output safer than process
# substitution + while-read which silently swallows the last line if
# it lacks a trailing newline.
n=$(jq 'length' <<<"$consumers_json")
for ((i = 0; i < n; i++)); do
	entry=$(jq -c ".[$i]" <<<"$consumers_json")
	name=$(jq -r '.name' <<<"$entry")
	repo=$(jq -r '.repo' <<<"$entry")
	old_ver=$(jq -r '.pinned_version' <<<"$entry")
	total=$((total + 1))

	# Skip consumers already on the new version.
	if [ "$old_ver" = "$NEW_VER" ]; then
		echo "[CURRENT] $name ($repo) — pinned $old_ver matches v$NEW_VER"
		_log "$name" "$repo" "$old_ver" "skip-current"
		skipped_current=$((skipped_current + 1))
		continue
	fi

	title="feat: refresh from plugin v$NEW_VER (was v$old_ver)"

	# Idempotency: check for existing open cascade issue with the same
	# title. gh issue list --search uses a "in:title" filter so we don't
	# false-match on issues that reference the title in their body.
	# Quote the title in the search query so multi-word titles match
	# the full string, not OR'd individual words.
	if ! existing=$(gh issue list --repo "$repo" \
		--state open \
		--label auto:plugin-release-cascade \
		--search "\"$title\" in:title" \
		--json number,title \
		--jq "map(select(.title == \"$title\")) | .[0].number // empty" 2>"$yq_err"); then
		echo "[FAIL] $name ($repo) — gh issue list idempotency check failed:" >&2
		cat "$yq_err" >&2
		_log "$name" "$repo" "$old_ver" "fail-idempotency-check" "" "$(cat "$yq_err")"
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi
	if [ -n "$existing" ] && [ "$existing" != "null" ]; then
		echo "[EXISTS] $name ($repo) — issue #$existing already open"
		_log "$name" "$repo" "$old_ver" "skip-exists" "$existing"
		skipped_exists=$((skipped_exists + 1))
		continue
	fi

	if [ "$DRY_RUN" = "1" ]; then
		echo "[DRY-RUN] $name ($repo) — would create: $title"
		_log "$name" "$repo" "$old_ver" "dry-run-would-create"
		continue
	fi

	# Create the issue. Pipe the body so we don't leak tmp files on
	# signals. --label intentionally NOT passed — consumer repos may
	# not have the auto:plugin-release-cascade label yet (and label-
	# creation is out of scope here; consumers register it via their
	# own labels.yml). If the label is missing, gh create still
	# succeeds; ai-triage / label-sync handle classification after.
	if ! issue_url=$(_render_body "$name" "$old_ver" |
		gh issue create --repo "$repo" --title "$title" --body-file - 2>"$yq_err"); then
		echo "[FAIL] $name ($repo) — gh issue create failed:" >&2
		cat "$yq_err" >&2
		_log "$name" "$repo" "$old_ver" "fail-create" "" "$(cat "$yq_err")"
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi
	# gh issue create prints the URL; extract the trailing /N to log.
	issue_num=$(printf '%s' "$issue_url" | awk -F/ '{print $NF}' | tr -d '[:space:]')
	if ! [[ $issue_num =~ ^[0-9]+$ ]]; then
		# Numeric extraction failed — log raw URL but don't fail the cascade.
		echo "[CREATED] $name ($repo) — $issue_url (issue number parse failed)"
		_log "$name" "$repo" "$old_ver" "created-url-only" "" "$issue_url"
		created=$((created + 1))
		continue
	fi
	echo "[CREATED] $name ($repo) — issue #$issue_num"
	_log "$name" "$repo" "$old_ver" "created" "$issue_num"
	created=$((created + 1))
done

echo
echo "=== cascade summary ($NEW_VER) ==="
echo "  total:           $total"
echo "  created:         $created"
echo "  skipped current: $skipped_current"
echo "  skipped exists:  $skipped_exists"
echo "  failed:          $failed"

exit "$worst_rc"
