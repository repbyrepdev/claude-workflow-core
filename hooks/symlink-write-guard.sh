#!/bin/bash
set -uo pipefail
# event: PreToolUse
# enforcement: deny
# auto-register: true
#
# Refuse a write whose path resolves, THROUGH A SYMLINK, into something the
# write plainly did not mean to touch. Two incidents in one session, same
# shape both times, both silent:
#
#   1. `printf '...' > "$dir/brew"` with $dir=/opt/homebrew/bin. That entry is
#      a symlink into the Cellar, so the redirect followed it and replaced the
#      real brew binary with a 3-line stub. brew simply went quiet afterwards.
#
#   2. A bats test doing `cat > .claude/scripts/cr/thread-reply.sh` to build a
#      fixture. `.claude/scripts` is a SYMLINK to this repo's scripts/ dir, so
#      the fixture write replaced a production helper — and the test then
#      passed against its own stub.
#
# WHAT IS ACTUALLY PARSED — stated precisely, because the first version of
# this header overstated it and phase-1 review caught that the guard let both
# of its own cited incidents through by their real routes:
#
#   Inspected:  `> path`, `>> path`, `N> path`, `tee [-a] path`, `dd of=path`,
#               and the Write/Edit tool's `file_path`.
#   NOT parsed: cp, mv, install, ln, `sed -i`, and any write performed inside
#               a script this hook cannot see. Those are real gaps, listed so
#               nobody assumes coverage that is not here.
#
# WHAT IS REFUSED, of the shapes above:
#   A. A write landing under `.claude/{scripts,hooks,_lib}/` INSIDE this repo
#      — whether written relatively, absolutely, or through $PWD. Those three
#      are symlinks to the production dirs. A fixture under a temp dir is
#      allowed; that is the sanctioned place for one.
#   B. A write landing in a PATH directory outside this repo — /usr/bin,
#      /usr/local/bin, /opt/homebrew/bin. Installing a tool is a job for a
#      package manager, not a redirect.
#
# Reads are untouched; only writes are inspected.
#
# Bypass: SYMLINK_WRITE_GUARD_SKIP=1 as a COMMAND PREFIX (or exported). It is
# genuinely audit-logged — see _audit_bypass. The token is anchored, because
# an unanchored match meant `echo SYMLINK_WRITE_GUARD_SKIP=1 > production.sh`
# disabled the guard using the very text it was about to write.

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

# Fail CLOSED on unreadable input, matching the sibling gate
# (pre-merge-cr-comments-gate.sh), whose own comment records that silently
# coercing a bad payload to {} hid real bugs. The first version of this file
# exited 0 on all three of these, which quietly disabled the guard.
PAYLOAD=$(cat 2>/dev/null) || hook_deny "symlink-write-guard" "stdin read failed — failing closed"
[ -n "$PAYLOAD" ] || hook_deny "symlink-write-guard" "empty hook payload — failing closed"
command -v jq >/dev/null 2>&1 ||
	hook_deny "symlink-write-guard" "jq not installed — this guard cannot parse its payload without it, and silently allowing writes is how both incidents happened. Install jq."
printf '%s' "$PAYLOAD" | jq -e . >/dev/null 2>&1 ||
	hook_deny "symlink-write-guard" "hook payload is not valid JSON — failing closed"

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""')
FILE_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // ""')
CWD=$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""')
[ -n "$CWD" ] || CWD=$PWD

# Returns NON-ZERO when the audit row could not be written. The bypass is
# sold as "genuinely audit-logged"; if the row does not land, that sentence is
# false and the escape hatch becomes an untracked hole. An unwritable log is
# rare and easy to fix, so refusing is cheap — silently allowing is not.
_audit_bypass() {
	local root reason log
	root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$CWD"
	reason=${SYMLINK_WRITE_GUARD_SKIP_REASON:-unstated}
	reason=${reason//\\/\\\\}
	reason=${reason//\"/\\\"}
	reason=${reason//$'\n'/ }
	log="$root/.claude/logs/pipeline-skip.jsonl"
	mkdir -p "$root/.claude/logs" 2>/dev/null || return 1
	printf '{"ts":"%s","kind":"symlink-write-guard-skip","reason":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" \
		>>"$log" 2>/dev/null || return 1
}

_bypass_or_deny() {
	_audit_bypass && exit 0
	hook_deny "symlink-write-guard" "bypass REFUSED — the audit row could not be written to .claude/logs/pipeline-skip.jsonl, and an unlogged bypass is not a bypass this guard offers. Fix the log path (check permissions on .claude/logs), then retry."
}

# Anchored to the START of the command, not to any segment boundary. Accepting
# it after `;`, `&` or `|` meant the token could sit AFTER the write it was
# meant to authorise:
#
#     cat > .claude/scripts/cr/x.sh; SYMLINK_WRITE_GUARD_SKIP=1 true
#
# The guard sees one CMD string and cannot attribute a per-segment prefix to a
# particular redirect, so the only honest reading is "the whole command is
# bypassed, and the operator said so up front".
if printf '%s' "$CMD" | grep -qE '^[[:space:]]*SYMLINK_WRITE_GUARD_SKIP=1[[:space:]]'; then
	_bypass_or_deny
fi
if [ "${SYMLINK_WRITE_GUARD_SKIP:-0}" = "1" ]; then
	_bypass_or_deny
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""

# --- collect write targets ------------------------------------------------
TARGETS=$FILE_PATH
# Every extractor below used `|| true`, which maps ANY failure — a missing
# grep, a broken sed, an OOM — onto "no targets found", and the empty-TARGETS
# check further down then EXITS 0. A guard whose parser silently disappearing
# means "allow" is the fail-open shape this whole file exists to remove.
#
# grep's rc 1 is the one benign non-zero: it means "no match", which really is
# "no target". Anything else, from either tool, denies.
#
# _extract RETURNS a status; it must NOT call hook_deny itself. Each call site
# is a command substitution, so hook_deny would print its JSON into the
# captured value and its `exit 0` would end only the subshell — the deny would
# be swallowed and assigned to a variable, which is worse than the `|| true`
# it replaces. The caller checks the rc and denies in the parent shell.
_extract() { # $1 = grep -E pattern, $2 = sed -E script; echoes matches, rc 0/9
	local out rc=0
	out=$(printf '%s\n' "$CMD" | grep -oE "$1" 2>/dev/null) || rc=$?
	if [ "$rc" -eq 1 ]; then
		return 0 # no match — a real, empty answer
	elif [ "$rc" -ne 0 ]; then
		return 9 # grep itself failed
	fi
	[ -n "$out" ] || return 0
	printf '%s\n' "$out" | sed -E "$2" || return 9
}
_ext_deny() { # $1 = which extractor, $2 = rc
	hook_deny "symlink-write-guard" "target extraction failed ($1, rc=$2) — failing closed rather than treating an unparsed command as having no write targets"
}
if [ -n "$CMD" ]; then
	# Strips a leading double OR single quote. Single quotes were not handled,
	# so `> '/opt/homebrew/bin/brew'` kept its apostrophe, failed the absolute
	# test, and skipped Rule B entirely — incident #1 with different quoting.
	# rc checked OUTSIDE each substitution — `$(...)` propagates the function
	# status to `||`, so the deny runs in this shell and its JSON reaches
	# stdout instead of a variable.
	_rc=0
	REDIRECTS=$(_extract \
		'[0-9]?>>?[[:space:]]*["'"'"']?[^ "'"'"'|;&)]+' \
		's/^[0-9]?>>?[[:space:]]*["'"'"']?//') || _rc=$?
	[ "$_rc" -eq 0 ] || _ext_deny "redirects" "$_rc"
	# EVERY tee operand, not just the first. `tee` takes a LIST of files, so
	# `tee /tmp/safe .claude/scripts/cr/x.sh` checked only /tmp/safe and let
	# the protected target through — the guard reported on a decoy. `tee --`
	# was worse: it recorded `--` and dropped every real operand.
	#
	# Grab the whole tee segment up to the next shell separator, then split it
	# into words and keep the non-flag ones. `--` ends option parsing, so
	# everything after it is a filename even if it starts with a dash.
	#
	# A QUOTED separator defeats the segment scan: in
	#     tee '/tmp/safe|decoy' <protected-path>
	# the `|` is DATA, but `[^|;&]*` stops there and the protected operand is
	# never seen. Properly fixing that needs a shell tokenizer, which is not
	# something a regex hook should pretend to be — so the ambiguous case is
	# REFUSED instead. Fail-closed on "I cannot parse this" is the contract
	# the rest of this file already keeps; quietly parsing half a command is
	# how the two incidents in the header happened.
	# Scoped to the tee CLAUSE: the quoted span must begin in the operand
	# region, not merely somewhere in the command. The first cut asked "does
	# the command contain tee, and separately contain a quoted separator" —
	# which refused any long text argument that happened to mention both, and
	# blocked this very fix's own audit record twice. A guard that fires on
	# prose gets bypassed habitually, and then it guards nothing.
	if printf '%s' "$CMD" |
		grep -qE '\btee[[:space:]]+([^"'"'"'|;&]*[[:space:]]+)*("[^"]*[|;&][^"]*"|'"'"'[^'"'"']*[|;&][^'"'"']*'"'"')'; then
		hook_deny "symlink-write-guard" 'REFUSED: a tee clause contains a QUOTED shell separator, so this hook cannot tell which words are operands and which are pipeline boundaries — and guessing is how a protected path gets skipped. Rewrite without the quoted separator, or use the audited bypass:
  SYMLINK_WRITE_GUARD_SKIP=1 SYMLINK_WRITE_GUARD_SKIP_REASON="why" <command>'
	fi
	_rc=0
	_tee_seg=$(_extract '\btee[[:space:]]+[^|;&]*' 's/^tee[[:space:]]+//') || _rc=$?
	[ "$_rc" -eq 0 ] || _ext_deny "tee" "$_rc"
	TEES=""
	if [ -n "$_tee_seg" ]; then
		_past_ddash=0
		# shellcheck disable=SC2086 # deliberate word-splitting of the operand list
		for _w in $_tee_seg; do
			if [ "$_past_ddash" = "0" ]; then
				case "$_w" in
				--)
					_past_ddash=1
					continue
					;;
				-*) continue ;;
				esac
			fi
			_w=${_w%\"}
			_w=${_w#\"}
			_w=${_w%\'}
			_w=${_w#\'}
			TEES=$(printf '%s\n%s' "$TEES" "$_w")
		done
	fi
	# `dd of=path` writes through a symlink exactly like a redirect does, and
	# it was in the documented-gaps list purely because nobody had written the
	# two lines. cp/mv/install/ln/sed -i stay listed as gaps: each needs
	# argument parsing this hook has no business attempting.
	_rc=0
	DDS=$(_extract \
		'\bdd[[:space:]]+([^|;&]*[[:space:]])?of=["'"'"']?[^ "'"'"'|;&)]+' \
		's/^.*of=["'"'"']?//') || _rc=$?
	[ "$_rc" -eq 0 ] || _ext_deny "dd" "$_rc"
	TARGETS=$(printf '%s\n%s\n%s\n%s\n' "$TARGETS" "$REDIRECTS" "$TEES" "$DDS")
fi
[ -n "$(printf '%s' "$TARGETS" | tr -d '[:space:]')" ] || exit 0

_deny_symlink() { # $1 = path, $2 = why
	hook_deny "symlink-write-guard" "REFUSED a write to '$1' — $2

This is the shape that replaced /opt/homebrew/bin/brew with a stub, and that
replaced a production helper with a test fixture. Both succeeded silently; the
damage surfaced much later.

If this is a TEST FIXTURE: build the path from your \$TEST_TMP so it lands in
a temp dir — e.g. \"\\\$TEST_TMP/.claude/scripts/x.sh\". A temp path is allowed.
Writing '.claude/scripts/...' relative to the repo is refused NO MATTER the
cwd, because the guard cannot tell a cd'd shell from an un-cd'd one.

If you really mean to change the production file: edit the real path
(scripts/..., hooks/..., _lib/...), so the change shows up in the diff.

Bypass (audit-logged to .claude/logs/pipeline-skip.jsonl):
  SYMLINK_WRITE_GUARD_SKIP=1 SYMLINK_WRITE_GUARD_SKIP_REASON=\"why\" <command>"
}

# Does an absolute path land inside one of THIS repo's symlinked .claude dirs?
# Resolving the parent is what catches the absolute form: `pwd -P` follows the
# symlink to <repo>/scripts, which the earlier version then treated as
# "inside the repo, therefore fine" — permitting the exact damage it exists to
# stop, and permitting it for Write/Edit specifically, since those tools only
# ever send absolute paths.
_lands_in_repo_symlink_dir() { # $1 = absolute path
	local d real
	# The MARKER is checked before the parent-exists test, because the
	# resolved-parent path below cannot see a directory that does not exist
	# yet. An absolute write to `<repo>/.claude/scripts/newdir/x.sh` failed
	# `[ -d "$d" ]`, returned 1, and was ALLOWED — and the relative case arm
	# never got a look at it, since a leading `/` matches the `/*` arm first.
	# Creating a subdirectory is the ordinary way a fixture gets built, so
	# that was the hole open on the most likely route.
	case "$1" in
	*/.claude/scripts/* | */.claude/hooks/* | */.claude/_lib/*)
		[ -n "$REPO_ROOT" ] || return 1
		case "$1" in
		"$REPO_ROOT"/*) return 0 ;;
		esac
		;;
	esac
	d=$(dirname "$1")
	[ -d "$d" ] || return 1
	real=$(cd "$d" 2>/dev/null && pwd -P) || return 1
	[ -n "$REPO_ROOT" ] || return 1
	case "$real/" in
	"$REPO_ROOT"/scripts/* | "$REPO_ROOT"/scripts/ | \
		"$REPO_ROOT"/hooks/* | "$REPO_ROOT"/hooks/ | \
		"$REPO_ROOT"/_lib/* | "$REPO_ROOT"/_lib/)
		# It resolves into production. Only refuse when the path was written
		# THROUGH the .claude symlink — a direct `scripts/foo.sh` edit is
		# ordinary work and must stay allowed.
		case "$1" in
		*/.claude/scripts/* | */.claude/hooks/* | */.claude/_lib/*) return 0 ;;
		esac
		;;
	esac
	return 1
}

while IFS= read -r t; do
	[ -n "$t" ] || continue
	t_norm="${t#./}"

	# A target built from an unexpanded variable cannot be resolved here. The
	# common case by far is a fixture path ($TEST_TMP/...), and refusing those
	# would deny the remedy this guard prescribes — after which it gets
	# bypassed habitually and protects nothing. Left to Rule B's realpath
	# check, which sees through nothing, so this is a known bound.
	case "$t_norm" in
	'$'* | '"$'* | "'\$"*) continue ;;
	esac

	case "$t_norm" in
	/*)
		# Absolute: does it land in the repo's symlinked dirs?
		if _lands_in_repo_symlink_dir "$t_norm"; then
			_deny_symlink "$t" \
				".claude/{scripts,hooks,_lib} are SYMLINKS to this repo's production directories — this absolute path resolves into one of them"
		fi
		;;
	.claude/scripts/* | .claude/hooks/* | .claude/_lib/* | \
		*/.claude/scripts/* | */.claude/hooks/* | */.claude/_lib/*)
		# Relative through the symlink. Refused regardless of cwd: the hook
		# cannot verify a cd that happens inside the same command, and the
		# fixture remedy (an absolute temp path) is unaffected.
		#
		# Anchored to a path boundary — leading, or after a `/`. The bare
		# `*.claude/...` form also matched `notes.claude/scripts/x`, an
		# ordinary directory that merely ENDS in ".claude" and is nobody's
		# symlink. A guard that refuses innocent writes gets bypassed
		# habitually, and then it is not guarding anything.
		_deny_symlink "$t" \
			".claude/{scripts,hooks,_lib} are SYMLINKS to this repo's production directories, so a relative write there lands on the real file"
		;;
	esac

	# --- Rule B: a PATH directory outside this repo -------------------------
	case "$t_norm" in
	/*)
		t_dir=$(dirname "$t_norm")
		[ -d "$t_dir" ] || continue
		t_real=$(cd "$t_dir" 2>/dev/null && pwd -P) || continue
		if [ -n "$REPO_ROOT" ]; then
			case "$t_real/" in
			"$REPO_ROOT"/*) continue ;;
			esac
		fi
		case "$t_real" in
		/tmp/* | /private/tmp/* | /var/folders/*) continue ;;
		esac
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
