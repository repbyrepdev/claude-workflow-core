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
# doesn't crash the EXIT trap with unbound-variable when _cleanup
# dereferences $yq_err. r2 comment-analyzer: refresh-from-source.sh r3
# hardened the same pattern for an array; here yq_err is a scalar so
# the failure mode is unbound-scalar, not unbound-array.
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
mkdir -p "$LOG_DIR" || {
	echo "cascade-to-consumers: failed to create $LOG_DIR" >&2
	exit 2
}
LOG_FILE="$LOG_DIR/cascade.jsonl"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

_log() {
	# JSONL via jq for proper escaping. Args: consumer repo old_ver action [issue_num] [detail].
	# `detail` carries free-form supplemental text — error message on failure
	# branches, raw URL on the rare numeric-parse-fallback success branch.
	# r2 silent-failure-hunter CRITICAL: previously mutually-exclusive
	# branches dropped `detail` whenever `issue_num` was set, silently
	# losing gh-close stderr on fail-supersede-close. Now ADDITIVE —
	# emits both fields when both are present (issue + detail).
	# Issue_num is also gracefully demoted if non-numeric so callers
	# can pass placeholders or malformed gh output without crashing the
	# script under set -e.
	local consumer=$1 repo=$2 old_ver=$3 action=$4 issue_num=${5:-} detail=${6:-}
	# Build the jq filter incrementally based on which fields are present.
	local filter='{ts:$ts,consumer:$consumer,repo:$repo,from:$from,to:$to,action:$action}'
	local -a jq_args=(
		--arg ts "$TS" --arg consumer "$consumer" --arg repo "$repo"
		--arg from "$old_ver" --arg to "$NEW_VER" --arg action "$action"
	)
	if [ -n "$issue_num" ]; then
		if [[ $issue_num =~ ^[0-9]+$ ]]; then
			jq_args+=(--argjson issue "$issue_num")
			filter='{ts:$ts,consumer:$consumer,repo:$repo,from:$from,to:$to,action:$action,issue:$issue}'
		else
			# Non-numeric (e.g. dry-run placeholder "<would-be-new>") —
			# preserve as string under .issue_ref to avoid --argjson crash.
			jq_args+=(--arg issue_ref "$issue_num")
			filter='{ts:$ts,consumer:$consumer,repo:$repo,from:$from,to:$to,action:$action,issue_ref:$issue_ref}'
		fi
	fi
	if [ -n "$detail" ]; then
		jq_args+=(--arg detail "$detail")
		# Append detail to the filter object.
		filter="${filter%\}}, detail:\$detail}"
	fi
	jq -cn "${jq_args[@]}" "$filter" >>"$LOG_FILE"
}

# Plugin identity SSOT (#2310): derive the repo URL + name from plugin.json so
# the cascade issue body carries no hardcoded self-references. Fail-closed at
# load if identity is incomplete (require_plugin_identity → rc 2 under set -e).
# NOTE: cascade already set PLUGIN_JSON above (for the .version read); the lib
# honors that pre-set value (${PLUGIN_JSON:-...}) so both read the SAME manifest.
_CASCADE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CASCADE_IDENTITY_LIB="$_CASCADE_LIB_DIR/../_lib/resolve-plugin-identity.sh"
# Fail with the script's precondition exit code (2) + a clear message when the
# SSOT lib is missing, rather than letting the bare `.` abort with rc 1 under
# set -e (CR phase2 major).
if [ ! -f "$_CASCADE_IDENTITY_LIB" ]; then
	echo "cascade-to-consumers: identity lib missing at $_CASCADE_IDENTITY_LIB" >&2
	exit 2
fi
# shellcheck source=../_lib/resolve-plugin-identity.sh
. "$_CASCADE_IDENTITY_LIB"
require_plugin_identity

# Render the issue body for a consumer. Args: consumer_name old_ver.
# Heredoc indirection via printf so callers can pipe directly into
# `gh issue create --body-file -` without intermediate tmp files
# leaking under signals.
_render_body() {
	local name=$1 old=$2
	cat <<EOF
**Area:** Infrastructure

$PLUGIN_NAME has released **v$NEW_VER** (previously pinned: v$old).

Run on this machine to refresh:

\`\`\`bash
~/$PLUGIN_NAME/scripts/refresh-from-source.sh --consumer $name
\`\`\`

This will:
- Replicate updated SSOT files (labels, templates, workflows) into this repo
- Honor entries in \`.claude/local-overrides.yml\`
- Audit-log replacements to \`.claude/logs/refresh-from-source.jsonl\`

After running locally, commit + push the result via ship-pr-cycle.

[Plugin release notes]($PLUGIN_REPO_URL/releases/tag/v$NEW_VER)

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
# r2 silent-failure-hunter HIGH: surface dedup activity in summary.
# Counters track BOTH successful supersedes AND failed close-attempts
# so a clean primary cascade doesn't hide dedup-feature regressions.
superseded=0
supersede_failed=0

# Iterate via length+index — set -e + jq -c output safer than process
# substitution + while-read which silently swallows the last line if
# it lacks a trailing newline. Guard every jq call so a corrupted
# consumers_json doesn't silently abort mid-sweep with no diagnostic
# (r2 silent-failure-hunter MEDIUM).
if ! n=$(jq 'length' <<<"$consumers_json" 2>"$yq_err"); then
	echo "cascade-to-consumers: jq failed counting consumers:" >&2
	cat "$yq_err" >&2
	exit 2
fi
for ((i = 0; i < n; i++)); do
	# r3 silent-failure-hunter MEDIUM: total++ before any continue so the
	# summary "total" matches the number of entries we tried.
	total=$((total + 1))
	if ! entry=$(jq -c ".[$i]" <<<"$consumers_json" 2>"$yq_err"); then
		echo "cascade-to-consumers: jq failed extracting consumer[$i]:" >&2
		cat "$yq_err" >&2
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi
	# r3 silent-failure-hunter LOW: explicit 2>"$yq_err" guard per the r2
	# mandate (previously bare jq -r). Catches set -e abort with diagnostic.
	if ! name=$(jq -r '.name // empty' <<<"$entry" 2>"$yq_err") ||
		! repo=$(jq -r '.repo // empty' <<<"$entry" 2>>"$yq_err") ||
		! old_ver=$(jq -r '.pinned_version // empty' <<<"$entry" 2>>"$yq_err"); then
		echo "cascade-to-consumers: jq -r failed extracting fields for consumer[$i]:" >&2
		cat "$yq_err" >&2
		_log "consumer[$i]" "<unknown>" "<unknown>" "fail-jq-extract" "" "$(cat "$yq_err")"
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi

	# Reject malformed entries explicitly rather than letting `--repo ''`
	# leak into the gh call + audit log.
	if [ -z "$name" ] || [ -z "$repo" ] || [ -z "$old_ver" ]; then
		echo "[FAIL] consumer[$i] missing required field (name='$name' repo='$repo' pinned_version='$old_ver')" >&2
		_log "${name:-<missing>}" "${repo:-<missing>}" "${old_ver:-<missing>}" "fail-malformed-entry" "" "consumer[$i] missing required field"
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi

	# Skip consumers already on the new version.
	if [ "$old_ver" = "$NEW_VER" ]; then
		echo "[CURRENT] $name ($repo) — pinned $old_ver matches v$NEW_VER"
		_log "$name" "$repo" "$old_ver" "skip-current"
		skipped_current=$((skipped_current + 1))
		continue
	fi

	title="feat: refresh from plugin v$NEW_VER (was v$old_ver)"

	# Idempotency MUST be label-based to survive future title-format drift.
	# Ensure the auto:plugin-release-cascade label exists in the consumer
	# repo before creation. `--force` is an UPSERT (creates if absent,
	# updates color/description if present) — this is intentional: the
	# plugin owns the label's canonical color + description, and consumer-
	# side edits should be made via local-overrides.yml (Sub 9), not by
	# manually editing the label on github.com. After this call both the
	# idempotency query AND the issue creation use --label so a re-cascade
	# detects its own prior issue.
	#
	# Failure to upsert the label halts cascade for this consumer (no
	# point creating an unlabeled issue that future idempotency checks
	# won't find). Common cause: gh token lacks `repo` write scope on
	# the consumer.
	if ! gh label create auto:plugin-release-cascade \
		--color "1a7f37" \
		--description "Auto-opened cascade tracker — consumer should refresh from plugin source" \
		--force \
		--repo "$repo" 2>"$yq_err"; then
		echo "[FAIL] $name ($repo) — failed to ensure auto:plugin-release-cascade label:" >&2
		cat "$yq_err" >&2
		_log "$name" "$repo" "$old_ver" "fail-label-create" "" "$(cat "$yq_err")"
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi

	# Idempotency: search by --label + --state open only (no --search;
	# GitHub's search tokenizer fragments colons/parens/dots so a quoted-
	# phrase search can false-miss a real match and create a duplicate).
	# Title-exact match happens in jq with --arg, avoiding shell-into-jq
	# string interpolation.
	if ! existing=$(gh issue list --repo "$repo" \
		--state open \
		--label auto:plugin-release-cascade \
		--json number,title 2>"$yq_err" |
		jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].number // empty' 2>>"$yq_err"); then
		echo "[FAIL] $name ($repo) — gh issue list idempotency check failed:" >&2
		cat "$yq_err" >&2
		_log "$name" "$repo" "$old_ver" "fail-idempotency-check" "" "$(cat "$yq_err")"
		failed=$((failed + 1))
		worst_rc=3
		continue
	fi
	# r3 silent-failure-hunter MEDIUM: validate $existing is numeric before
	# passing to _log (--argjson would crash the script if $existing is
	# non-JSON like "abc" — set -e would abort the whole cascade mid-sweep).
	if [ -n "$existing" ] && [ "$existing" != "null" ] && [[ $existing =~ ^[0-9]+$ ]]; then
		echo "[EXISTS] $name ($repo) — issue #$existing already open"
		_log "$name" "$repo" "$old_ver" "skip-exists" "$existing"
		skipped_exists=$((skipped_exists + 1))
		continue
	fi

	if [ "$DRY_RUN" = "1" ]; then
		echo "[DRY-RUN] $name ($repo) — would create: $title"
		_log "$name" "$repo" "$old_ver" "dry-run-would-create"
		# v0.26.0 #169: dry-run should preview supersedes too. Use a
		# synthetic placeholder for issue_num so the supersede preview
		# can format a "would close #X (superseded by ...)" line.
		# Real gh issue close is gated by DRY_RUN=1 inside the loop.
		issue_num="<would-be-new>"
	else
		# Render body to a variable so we can `printf '%s\n'` it (preserves
		# the trailing newline a heredoc produces — r3 silent-failure-hunter
		# LOW: bare `printf '%s' "$body"` would byte-mismatch heredoc-pipe).
		body=$(_render_body "$name" "$old_ver")
		# Create the issue with --label so future idempotency checks can find
		# it (label is now guaranteed to exist in the consumer repo).
		if ! issue_url=$(printf '%s\n' "$body" |
			gh issue create --repo "$repo" \
				--title "$title" \
				--label auto:plugin-release-cascade \
				--body-file - 2>"$yq_err"); then
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
			# Numeric extraction failed — log raw URL via .detail (not .error,
			# r2 code-simplifier LOW: the create itself succeeded). Don't fail
			# the cascade — the issue is created, just unparseable.
			echo "[CREATED] $name ($repo) — $issue_url (issue number parse failed)"
			_log "$name" "$repo" "$old_ver" "created-url-only" "" "$issue_url"
			created=$((created + 1))
			continue
		fi
		echo "[CREATED] $name ($repo) — issue #$issue_num"
		_log "$name" "$repo" "$old_ver" "created" "$issue_num"
		created=$((created + 1))
	fi

	# v0.26.0 #169: dedup — close any OTHER open cascade issues in this
	# consumer with a "superseded by #N" comment. Operator running
	# migrate-settings.sh once jumps consumer pin from oldest pin
	# straight to NEW_VER; intermediate cascades are no longer
	# actionable but pollute the board until manually closed.
	# Idempotent: a re-run that hits [EXISTS] above doesn't enter this
	# branch, so old cascades aren't re-closed. Dry-run uses a synthetic
	# placeholder for issue_num; we filter via jq tostring so non-numeric
	# placeholder doesn't crash --argjson. Failure here is best-effort
	# (primary create already succeeded); failures are audit-logged AND
	# counted in the supersede_failed total so a clean primary cascade
	# doesn't hide dedup regression (r2 silent-failure-hunter HIGH).
	#
	# r2 silent-failure-hunter MEDIUM: truncate $yq_err before each gh
	# call so stale stderr from the prior idempotency check doesn't
	# contaminate diagnostics.
	: >"$yq_err"
	if ! prior_list=$(gh issue list --repo "$repo" \
		--state open \
		--label auto:plugin-release-cascade \
		--json number,title 2>"$yq_err" |
		jq -r --arg keep "$issue_num" '.[] | select((.number | tostring) != $keep) | .number' 2>>"$yq_err"); then
		echo "  [supersede-skip] $name — gh issue list failed; superseded cleanup not attempted" >&2
		cat "$yq_err" >&2
		_log "$name" "$repo" "$old_ver" "fail-supersede-list" "" "$(cat "$yq_err")"
		# CR Phase 2 minor: count list-failure as a supersede failure
		# so summary doesn't under-report (counter was previously only
		# incremented on close-failures).
		supersede_failed=$((supersede_failed + 1))
		continue
	fi
	# r2 silent-failure-hunter HIGH: trim whitespace-only output that
	# would otherwise pass the `[ -z ]` test while spawning a degenerate
	# one-iteration loop.
	prior_list=$(printf '%s\n' "$prior_list" | sed '/^[[:space:]]*$/d')
	if [ -z "$prior_list" ]; then
		_log "$name" "$repo" "$old_ver" "supersede-none"
		continue
	fi
	while IFS= read -r prior; do
		[ -z "$prior" ] && continue
		[ "$prior" = "$issue_num" ] && continue
		# r2 silent-failure-hunter MEDIUM: non-numeric prior would crash
		# _log's --argjson; surface as audit anomaly + skip.
		if ! [[ $prior =~ ^[0-9]+$ ]]; then
			echo "  [supersede-skip] $name — non-numeric prior '$prior' from gh list" >&2
			_log "$name" "$repo" "$old_ver" "fail-supersede-nonnumeric" "" "non-numeric prior: $prior"
			supersede_failed=$((supersede_failed + 1))
			continue
		fi
		if [ "$DRY_RUN" = "1" ]; then
			echo "  [DRY-RUN-supersede] $name — would close #$prior (superseded by #$issue_num)"
			_log "$name" "$repo" "$old_ver" "dry-run-would-supersede" "$prior"
			continue
		fi
		# r2 silent-failure-hunter MEDIUM: truncate $yq_err before this gh
		# call too — keep stderr captures call-scoped.
		: >"$yq_err"
		# r2 silent-failure-hunter HIGH: comment SSOT — reference the new
		# cascade #issue_num for actionable detail (don't hardcode
		# migrate-settings.sh which may not exist on bootstrap-incomplete
		# consumers; the new issue body has the up-to-date refresh
		# instructions). Single canonical place for migration guidance.
		if ! gh issue close "$prior" --repo "$repo" \
			--comment "Superseded by #$issue_num (cascade for plugin v$NEW_VER). See #$issue_num for up-to-date refresh instructions; this older cascade is no longer actionable." \
			2>"$yq_err"; then
			echo "  [supersede-fail] $name — gh issue close #$prior failed:" >&2
			cat "$yq_err" >&2
			_log "$name" "$repo" "$old_ver" "fail-supersede-close" "$prior" "$(cat "$yq_err")"
			supersede_failed=$((supersede_failed + 1))
			# Don't fail the cascade — supersede is best-effort polish.
			continue
		fi
		echo "  [SUPERSEDED] $name — closed #$prior (superseded by #$issue_num)"
		_log "$name" "$repo" "$old_ver" "superseded-close" "$prior"
		superseded=$((superseded + 1))
	done <<<"$prior_list"
done

echo
echo "=== cascade summary ($NEW_VER) ==="
echo "  total:           $total"
echo "  created:         $created"
echo "  skipped current: $skipped_current"
echo "  skipped exists:  $skipped_exists"
echo "  failed:          $failed"
echo "  superseded:      $superseded"
echo "  supersede fails: $supersede_failed"

exit "$worst_rc"
