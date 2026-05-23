#!/bin/bash
set -euo pipefail
# v4.21 (#520): compute which area:* labels *would* apply to a file set
# based on .github/labeler.yml globs. READ-ONLY — prints matching label
# names to stdout. No PR mutation.
#
# Shares glob-match semantics with .claude/hooks/pr-labeler.sh (the
# actual label-applier) — both use the same Python matcher emulating
# actions/labeler@v5 rules. This script is the "compute without apply"
# front door for ad-hoc analysis.
#
# Usage:
#   .claude/scripts/labels/apply-area.sh <pr-num>
#   .claude/scripts/labels/apply-area.sh --files <f1> <f2> ...
#   .claude/scripts/labels/apply-area.sh --diff-range <BASE..HEAD>

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || { cd "$SCRIPT_DIR/../../.." && pwd; })
# shellcheck source=../_common.sh
source "$SCRIPT_DIR/../_common.sh"

LABELER_YML="$REPO_ROOT/.github/labeler.yml"
[ -f "$LABELER_YML" ] || scm_fail ".github/labeler.yml missing"

MODE=""
PR=""
RANGE=""
FILES_ARR=()

while [ $# -gt 0 ]; do
	case "$1" in
	--files)
		MODE="files"
		shift
		while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
			FILES_ARR+=("$1")
			shift
		done
		;;
	--diff-range)
		MODE="range"
		RANGE="${2:?--diff-range requires a value}"
		shift 2
		;;
	-h | --help)
		grep '^#' "$0" | sed 's/^# \?//'
		exit 0
		;;
	*)
		if [ -z "$MODE" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
			MODE="pr"
			PR="$1"
			shift
		else
			scm_fail "unknown arg: $1"
		fi
		;;
	esac
done

# Gather the file list from whichever source was requested.
case "$MODE" in
pr)
	CHANGED=$(gh pr diff "$PR" --name-only 2>&1) || scm_fail "gh pr diff failed: $CHANGED"
	;;
range)
	CHANGED=$(git diff --name-only "$RANGE" 2>&1) || scm_fail "git diff failed: $CHANGED"
	;;
files)
	# Bash 3.2 + set -u: `${FILES_ARR[@]}` with zero elements is unbound.
	# Guard the empty case with a clear error instead of a bash diagnostic.
	[ "${#FILES_ARR[@]}" -gt 0 ] || scm_fail "--files requires at least one file"
	CHANGED=$(printf '%s\n' "${FILES_ARR[@]}")
	;;
*)
	scm_fail "usage: $0 <pr-num> | --files <f1 f2 ...> | --diff-range <range>"
	;;
esac

[ -n "$CHANGED" ] || exit 0

# Extract label → glob rules from labeler.yml (same query pr-labeler.sh uses).
if ! LABEL_RULES=$(yq -r 'to_entries | .[] | .key as $k | .value[] | .["changed-files"][]["any-glob-to-any-file"] | [$k] + . | @tsv' "$LABELER_YML" 2>&1); then
	scm_fail "yq parse of labeler.yml failed: $LABEL_RULES"
fi
# Empty LABEL_RULES = labeler.yml is malformed or schema drifted (yq ran
# but extracted nothing). Without this check, the Python matcher returns
# zero labels and consumers see "no labels matched" — indistinguishable
# from a legitimate no-match.
[ -n "$LABEL_RULES" ] || scm_fail "no rules extracted from $LABELER_YML — check schema (expected .changed-files[].any-glob-to-any-file)"

# Python matcher emulating actions/labeler@v5 glob semantics. Identical
# to the one in .claude/hooks/pr-labeler.sh — keep in sync if either changes.
# Capture via $(...) so python3's stderr surfaces on failure; piping
# directly would silently route python errors to terminal stderr while
# stdout readers (e.g., `$(apply-area.sh 520)` in scripts) see empty
# output and assume "no labels matched".
if ! OUT=$(printf '%s\n---RULES---\n%s\n' "$CHANGED" "$LABEL_RULES" | python3 -c '
import fnmatch, sys

blob = sys.stdin.read().split("---RULES---\n", 1)
if len(blob) != 2:
    sys.exit(2)
changed = [l for l in blob[0].strip().split("\n") if l]
rules = [l for l in blob[1].strip().split("\n") if l]

def matches(path, glob):
    if glob.endswith("/**"):
        return path.startswith(glob[:-3] + "/") or path == glob[:-3]
    if "/" not in glob:
        return "/" not in path and fnmatch.fnmatch(path, glob)
    g_parts = glob.split("/")
    p_parts = path.split("/")
    def match_parts(gp, pp):
        if not gp: return not pp
        if gp[0] == "**":
            for i in range(len(pp) + 1):
                if match_parts(gp[1:], pp[i:]):
                    return True
            return False
        if not pp: return False
        if fnmatch.fnmatchcase(pp[0], gp[0]):
            return match_parts(gp[1:], pp[1:])
        return False
    return match_parts(g_parts, p_parts)

wanted = set()
for line in rules:
    parts = line.split("\t")
    if len(parts) < 2: continue
    label, globs = parts[0], parts[1:]
    for path in changed:
        if any(matches(path, g) for g in globs):
            wanted.add(label)
            break

for label in sorted(wanted):
    print(label)
' 2>&1); then
	scm_fail "python3 label matcher failed: $OUT"
fi
# Guard prints on empty OUT — otherwise `printf '%s\n' ""` emits a lone
# blank line that pollutes consumers piping through `grep -v '^$'`.
# `&& ...` alone would make the script exit 1 when OUT is empty (the
# [ -n "" ] side returns 1); use an explicit if.
if [ -n "$OUT" ]; then
	printf '%s\n' "$OUT"
fi
