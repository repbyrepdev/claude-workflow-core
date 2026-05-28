#!/bin/bash
set -euo pipefail
# Pre-commit gate: validate `.claude/local-overrides.yml` schema integrity.
#
# local-overrides.yml is the consumer's operator-declared divergence
# ledger. Anything listed here is INTENTIONAL drift from plugin SSOT —
# `hash-drift.sh` skips these paths and surfaces them as "known
# overrides" instead of "violation".
#
# Schema (validated here):
#   schema_version: 1
#   overrides:
#     - path: <relative-path>
#       category: domain-extension | superset | temp-divergence | legacy
#       reason: <free-form string, >=10 chars>
#       added: YYYY-MM-DD
#       [expires: YYYY-MM-DD]  # required for category=temp-divergence
#       [diff_allowed: <string>]  # informational for category=superset
#
# Bypass: LOCAL_OVERRIDES_SCHEMA_SKIP=1 (audit-logged to stderr).
#
# Exit codes:
#   0 — passed (no file staged, OR file is empty/absent, OR schema valid)
#   1 — schema violation
#   2 — precondition error (yq missing, mktemp failure, yq parse failure)

if [ "${LOCAL_OVERRIDES_SCHEMA_SKIP:-0}" = "1" ]; then
	echo "local-overrides-schema-check: LOCAL_OVERRIDES_SCHEMA_SKIP=1 — bypassing" >&2
	exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "local-overrides-schema-check: not in a git working tree — refusing" >&2
	exit 2
}
cd "$REPO_ROOT"

OVERRIDES=".claude/local-overrides.yml"

STAGED=$(git diff --cached --name-only --diff-filter=ACMRD |
	grep -Fx "$OVERRIDES" || true)
if [ -z "$STAGED" ]; then
	exit 0
fi

if [ ! -f "$OVERRIDES" ]; then
	# Staged for deletion — operator removing the overrides file is fine
	# (consumer might have eliminated all divergences). Allow.
	exit 0
fi

command -v yq >/dev/null 2>&1 || {
	echo "local-overrides-schema-check: yq required" >&2
	exit 2
}

yq_err=$(mktemp -t lo-yq.XXXXXX) || {
	echo "local-overrides-schema-check: mktemp failed" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

_yq_or_die() {
	local expr=$1 file=$2 desc=$3
	local out
	: >"$yq_err"
	if ! out=$(yq -r "$expr" "$file" 2>"$yq_err"); then
		echo "local-overrides-schema-check: yq failed parsing $file ($desc):" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	printf '%s' "$out"
}

spec_version=$(_yq_or_die '.schema_version' "$OVERRIDES" 'schema_version')
if [ "$spec_version" != "1" ]; then
	echo "local-overrides-schema-check: $OVERRIDES .schema_version must equal 1 (got '$spec_version')" >&2
	exit 1
fi

# Allow empty overrides[] — fresh consumer with no divergences is valid.
overrides_count=$(_yq_or_die '.overrides // [] | length' "$OVERRIDES" 'overrides list length')
if [ "$overrides_count" = "0" ]; then
	exit 0
fi

if ! [[ $overrides_count =~ ^[0-9]+$ ]]; then
	echo "local-overrides-schema-check: $OVERRIDES .overrides | length returned non-numeric '$overrides_count'" >&2
	exit 1
fi

errors=()
today=$(date +%Y-%m-%d)
i=0
while [ "$i" -lt "$overrides_count" ]; do
	path=$(_yq_or_die ".overrides[$i].path" "$OVERRIDES" "overrides[$i].path")
	category=$(_yq_or_die ".overrides[$i].category" "$OVERRIDES" "overrides[$i].category")
	reason=$(_yq_or_die ".overrides[$i].reason" "$OVERRIDES" "overrides[$i].reason")
	added=$(_yq_or_die ".overrides[$i].added" "$OVERRIDES" "overrides[$i].added")
	expires=$(_yq_or_die ".overrides[$i].expires // \"\"" "$OVERRIDES" "overrides[$i].expires")

	# path: required, non-empty, no '..' or absolute
	if [ -z "$path" ] || [ "$path" = "null" ]; then
		errors+=("overrides[$i].path missing or null")
	elif [[ $path == /* ]] || [[ $path == *..* ]]; then
		errors+=("overrides[$i].path '$path' must be repo-relative (no leading '/', no '..')")
	fi

	# category: required, must be one of the 4 enums
	case "$category" in
	domain-extension | superset | temp-divergence | legacy) ;;
	"" | null)
		errors+=("overrides[$i].category missing or null")
		;;
	*)
		errors+=("overrides[$i].category '$category' must be one of: domain-extension, superset, temp-divergence, legacy")
		;;
	esac

	# reason: required, >=10 chars (operator must justify the divergence)
	if [ -z "$reason" ] || [ "$reason" = "null" ]; then
		errors+=("overrides[$i].reason missing or null")
	elif [ "${#reason}" -lt 10 ]; then
		errors+=("overrides[$i].reason '$reason' is too short (min 10 chars — operator must justify the divergence)")
	fi

	# added: required, YYYY-MM-DD shape
	if [ -z "$added" ] || [ "$added" = "null" ]; then
		errors+=("overrides[$i].added missing or null")
	elif ! [[ $added =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
		errors+=("overrides[$i].added '$added' must be YYYY-MM-DD")
	fi

	# expires: required when category=temp-divergence; YYYY-MM-DD shape;
	# refuse if past today (operator should reconcile expired entries).
	if [ "$category" = "temp-divergence" ]; then
		if [ -z "$expires" ] || [ "$expires" = "null" ]; then
			errors+=("overrides[$i].expires required for category=temp-divergence")
		elif ! [[ $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
			errors+=("overrides[$i].expires '$expires' must be YYYY-MM-DD")
		elif [ "$expires" \< "$today" ]; then
			errors+=("overrides[$i].expires '$expires' is in the past (today=$today) — reconcile or extend")
		fi
	fi

	i=$((i + 1))
done

if [ ${#errors[@]} -gt 0 ]; then
	echo "local-overrides-schema-check: ${#errors[@]} violation(s) in $OVERRIDES:" >&2
	for e in "${errors[@]}"; do
		echo "  - $e" >&2
	done
	echo "" >&2
	echo "  Fix: edit $OVERRIDES + re-stage." >&2
	echo "  Schema: see templates/local-overrides.yml.tpl in plugin." >&2
	echo "  Bypass (audit-log): LOCAL_OVERRIDES_SCHEMA_SKIP=1 git commit ..." >&2
	exit 1
fi

exit 0
