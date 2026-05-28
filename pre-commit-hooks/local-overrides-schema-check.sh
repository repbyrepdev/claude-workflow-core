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

# Detect staged deletion explicitly (covers both `git rm` and
# `git rm --cached` — the latter leaves the file on disk but removes
# the index entry, so a worktree-only `[ ! -f ]` check would miss it
# and then `git show :path` would fail with a confusing error).
STAGED_D=$(git diff --cached --name-only --diff-filter=D 2>/dev/null |
	grep -Fx "$OVERRIDES" || true)
if [ -n "$STAGED_D" ]; then
	# Operator removed overrides — consumer might have eliminated all
	# divergences. Allow.
	exit 0
fi

if [ ! -f "$OVERRIDES" ]; then
	# Worktree-only staging anomaly (e.g. file removed locally but not
	# staged). Treat as precondition error — distinct from staged delete.
	echo "local-overrides-schema-check: $OVERRIDES staged but missing on disk" >&2
	exit 2
fi

command -v yq >/dev/null 2>&1 || {
	echo "local-overrides-schema-check: yq required" >&2
	exit 2
}

# r3 code-reviewer Important: validate the STAGED blob, not the worktree
# file. Mirrors consumers-schema-check.sh + issue-template-schema-check.sh
# pattern. Without this, an operator who `git add`s a valid file then
# edits it locally would see the hook validate the WRONG content.
yq_err=$(mktemp -t lo-yq.XXXXXX) || {
	echo "local-overrides-schema-check: mktemp failed (yq_err buffer)" >&2
	exit 2
}
staged_tmp=$(mktemp -t lo-staged.XXXXXX) || {
	rm -f "$yq_err"
	echo "local-overrides-schema-check: mktemp failed (staged buffer)" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$yq_err" "$staged_tmp"; }
trap _cleanup EXIT INT TERM HUP

# Materialize staged content to a temp file. r3: capture git show stderr
# explicitly so corrupt-object-store / permission errors surface instead
# of getting masked.
if ! git show ":${OVERRIDES}" >"$staged_tmp" 2>"$yq_err"; then
	echo "local-overrides-schema-check: could not read staged $OVERRIDES:" >&2
	cat "$yq_err" >&2
	exit 2
fi

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

spec_version=$(_yq_or_die '.schema_version' "$staged_tmp" 'schema_version')
if [ "$spec_version" != "1" ]; then
	echo "local-overrides-schema-check: $OVERRIDES .schema_version must equal 1 (got '$spec_version')" >&2
	exit 1
fi

# CR-in-CI r1 F1: assert .overrides is an array (not scalar/object) BEFORE
# relying on `length`. `overrides: bogus` (scalar string) would have yq
# return `length(bogus)` = string length, slipping past as a numeric
# count and crashing later at .overrides[$i] iteration.
overrides_type=$(_yq_or_die '.overrides // [] | type' "$staged_tmp" 'overrides type')
if [ "$overrides_type" != "!!seq" ] && [ "$overrides_type" != "array" ]; then
	echo "local-overrides-schema-check: $OVERRIDES .overrides must be a list (got type '$overrides_type')" >&2
	exit 1
fi

# Allow empty overrides[] — fresh consumer with no divergences is valid.
overrides_count=$(_yq_or_die '.overrides // [] | length' "$staged_tmp" 'overrides list length')
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
	path=$(_yq_or_die ".overrides[$i].path" "$staged_tmp" "overrides[$i].path")
	category=$(_yq_or_die ".overrides[$i].category" "$staged_tmp" "overrides[$i].category")
	reason=$(_yq_or_die ".overrides[$i].reason" "$staged_tmp" "overrides[$i].reason")
	added=$(_yq_or_die ".overrides[$i].added" "$staged_tmp" "overrides[$i].added")
	expires=$(_yq_or_die ".overrides[$i].expires // \"\"" "$staged_tmp" "overrides[$i].expires")

	# path: required, non-empty, no absolute, no `..` as path SEGMENT.
	# CR-in-CI r1 F2: prior `*..*` rejected valid filenames like
	# `docs/v1..v2-notes.md`. Match `..` only when it's a bare segment.
	if [ -z "$path" ] || [ "$path" = "null" ]; then
		errors+=("overrides[$i].path missing or null")
	elif [[ $path == /* ]]; then
		errors+=("overrides[$i].path '$path' must be repo-relative (no leading '/')")
	elif [[ $path == ".." ]] || [[ $path == "../"* ]] || [[ $path == *"/.." ]] || [[ $path == *"/../"* ]]; then
		errors+=("overrides[$i].path '$path' contains '..' as a path segment (path traversal)")
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
