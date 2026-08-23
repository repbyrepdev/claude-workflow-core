#!/usr/bin/env bash
set -u
# NB: sourced lib → `set -u` (nounset) ONLY, intentionally NOT `set -euo
# pipefail`. -e/-o pipefail would mutate the CALLERS' errexit. Matches the
# sourced-lib convention of _lib/cr-phase2-coverage.sh.
#
# v0.34.122 (#2536): SSOT for resolving the plugin cache, and for the
# VERSION-AGNOSTIC hook-launcher layout that replaces version-pinned absolute
# paths in the operator's global settings.json.
#
# THE BUG THIS KILLS
#   register-hook.sh + hooks/install-hooks.sh both baked an ABSOLUTE,
#   version-pinned path into ~/.claude/settings.json
#   (.../claude-workflow-core/0.34.83/hooks/foo.sh). When the cache advanced
#   and GC pruned the old version dir, all 58 registered hooks 404'd — and
#   before that they silently ran a stale copy. Observed live on 2026-08-22:
#   58 refs pinned to 0.34.108 while the repo was 0.34.121, which is what made
#   the phase-1 guard execute a build predating its own escape hatches (#2531).
#
# WHY NOT ${CLAUDE_PLUGIN_ROOT}
#   It is NOT expanded in settings.json — it HARD-THROWS. Verified in the
#   Claude Code 2.1.239 binary, whose own error text reads: "This variable is
#   only available in hooks defined in a plugin's hooks/hooks.json file, not in
#   settings.json." It works only in a plugin manifest, never here.
#
# WHY NOT A BARE `current` SYMLINK
#   It still dangles. GC prunes version DIRS; a symlink pointing into a pruned
#   dir survives as a broken link, and because the self-healer would itself be
#   registered THROUGH that symlink, the healer could never run to repair it.
#   That is the bootstrap paradox that sank the reverted first attempt.
#
# THE MECHANISM
#   A stable launcher dir OUTSIDE the versioned cache holds one tiny forwarder
#   per hook. Each forwarder re-resolves, AT RUN TIME, the newest cache version
#   that actually contains ITS OWN hook file, then execs it. Nothing is pinned,
#   so nothing can dangle; a `/reload` "feeds everywhere" with no migration. A
#   half-populated new version cannot break a hook it does not yet ship —
#   resolution simply falls back to the newest version that has it.

# Root of the versioned plugin cache. Env override exists for tests.
# SSOT NOTE: the generated launcher (pcr_launcher_body, line ~141) is standalone
# — it cannot source this lib — so it MUST repeat this exact default. The two
# literals are drift-guarded by cache-root-default-parity.bats, which greps both
# and asserts equality (CR-in-CI #2540). Change one → change the other.
pcr_cache_root() {
	printf '%s' "${PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
}

# Stable, version-agnostic launcher dir. Deliberately OUTSIDE the plugin cache:
# Claude Code owns the cache and may prune or repopulate it wholesale, and
# anything we write inside it is subject to that GC. This path is ours.
pcr_launcher_dir() {
	printf '%s' "${PLUGIN_LAUNCHER_DIR:-$HOME/.claude/plugin-hooks/claude-workflow-core}"
}

# pcr_newest_complete <cache_root> [probe_rel_path ...]
#   Echo the newest semver version dir under <cache_root> that contains EVERY
#   probe path. With no probes, "contains" degrades to "is a semver dir".
#   rc 1 (and no output) when nothing qualifies.
#
# The probe list is the completeness guard #2536 asks for: never resolve to a
# cache dir that does not actually hold the file we are about to run. Sorting
# is `sort -V` so 0.10.0 correctly beats 0.9.5 (a lexical sort inverts them).
pcr_newest_complete() {
	local root=$1
	shift
	[ -d "$root" ] || return 1
	local candidates name probe ok
	# Newest first; take the first that passes every probe.
	candidates=$(
		for entry in "$root"/*; do
			name=${entry##*/}
			[ -d "$entry" ] || continue
			[[ $name =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
			printf '%s\n' "$name"
		done 2>/dev/null | sort -V -r
	)
	[ -n "$candidates" ] || return 1
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		ok=1
		for probe in "$@"; do
			# -x, not -e: every caller probes a hook it intends to EXECUTE, and
			# `-e` is satisfied by a directory or a non-executable file. Keeping
			# this in step with the generated launcher's own probe matters —
			# otherwise --verify can report a version the launcher would skip.
			[ -x "$root/$name/$probe" ] || {
				ok=0
				break
			}
		done
		if [ "$ok" -eq 1 ]; then
			printf '%s' "$root/$name"
			return 0
		fi
	done <<<"$candidates"
	return 1
}

# pcr_launcher_path <hook_basename>  → absolute path of that hook's launcher.
pcr_launcher_path() {
	printf '%s/%s' "$(pcr_launcher_dir)" "$1"
}

# pcr_launcher_body <hook_basename>
#   Emit the forwarder script for one hook on stdout.
#
# Contract the body must honour:
#   - resolve at RUN TIME (never bake a version)
#   - probe for its OWN hook file so a partial cache version is skipped
#   - forward argv AND stdin untouched (hooks are fed a JSON payload on stdin)
#   - forward the real hook's exit status verbatim — hook protocol encodes
#     deny/allow in the status and stdout, so swallowing either breaks gating
#   - fail OPEN (rc 0, warn on stderr) when no version can be resolved: a hook
#     that cannot be found must not wedge the session. This mirrors every other
#     "can't resolve" path in this plugin, which allows the call and warns.
pcr_launcher_body() {
	local base=$1
	# QUOTED heredoc + @@HOOK@@ placeholder: the body is emitted verbatim with
	# zero shell expansion, so none of the launcher's own $-syntax needs
	# escaping. (An unquoted heredoc here needed four levels of backslash
	# nesting and was a latent corruption bug.)
	local tmpl
	tmpl=$(
		cat <<'LAUNCHER'
#!/usr/bin/env bash
set -uo pipefail
# GENERATED by scripts/install-hook-launchers.sh (#2536) — DO NOT EDIT.
# Version-agnostic launcher for hooks/@@HOOK@@.
#
# Resolves, AT RUN TIME, the newest plugin-cache version that actually contains
# this hook, then execs it. No version is baked in, so a cache bump + GC can
# never leave this dangling — which is exactly what made the old version-pinned
# settings.json entries 404 en masse (#2536).
# This default MUST byte-match pcr_cache_root() in the lib above — a standalone
# launcher can't source it. cache-root-default-parity.bats fails if they drift.
_root="${PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
_best=""
if [ -d "$_root" ]; then
	# Newest-first; take the first version that actually ships this hook, so a
	# half-populated new cache dir cannot break a hook it does not yet contain.
	# sort -V so 0.10.0 beats 0.9.5 (a lexical sort inverts that).
	_vers=$(
		for _d in "$_root"/*/; do
			_n=${_d%/}
			_n=${_n##*/}
			# The leading `(` is REQUIRED, not style: bash 3.2 (which macOS
			# still ships as /bin/bash) mis-parses a paren-less case pattern
			# inside $( ) and dies with "syntax error near unexpected token
			# ';;'". shellcheck does NOT catch this. Balanced form parses on
			# 3.2 and 5.x alike.
			# Reject arms constrain the accepted set to strict X.Y.Z so it
			# matches pcr_newest_complete's `^[0-9]+(\.[0-9]+){2}$` — not the
			# loose final glob alone, which admitted `9 rm.0.0`, `1.2.3-rc1`
			# (non-[0-9.]), AND — because `*` also matches `.` — `0.34.121.1`,
			# `1.2.3.` and `1..2.3` (CR-in-CI #2540: launcher glob must not
			# resolve a version the resolver regex rejects). Dotfiles can't
			# reach here: `"$_root"/*/` never enumerates a leading-dot dir.
			case "$_n" in
			([0-9]*[!0-9.]*) ;; # a non-[0-9.] char (1.2.3-rc1)
			(*.*.*.*) ;;        # 4+ components — not X.Y.Z (0.34.121.1)
			(*..*) ;;           # empty component (1..2.3)
			(*.) ;;             # trailing dot (1.2.3.)
			([0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$_n" ;;
			esac
		done 2>/dev/null | sort -V -r
	)
	# QUOTED read loop, not `for _v in $_vers`: an unquoted expansion word-splits
	# on IFS and glob-expands, so a version dir containing a space or `*` is
	# split into bogus candidates or matched against the cwd.
	while IFS= read -r _v; do
		[ -n "$_v" ] || continue
		# -x, NOT -f: this path is about to be exec'd. `-f` passes for a
		# non-executable file, which halts the search on a version that cannot
		# run, skips the fail-open branch below, and makes exec die with 126 —
		# the exact opposite of the fail-open contract documented above. A cache
		# copy that drops the exec bit is a real case; install-hook-launchers.sh
		# has to chmod 755 its own launchers for the same reason.
		if [ -x "$_root/$_v/hooks/@@HOOK@@" ]; then
			_best="$_root/$_v"
			break
		fi
	done <<VERS
$_vers
VERS
fi
if [ -z "$_best" ]; then
	# Fail OPEN: a hook we cannot locate must never wedge the session. Mirrors
	# every other unresolvable path in this plugin (warn on stderr, allow).
	echo "@@HOOK@@: no plugin-cache version under $_root contains hooks/@@HOOK@@ — allowing call (fail-open)" >&2
	exit 0
fi
# stdin is inherited (hooks read a JSON payload from it) and exec preserves the
# real hook's exit status verbatim — the hook protocol encodes deny/allow in
# status + stdout, so neither may be swallowed.
# ${1+"$@"}, not "$@": hooks are invoked with NO argv (payload is on stdin), and
# an empty "$@" under `set -u` aborts as an unbound variable on bash < 4.4 —
# incl. the 3.2 macOS ships as /bin/bash — so the launcher would exit before
# exec and every hook would silently no-op (CR-in-CI #2540). ${1+…} expands to
# nothing when unset, so it is safe empty and forwards args verbatim when present.
exec "$_best/hooks/@@HOOK@@" ${1+"$@"}
LAUNCHER
	)
	printf '%s\n' "${tmpl//@@HOOK@@/$base}"
}
