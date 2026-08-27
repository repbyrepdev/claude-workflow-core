#!/bin/bash
set -uo pipefail
# event: PreToolUse
# enforcement: deny
# auto-register: true
#
# Refuse a write whose path resolves, THROUGH A SYMLINK, into something the
# write plainly did not mean to touch. Two incidents in one session, same
# shape both times:
#
#   1. `printf '...' > "$dir/brew"` where $dir was /opt/homebrew/bin. The
#      entry there is a symlink into the Cellar, so the redirect followed it
#      and replaced the real brew binary with a 3-line stub. Nothing warned;
#      brew simply went silent afterwards.
#
#   2. A bats test doing `cat > .claude/scripts/cr/thread-reply.sh` to build a
#      stub. `.claude/scripts` is a SYMLINK to the repo's real scripts/ dir,
#      so the fixture write went straight through and replaced a 292-line
#      production helper. The test then "passed" against its own stub.
#
# Both are invisible at the time — the write succeeds, and the damage shows up
# later as something inexplicably broken. That is precisely the class epic
# #2544 exists to make mechanical.
#
# WHAT IS REFUSED
#   A. Any write under `.claude/{scripts,hooks,_lib}/` reached by a RELATIVE
#      path. Those three are symlinks to the production dirs, so a relative
#      write from the repo root always lands on production. A test that wants
#      a fixture must write under its own $TEST_TMP (an absolute path outside
#      the repo), which stays allowed.
#   B. Any write landing in a PATH directory outside this repo — /usr/bin,
#      /usr/local/bin, /opt/homebrew/bin and friends. Installing a tool is a
#      deliberate act that belongs in a package manager, not a redirect.
#
# Read-only use of those paths is untouched; only writes are inspected.
#
# Bypass (audit-logged): SYMLINK_WRITE_GUARD_SKIP=1 <command>

HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
LIB_DENY="${HOOK_DIR}/../_lib/hook-deny.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi

PAYLOAD=$(cat 2>/dev/null) || PAYLOAD=""
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)
FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

# Inline bypass, matching the sibling guards' shape.
case "$CMD" in
*SYMLINK_WRITE_GUARD_SKIP=1*) exit 0 ;;
esac
[ "${SYMLINK_WRITE_GUARD_SKIP:-0}" = "1" ] && exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""

# Collect candidate write targets.
TARGETS=""
if [ -n "$FILE_PATH" ]; then
	TARGETS="$FILE_PATH"
fi
if [ -n "$CMD" ]; then
	# `> path`, `>> path`, and `tee [-a] path`. Deliberately narrow: these two
	# shapes cover both observed incidents, and a broader parser would produce
	# false denials on ordinary commands — a guard nobody trusts gets skipped.
	REDIRECTS=$(printf '%s\n' "$CMD" |
		grep -oE '>>?[[:space:]]*"?[^ "|;&)]+' 2>/dev/null |
		sed -E 's/^>>?[[:space:]]*"?//' || true)
	TEES=$(printf '%s\n' "$CMD" |
		grep -oE '\btee[[:space:]]+(-a[[:space:]]+)?"?[^ "|;&)]+' 2>/dev/null |
		sed -E 's/^tee[[:space:]]+(-a[[:space:]]+)?"?//' || true)
	TARGETS=$(printf '%s\n%s\n%s\n' "$TARGETS" "$REDIRECTS" "$TEES")
fi
[ -n "$(printf '%s' "$TARGETS" | tr -d '[:space:]')" ] || exit 0

_deny_symlink() { # $1 = path, $2 = why
	hook_deny "symlink-write-guard" "REFUSED a write to '$1' — $2

This is the shape that replaced /opt/homebrew/bin/brew with a 3-line stub, and
that replaced a 292-line production helper with a test fixture. Both succeeded
silently; the damage surfaced much later.

If this is a TEST FIXTURE: write it under your \$TEST_TMP (an absolute path
outside the repo), then cd into that fixture BEFORE creating any .claude/
subdirectory. The symlinked dirs only resolve to production when reached by a
relative path from the repo.

If you really mean to change the production file: edit the real path directly
(scripts/..., hooks/..., _lib/...), so the change is visible in the diff.

Bypass (audit-logged): SYMLINK_WRITE_GUARD_SKIP=1 <command>"
}

while IFS= read -r t; do
	[ -n "$t" ] || continue
	# Strip a leading ./ for matching.
	t_norm="${t#./}"

	# --- Rule A: the repo's symlinked .claude dirs, reached relatively ------
	case "$t_norm" in
	/*) ;; # absolute — handled by rule B below
	*.claude/scripts/* | *.claude/hooks/* | *.claude/_lib/*)
		_deny_symlink "$t" \
			".claude/{scripts,hooks,_lib} are SYMLINKS to this repo's production directories, so a relative write there lands on the real file"
		;;
	esac

	# --- Rule B: a PATH directory outside this repo -------------------------
	case "$t_norm" in
	/*)
		t_dir=$(dirname "$t_norm")
		# Only care about existing dirs; a write into a new tree is not the
		# hazard this guard is about.
		[ -d "$t_dir" ] || continue
		t_real=$(cd "$t_dir" 2>/dev/null && pwd -P) || continue
		# Inside the repo is fine — that is ordinary work.
		if [ -n "$REPO_ROOT" ]; then
			case "$t_real/" in
			"$REPO_ROOT"/*) continue ;;
			esac
		fi
		# A temp dir is the sanctioned place for fixtures.
		case "$t_real" in
		/tmp/* | /private/tmp/* | /var/folders/*) continue ;;
		esac
		# Is it on PATH? Then it holds executables something else depends on.
		_on_path=0
		_old_ifs=$IFS
		IFS=:
		for d in $PATH; do
			[ -n "$d" ] || continue
			d_real=$(cd "$d" 2>/dev/null && pwd -P) || continue
			[ "$d_real" = "$t_real" ] && _on_path=1 && break
		done
		IFS=$_old_ifs
		if [ "$_on_path" = "1" ]; then
			_deny_symlink "$t" \
				"'$t_real' is on \$PATH and outside this repo — writing there replaces a binary other tools resolve"
		fi
		;;
	esac
done <<EOF
$TARGETS
EOF

exit 0
