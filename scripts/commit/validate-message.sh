#!/bin/bash
set -u
# v4.28-W3-CD #743 r2: factored-out commit-message validator.
#
# Reads message from stdin OR --file <path>; emits warnings on stderr;
# exits 0 if clean, 1 if any drift.
#
# SSOT: .github/commit-template.yml (schema, types, max-length, anti-patterns,
# body-required-for). Shared between:
#   .claude/skills/git-commit/run.sh        — pre-commit fail-closed for
#                                             Copilot drafts (rc != 0 → rc=4)
#   .claude/hooks/post-commit-template-lint.sh — post-commit warn-only
#
# Why factored out: PR #743 r2 CR finding flagged that the wrapper's inline
# preflight only enforced subject-length / type-prefix / Co-Authored-By, so
# a Copilot draft with `feat:` + missing WHY body would pass preflight then
# get caught only post-commit. SSOT-first: one validator, two callers.
#
# Usage:
#   echo "<message>" | .claude/scripts/commit/validate-message.sh
#   .claude/scripts/commit/validate-message.sh --file <path>
#
# Exit codes:
#   0 — message clean
#   1 — drift detected (warnings on stderr)
#   2 — arg / IO error

MSG=""
FILE=""
while [ $# -gt 0 ]; do
	case "$1" in
	--file)
		[ $# -ge 2 ] || {
			echo "error: --file requires a value" >&2
			exit 2
		}
		FILE="$2"
		shift 2
		;;
	-h | --help)
		sed -n '3,26p' "$0"
		exit 0
		;;
	*)
		echo "error: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

if [ -n "$FILE" ]; then
	[ -f "$FILE" ] || {
		echo "error: --file '$FILE' not found" >&2
		exit 2
	}
	# CR-in-CI #743 r5 major: capture cat's exit status. Without this, a
	# permission/IO failure on --file degrades into "error: empty message"
	# below — distinct failure modes must surface distinct errors.
	MSG=$(cat "$FILE") || {
		echo "error: failed to read --file '$FILE' (rc=$?)" >&2
		exit 2
	}
else
	MSG=$(cat) || {
		echo "error: failed to read commit message from stdin (rc=$?)" >&2
		exit 2
	}
fi

if [ -z "$MSG" ]; then
	echo "error: empty message" >&2
	exit 2
fi

SUBJECT=$(printf '%s' "$MSG" | head -1)
BODY=$(printf '%s' "$MSG" | tail -n +3)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
TEMPLATE="$REPO_ROOT/.github/commit-template.yml"

# Schema extraction — yq when available, hardcoded defaults otherwise.
# Mirrors post-commit-template-lint.sh fallback for portability.
# CR-in-CI #743 r3 major: fail hard on parse errors. Prior `2>/dev/null`
# silently swallowed yq stderr + ignored exit codes — a malformed
# .github/commit-template.yml (e.g., during a refactor) would degrade the
# validator to hardcoded defaults instead of the SSOT, and an empty MAX_LEN
# would cause a bash integer-expression error that fails silently. Now:
# capture yq rc per call; refuse with rc=2 + stderr message if any field
# fails to parse OR comes back empty.
if command -v yq >/dev/null 2>&1 && [ -f "$TEMPLATE" ]; then
	MAX_LEN=$(yq -r '.schema.subject.max_length // 70' "$TEMPLATE") || {
		echo "error: failed to parse $TEMPLATE (yq rc=$?) — schema.subject.max_length" >&2
		exit 2
	}
	VALID_TYPES=$(yq -r '.schema.subject.types | join("|")' "$TEMPLATE") || {
		echo "error: failed to parse $TEMPLATE (yq rc=$?) — schema.subject.types" >&2
		exit 2
	}
	BODY_REQUIRED_FOR=$(yq -r '.schema.body.required_for | join("|")' "$TEMPLATE") || {
		echo "error: failed to parse $TEMPLATE (yq rc=$?) — schema.body.required_for" >&2
		exit 2
	}
	# Empty values would silently degrade validation; refuse loudly.
	if [ -z "$MAX_LEN" ] || [ -z "$VALID_TYPES" ] || [ -z "$BODY_REQUIRED_FOR" ]; then
		echo "error: $TEMPLATE returned empty schema field(s) — MAX_LEN='$MAX_LEN' VALID_TYPES='$VALID_TYPES' BODY_REQUIRED_FOR='$BODY_REQUIRED_FOR'" >&2
		exit 2
	fi
	# CR-in-CI #743 r4 major: MAX_LEN must be a non-negative integer.
	# A non-numeric value (e.g., 'seventy') makes the `-gt` comparison
	# below return rc=2 and silently skip the subject-length check —
	# malformed schema disables validation instead of hard-failing.
	case "$MAX_LEN" in
	'' | *[!0-9]*)
		echo "error: $TEMPLATE schema.subject.max_length must be a non-negative integer, got '$MAX_LEN'" >&2
		exit 2
		;;
	esac
else
	MAX_LEN=70
	VALID_TYPES="feat|fix|refactor|perf|chore|docs|test|revert|build|ci"
	BODY_REQUIRED_FOR="feat|fix|refactor|perf"
fi

warnings=""

# Subject length
if [ "${#SUBJECT}" -gt "$MAX_LEN" ]; then
	warnings="${warnings}
  • Subject is ${#SUBJECT} chars (template max: $MAX_LEN)"
fi

# Subject format: <type>(<scope>): <summary> — type required, scope optional
TYPE=$(printf '%s' "$SUBJECT" | grep -oE "^($VALID_TYPES)(\([^)]+\))?:" | grep -oE "^($VALID_TYPES)" || echo "")
if [ -z "$TYPE" ]; then
	warnings="${warnings}
  • Subject does not start with a valid type: $VALID_TYPES"
fi

# Body required for feat/fix/refactor/perf
if [ -n "$TYPE" ] && printf '%s' "$TYPE" | grep -qE "^($BODY_REQUIRED_FOR)$"; then
	# Strip trailers (Co-Authored-By, Closes, etc.) before body-emptiness check
	BODY_WITHOUT_TRAILERS=$(printf '%s' "$BODY" | grep -vE '^(Co-Authored-By|Closes|Advances|Fixes|Signed-off-by|Refs):' | grep -v '^[[:space:]]*$' || echo "")
	if [ -z "$BODY_WITHOUT_TRAILERS" ]; then
		warnings="${warnings}
  • Type '$TYPE' requires a body explaining WHY (template body.required_for)"
	fi
fi

# Anti-pattern check: subject contains known bad phrases.
# Read .anti_patterns[].regex (or .pattern) from TEMPLATE SSOT; fall back to
# curated list when YAML missing or yq absent.
# CR-in-CI #743 r3 major: hard-fail on yq parse error (was silently
# swallowed). Also fix yq syntax: prior `.regex // .pattern // empty` is
# INVALID yq — Go yq treats `empty` as a yaml-path lexer token, not a jq
# builtin. The bug existed in post-commit-template-lint.sh for ages and
# silently disabled SSOT anti-patterns; the validator inherited it and
# r3 surfaced it. Fix: use `// ""` (jq-compatible across both yq variants).
# CR-in-CI #743 r5 minor: track whether the template provided the list
# at all. Empty `anti_patterns: []` from SSOT must be respected; the
# fallback should only apply when yq unavailable OR template absent —
# not when the template intentionally resolves to no patterns.
ANTI_PATTERNS=""
ANTI_PATTERNS_FROM_TEMPLATE=0
if command -v yq >/dev/null 2>&1 && [ -f "$TEMPLATE" ]; then
	ANTI_PATTERNS_FROM_TEMPLATE=1
	ANTI_PATTERNS=$(yq -r '.anti_patterns[] | .regex // .pattern // ""' "$TEMPLATE") || {
		echo "error: failed to parse $TEMPLATE (yq rc=$?) — anti_patterns" >&2
		exit 2
	}
	# yq emits "null" literal on some versions when field missing — filter
	# both literal "null" and empty lines (BSD grep rejects empty alternation).
	ANTI_PATTERNS=$(printf '%s\n' "$ANTI_PATTERNS" | awk 'NF && $0 != "null"')
fi
if [ "$ANTI_PATTERNS_FROM_TEMPLATE" -eq 0 ]; then
	ANTI_PATTERNS="^wip$
^misc
^stuff
^fixed bug$
^updated files$"
fi
while IFS= read -r pat; do
	[ -z "$pat" ] && continue
	# CR-in-CI #743 r3 major: capture grep rc to distinguish no-match
	# (rc=1, expected) from invalid-regex (rc≥2, hard error). Without
	# this, a corrupted anti_patterns.regex in commit-template.yml would
	# silently bypass validation. POSIX grep: 0=match, 1=no-match, ≥2=error.
	if printf '%s' "$SUBJECT" | grep -qiE "$pat"; then
		warnings="${warnings}
  • Subject matches anti-pattern: /$pat/"
	else
		grep_rc=$?
		if [ "$grep_rc" -gt 1 ]; then
			echo "error: invalid anti-pattern regex in $TEMPLATE: /$pat/ (grep rc=$grep_rc)" >&2
			exit 2
		fi
	fi
done <<<"$ANTI_PATTERNS"

# Co-Authored-By trailer required for Claude-assisted commits. Caller-side
# heuristic (.claude/-touched) lives in post-commit-template-lint.sh; this
# validator just checks presence/absence and surfaces it as a warning so
# the caller can decide whether it's required.
if ! printf '%s' "$MSG" | grep -q 'Co-Authored-By:'; then
	warnings="${warnings}
  • Missing Co-Authored-By trailer (mandatory for Claude-assisted commits)"
fi

if [ -n "$warnings" ]; then
	echo "commit-message validation drift:$warnings" >&2
	exit 1
fi

exit 0
