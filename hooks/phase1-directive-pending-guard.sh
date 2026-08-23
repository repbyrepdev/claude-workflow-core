#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Edit|Write|MultiEdit|NotebookEdit
# auto-register: true
# v0.7.1 (#23): stricter Phase 1 directive enforcement (partial #732 fix).
#
# WHY this exists: ship-pr-cycle.sh emits a Phase 1 directive ("fire 5
# parallel Agent calls") via stdout when `next` is invoked at the phase1
# stage. Today Claude can ignore that directive — summarize, stall, or
# fire Bash/Edit calls before the 5 Agents. The existing phase1-log-
# pending-gate fires AFTER agents return (forcing review-log.sh per
# agent), but there's no symmetric gate BEFORE agents fire.
#
# This hook closes the gap: when a Phase 1 round directive marker exists
# AND no Agent/Skill call has been observed yet for that round, the next
# non-Agent/Skill tool call is REFUSED with a directive-replay message.
#
# Marker location (re-uses existing ship-pr-cycle marker infrastructure):
#   .claude/.session-state/ship-cycle/<sha>.phase1-directive.txt
#   — written by ship-pr-cycle.sh `_write_phase1_directive_marker()` when
#   cmd_next emits the phase1 directive (#732 r2). Contains directive text.
#
# Cleared by ship-pr-cycle.sh `_clear_phase1_directive_marker()` when
# state advances past phase1.
#
# Bypass: PHASE1_DIRECTIVE_GUARD_SKIP=1 inline sentinel (audit-logged).

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# (#2531) LAYOUT-AGNOSTIC _lib resolution.
#
# WHAT THIS IS *NOT*: the original #2531 theory was that `$HOOK_DIR/../_lib`
# fails to resolve, silently stranding the read-only allowlist and the
# advertised PHASE1_DIRECTIVE_GUARD_SKIP bypass. That theory was DOGFOOD-
# DISPROVEN on 2026-08-22: `hooks/../_lib/cmd-anchor.sh` and
# `.claude/hooks/../_lib/cmd-anchor.sh` both exist, sourcing either defines
# `match_cmd_at_anchor`, rc=0, and every cached plugin version ships _lib/.
# The REAL cause of the observed deadlock was plugin-cache VERSION SKEW —
# ~/.claude/settings.json had all 58 hooks pinned to a cache version that
# PREDATED the escapes, so the harness executed an old copy of this file. That
# root cause is fixed by the version-agnostic registration work (#2536), not
# here.
#
# WHAT THIS *IS*: two real robustness gaps that survived that diagnosis.
#   1. Consumer layout. `$HOOK_DIR/../_lib` is correct in the plugin, where
#      `.claude/hooks` + `.claude/_lib` are symlinks to the repo-root dirs. A
#      real consumer mirrors hooks into `.claude/hooks/` with `_lib` at
#      `.claude/_lib/` — the same relative hop — but a consumer that installs
#      hooks anywhere else has no second candidate. Try both explicitly.
#   2. SILENT degradation. When cmd-anchor did not load, the entire read-only
#      allowlist was skipped by a bare `declare -f` test with NO signal, so the
#      guard silently became far stricter than documented and the operator saw
#      an inexplicable deny. Name the failure instead.
# NB: candidates are HOOK_DIR-relative ONLY. REPO_ROOT is deliberately not
# consulted — it is not resolved until further down this file (the git
# rev-parse block), so a `$REPO_ROOT/.claude/_lib` candidate here would be a
# dead probe against `/` on every invocation.
#   ../_lib     → plugin repo (hooks/../_lib) AND the standard consumer mirror
#                 (.claude/hooks/../_lib = .claude/_lib)
#   ../../_lib  → a consumer that installs hooks one level deeper
_resolve_guard_lib() {
	local rel=$1 c
	for c in "$HOOK_DIR/../_lib/$rel" "$HOOK_DIR/../../_lib/$rel"; do
		[ -f "$c" ] && {
			printf '%s' "$c"
			return 0
		}
	done
	return 1
}

if LIB_DENY=$(_resolve_guard_lib hook-deny.sh); then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi
if LIB_SENTINEL=$(_resolve_guard_lib hook-inline-sentinel.sh); then
	# shellcheck source=../_lib/hook-inline-sentinel.sh
	source "$LIB_SENTINEL"
else
	# The advertised bypass is UNAVAILABLE, not merely inert — say so, because
	# the deny message below still advertises it.
	echo "phase1-directive-pending-guard: WARN: _lib/hook-inline-sentinel.sh not found (searched $HOOK_DIR/../_lib, $HOOK_DIR/../../_lib) — the PHASE1_DIRECTIVE_GUARD_SKIP bypass is UNAVAILABLE in this invocation" >&2
	hook_inline_sentinel_check() { return 1; }
fi
# v0.30.E (#191): cmd-anchor for the read-only allowlist below.
if LIB_ANCHOR=$(_resolve_guard_lib cmd-anchor.sh); then
	# shellcheck source=../_lib/cmd-anchor.sh
	source "$LIB_ANCHOR"
else
	echo "phase1-directive-pending-guard: WARN: _lib/cmd-anchor.sh not found (searched $HOOK_DIR/../_lib, $HOOK_DIR/../../_lib) — the read-only inspection allowlist is DISABLED; reads will be denied while a directive is pending" >&2
fi

# Outside-git-repo: allow (hook can fire anywhere). Capture stderr to
# distinguish "not a repo" from corruption.
git_err=$(mktemp)
git_rc=0
REPO_ROOT=$(git rev-parse --show-toplevel 2>"$git_err") || git_rc=$?
if [ "$git_rc" -ne 0 ]; then
	[ -s "$git_err" ] && echo "phase1-directive-pending-guard: git rev-parse failed (rc=$git_rc) — allowing call: $(head -c 200 "$git_err")" >&2
	rm -f "$git_err"
	exit 0
fi
rm -f "$git_err"

DIRECTIVE_DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
[ -d "$DIRECTIVE_DIR" ] || exit 0

# Find phase1-directive markers (existing ship-pr-cycle infrastructure).
# Use find with explicit rc capture (v0.6.5+ pattern). Pattern matches the
# `_phase1_directive_marker_file()` filename convention: `<sha>.phase1-directive.txt`.
find_err=$(mktemp)
find_out=$(mktemp)
find_rc=0
find "$DIRECTIVE_DIR" -maxdepth 1 -name '*.phase1-directive.txt' -print0 >"$find_out" 2>"$find_err" || find_rc=$?
if [ "$find_rc" -ne 0 ]; then
	hook_deny "phase1-directive-pending-guard" "find failed enumerating directive dir (rc=$find_rc) — fail-closed: $(head -c 200 "$find_err")"
fi
rm -f "$find_err"

pending_count=0
pending_list=""
# HEAD is invariant across markers — resolve ONCE here rather than per-iteration
# (CR-CLI). The age-prune predicate inside the loop reads $_head_sha.
_head_sha=$(git rev-parse HEAD 2>/dev/null) || _head_sha=""
while IFS= read -r -d '' f; do
	sha=$(basename "$f" .phase1-directive.txt)
	# (#223) Layer 0: age-based stale cleanup. A phase1-directive
	# marker is acted on within a session (agents fire within minutes); one
	# still "pending" after 2 days is stale cruft (an abandoned round, or a
	# squash-merge that left a local topic branch) that the two in-guard
	# self-heals BELOW miss — the #173 ancestor-of-origin/main check skips
	# squash-merges (the SHA is not an ancestor) and the #174 reachable-from-
	# any-ref check keeps the marker while a stale LOCAL branch still contains
	# the SHA. (NB: the project's "Layer 2"/"Layer 3" are the github-pr-merge
	# skill-side rm + the post-merge hook — NOT these in-guard checks; referenced
	# by #issue here to avoid that naming collision.) This is what let 9 markers
	# pile up over a multi-day session — the SessionStart sweep cannot fire mid-
	# session, but this guard runs on every Bash/Edit so it self-heals
	# continuously. The age test runs in the elif condition (set -e suppressed
	# there) so a find error short-circuits to "keep the marker" rather than
	# aborting; log the deletion so a mistaken cleanup is observable. Portable
	# mtime via find -mmin (macOS+Linux).
	#
	# CR #223 (major): age-ALONE could nuke a LIVE round paused over a long
	# weekend (>48h) — its marker SHA is the CURRENT HEAD, agents not yet fired —
	# silently un-gating Edit/Write/commit. So gate the age-prune behind a
	# stale-state predicate: NEVER age-prune a marker whose SHA == current HEAD
	# (that is an active, possibly-paused round, not cruft). Non-HEAD aged markers
	# (abandoned branches, squash-merge orphans the reachability layers below
	# miss) remain Layer-0 eligible — that is the cruft Layer 0 exists to sweep.
	# ($_head_sha is hoisted above the loop — HEAD is invariant across markers.)
	if [ -z "$_head_sha" ]; then
		: # git HEAD unverifiable — fail-CLOSED: do NOT age-prune (the marker may be
		# a live round; mirrors the rc-capture bail at the top of this hook). CR-CLI
		# r1 (major): the prior `|| echo ""` was fail-OPEN — an empty _head_sha fell
		# through to age-prune, which could nuke a live round when git was unreadable.
	elif [ "$sha" = "$_head_sha" ]; then
		: # active round on the current HEAD — skip age-prune; let Layers 1/2 decide
	elif _age_out=$(find "$f" -mmin +2880 -print 2>/dev/null) && [ -n "$_age_out" ]; then
		# CR #478 p2 (major): best-effort rm — under `set -euo pipefail` a failing
		# rm (readonly fs / perms) would ABORT the guard mid-sweep, leaving later
		# markers unprocessed AND the current Bash/Edit un-gated. Warn + keep
		# scanning the remaining markers instead of dying. Log the removal AFTER a
		# successful rm so the "auto-removed" line never claims a deletion that the
		# rm below actually failed to perform.
		if _rm_err=$(rm -f "$f" 2>&1); then
			echo "phase1-directive-pending-guard: Layer 0 auto-removed stale (>2d) marker $sha" >&2
			continue
		fi
		echo "phase1-directive-pending-guard: WARN: Layer 0 rm failed for $sha (continuing): $_rm_err" >&2
	fi
	# v0.27.0 #173 Layer 1: self-heal stale markers whose SHA is now
	# reachable from origin/main. Catches merge-commit / fast-forward /
	# rebase-and-push-retaining-SHA flows. Squash-merge writes a NEW
	# commit on main, so the ORIGINAL topic-branch HEAD sha is NOT a
	# direct ancestor of main — Layer 1 will NOT clean those; Layer 2
	# (skill-side rm in github-pr-merge) catches squash-merges by
	# capturing the pre-merge HEAD sha + removing the marker before the
	# branch is deleted. Layer 3 (post-merge hook) provides cross-clone
	# coverage for non-squash paths the operator pulled from main.
	if git merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
		rm -f "$f"
		continue
	fi
	# v0.28.0 #174: also drop markers whose sha is no longer reachable
	# from ANY local ref (abandoned commits — branch deleted, commit
	# rebased away). 2026-05-28 observed 34 accumulating across prior
	# sessions in a peer repo (#174 Axis 2).
	# CR fix: validate hex-sha basename BEFORE for-each-ref (skip
	# editor swap files); separate rc from empty-output (rc!=0 keeps
	# marker rather than flipping `!` into mass-rm on git error).
	if [[ $sha =~ ^[0-9a-f]{7,40}$ ]]; then
		_ref_out=$(git for-each-ref --contains "$sha" --format='%(refname)' 2>/dev/null) && _ref_rc=0 || _ref_rc=$?
		if [ "$_ref_rc" -eq 0 ] && [ -z "$_ref_out" ]; then
			rm -f "$f"
			continue
		fi
	fi
	# Stamp-less self-heal (#2427, the 2026-06-16 deadlock): a marker whose
	# state JSON EXISTS but lacks phase1_directive_protocol was written by a
	# STALE driver (a frozen repo-root scripts/ship-pr-cycle.sh predating the
	# #2237 protocol stamp). The correct (v0.34.32+) driver ALWAYS stamps it, so
	# ship-cycle-guard REJECTS the pr-review agents for an unstamped directive —
	# and every mechanical clear (re-drive / rm / the bypass's approval-file
	# write) is itself blocked by THIS guard → an unrecoverable in-session
	# deadlock. Such a marker can NEVER be satisfied by firing agents, so
	# self-clear it; the correct driver re-emits a STAMPED directive on the next
	# `next`. AGE-GUARDED on the marker mtime (>1 min): the correct driver writes
	# the state JSON (WITH the protocol stamp) FIRST and the marker SECOND
	# (ship-pr-cycle.sh #92 r2), so a freshly-written marker from a correct driver
	# already has a stamped state JSON beside it. An unstamped state JSON next to a
	# marker is the stale-driver signature; the >1 min guard only adds margin
	# against reading a state JSON whose stamping write is momentarily in flight,
	# while >1 min unstamped is definitively stale-driver. jq is rc-captured (not
	# `||`-abort under set -e):
	# a missing/unreadable/corrupt state JSON yields a non-"absent" verdict →
	# KEEP the marker (fail-closed; only a READABLE JSON that genuinely lacks the
	# field self-heals).
	_slh_state="$DIRECTIVE_DIR/$sha.json"
	# #2450: rc-capture + log find/jq failures in this stale-marker RECOVERY path
	# instead of a bare 2>/dev/null swallow — a hidden failure here masks WHY the
	# deadlock self-heal didn't fire. Behavior stays fail-closed: any failure
	# (find errors / unreadable-or-corrupt state JSON) → KEEP the marker.
	_slh_aged=""
	if [ -f "$_slh_state" ]; then
		if ! _slh_aged=$(find "$f" -mmin +1 -print 2>/dev/null); then
			echo "phase1-directive-pending-guard: WARN: find failed probing age of marker $sha — keeping marker (fail-closed)" >&2
			_slh_aged=""
		fi
	fi
	if [ -n "$_slh_aged" ]; then
		if ! _slh_proto=$(jq -r '.phase1_directive_protocol // "absent"' "$_slh_state" 2>/dev/null); then
			_slh_proto="unreadable"
			echo "phase1-directive-pending-guard: WARN: jq failed reading phase1_directive_protocol from $_slh_state (marker $sha) — treating as unreadable, keeping marker (fail-closed)" >&2
		fi
		if [ "$_slh_proto" = "absent" ]; then
			if _slh_rm=$(rm -f "$f" 2>&1); then
				echo "phase1-directive-pending-guard: self-healed stamp-less (stale-driver) marker $sha — state JSON has no phase1_directive_protocol; re-drive via the skill wrapper for a stamped directive (#2427)" >&2
				continue
			fi
			echo "phase1-directive-pending-guard: WARN: stamp-less self-heal rm failed for $sha (continuing): $_slh_rm" >&2
		fi
	fi
	pending_count=$((pending_count + 1))
	pending_list="${pending_list}  - sha=$sha (directive emitted; agents not yet fired)
"
done <"$find_out"
rm -f "$find_out"

[ "$pending_count" -eq 0 ] && exit 0

# Read stdin to extract command for inline-sentinel bypass + tool detection.
if ! PAYLOAD=$(cat 2>/dev/null); then
	echo "phase1-directive-pending-guard: stdin read failed — allowing call" >&2
	exit 0
fi

# Extract tool name + command. If it's Agent or Skill, allow (those are what
# we want to fire). Other tool types refused until directive cleared.
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

case "$TOOL" in
Agent | Skill)
	# Allow Agent + Skill calls — those ARE the Phase 1 firing path.
	exit 0
	;;
esac

# NOTE: the review-log.sh escape used to live HERE, above the shared screens,
# which is exactly why it never got them — see the hardened version further down,
# placed with its siblings after _cmd_launders_mutation is defined.

# (#2531) Shared launder-screen for the two lib-independent single-verb escapes
# below AND the general read-only block (which DELEGATES to it — #2531 CR r1).
# Returns 0 if $1 contains a construct that could smuggle a mutation past a verb
# allowlist: a statement separator / background / pipe / backtick, command/
# process substitution, or a SURVIVING file redirect. Harmless discard/dup
# redirects (2>/dev/null, 2>&1, >/dev/null, &>/dev/null) are STRIPPED FIRST
# (#2531 CR r1 comment-analyzer) so a benign `… 2>/dev/null` is NOT flagged —
# only a real file-writing redirect survives to the grep. Newlines fold to `;`
# because grep is line-oriented — a second-line command (`… next`⏎`git commit`)
# is otherwise invisible to a per-line reject. Extracted to ONE place so the
# escapes + general block can't drift.
# (#2535 phase2) Delegates to the SHARED definition in
# _lib/cmd-launder-screen.sh so this guard and phase1-log-pending-gate.sh can
# never disagree about whether a given command launders a mutation — they both
# admit review-log.sh, and an inline copy in the sibling had already drifted
# (missing the discard-redirect stripping). Falls back to the inline body when
# the lib is unreachable, keeping the guard functional in a lib-less layout.
if [ -r "$HOOK_DIR/../_lib/cmd-launder-screen.sh" ]; then
	# shellcheck source=../_lib/cmd-launder-screen.sh
	. "$HOOK_DIR/../_lib/cmd-launder-screen.sh" 2>/dev/null || true
fi
_cmd_launders_mutation() {
	if declare -f cmd_launders_mutation >/dev/null 2>&1; then
		cmd_launders_mutation "$1"
		return $?
	fi
	# Fallback body kept BYTE-FOR-BYTE identical to cmd_launders_mutation in
	# _lib/cmd-launder-screen.sh (incl. the discard-redirect stripping the sibling
	# gate's copy once lacked) so an unreachable-lib layout can't reintroduce the
	# drift the shared lib exists to end (CR-in-CI #2540). Same SIGPIPE-safe shape:
	# capture the transform, match in-shell, fail CLOSED on transform failure.
	local _screened
	_screened=$(
		printf '%s' "$1" |
			sed -E 's/2>&1/ /g; s/(&|[0-9]*)>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g' |
			tr '\n' ';'
	) || return 0
	local _re='[;&|`]|\$\(|<\(|[0-9]*>'
	[[ $_screened =~ $_re ]]
}

# (#2531 CR r1) semgrep flags that WRITE a file, POST to a URL, or rewrite
# source in place — rejected wherever a bare `semgrep scan` is admitted (the
# lib-independent escape below AND the general allowlist's `semgrep` verb),
# enumerated ONCE so the two can't drift. Matches short `-o`/`-oFILE` (the
# attached form evaded the old boundary-anchored reject — #2531 CR r1 Finding
# B), the whole `--<fmt>-output` family (--output/--json-output/--sarif-output/
# …), `--autofix`, and `--allow-local-builds`. `-o` is screened HERE (verb-
# aware), NOT in the general block, because it is a benign READ flag for grep
# (-o=only-matching), find (-o=OR), and ls (-o) — a blanket reject there broke
# those reads (#2531 CR r1 Finding A). The `--<fmt>-output` alternative is
# BOUNDED (…output([[:space:]=]|$)) so it matches only the write family whose
# flag ENDS in `output` (--output/--json-output/--sarif-output/--vim-output/…)
# and not a longer `--…output-<suffix>` flag. (The bound mirrors the general
# all-verb screen below, where it genuinely protects git diff's READ flag
# --output-indicator-new/-old; semgrep itself has no such flag — this helper is
# verb-gated to semgrep, so that protection lives there, not here.)
_semgrep_has_write_flag() {
	# Short forms are matched as a CLUSTER (`-[a-zA-Z]*[ao]`) so both the bare
	# `-a`/`-o`, the attached-value `-oFILE`, and a bundled `-qa`/`-qo` are
	# caught — semgrep documents `-a/--autofix` (in-place source rewrite) and
	# `-o/--output`, and a cluster is the same flag by another spelling.
	# `--allow-*` is screened as a FAMILY (not just --allow-local-builds) since
	# every member relaxes a sandbox/exec restriction.
	printf '%s' "$1" | grep -qE '(^|[[:space:]])-[a-zA-Z]*[ao]|(^|[[:space:]])--[a-z-]*output([[:space:]=]|$)|(^|[[:space:]])--(autofix|allow-[a-z-]+)([[:space:]=]|$)'
}

# Allow the cycle-advance/report verbs `ship-pr-cycle.sh next|resume|status|
# start`. These ONLY advance or report cycle state — during phase1 (the only
# stage this guard fires in) `next` walks the round machinery; it never
# commits/pushes/Edits (the productive work this guard exists to defer, all of
# which lives at later stages where no phase1 marker exists). Without this the
# operator can't run `next` to advance a round after firing agents, and because
# `next` re-emits the directive marker, the round can never complete →
# phase1_rounds stuck at 0 → the branch never graduates (the mid-phase1
# advance deadlock). Plain grep (like the review-log allowlist above) so it
# works even when the cmd-anchor / inline-sentinel libs fail to source from
# $HOOK_DIR/../_lib (the environment in which the advertised
# PHASE1_DIRECTIVE_GUARD_SKIP bypass silently no-ops). Anchored at `^` with NO
# env-assignment prefix (a `BASH_ENV=`/`LD_PRELOAD=` prefix would be arbitrary
# code exec — security-review) and screened by _cmd_launders_mutation, so
# nothing can precede or trail the bare verb. The PATH is restricted to the
# CANONICAL `(.claude/)?scripts/ship-pr-cycle.sh` (plugin + consumer forms, opt.
# `./` / `bash ` prefix) — NOT an arbitrary `*/ship-pr-cycle.sh`, a `/tmp/…` or
# `../` traversal path, or a bare PATH-resolved name — so the escape can't admit
# a look-alike script planted elsewhere (#2531 CR-CLI critical).
if printf '%s' "$CMD" | grep -qE '^(bash[[:space:]]+)?(\./)?(\.claude/)?scripts/ship-pr-cycle\.sh[[:space:]]+(next|resume|status|start)([[:space:]]|$)' &&
	! _cmd_launders_mutation "$CMD"; then
	exit 0
fi

# Allow a bare `semgrep scan …` (the round's static-analysis step). semgrep is
# already in the read-only allowlist below, but that whole block is gated on
# `declare -f match_cmd_at_anchor` and is silently skipped whenever the
# cmd-anchor lib fails to source from $HOOK_DIR/../_lib (the same resolution
# failure that no-ops the inline-sentinel bypass) — which strands the operator
# mid-round: the 5 agents are logged but `semgrep` (required to complete the
# round) is denied, so the round never finishes. This plain-grep escape is
# lib-independent. Anchored `^` with no env-prefix (see above); _cmd_launders_
# mutation blocks separators/redirects/subst; and _semgrep_has_write_flag (a
# shared helper) rejects every output-writing / source-rewriting flag so the
# escape and the general block below can't drift. (#followup: fix the
# directive-guard _lib resolution at the root.)
if printf '%s' "$CMD" | grep -qE '^semgrep[[:space:]]+scan([[:space:]]|$)' &&
	! _cmd_launders_mutation "$CMD" &&
	! _semgrep_has_write_flag "$CMD"; then
	exit 0
fi

# Allow review-log.sh — the way to clear the directive after agents return.
#
# SECURITY (#2535 r1 security-review): this escape previously sat ABOVE the
# shared screens and was the guard's most permissive path. Two bypasses were
# CONFIRMED empirically against the old regex
# `((^|[;&|][[:space:]]*)([A-Z_][A-Z0-9_]*=...)*)\.?/?\.claude/hooks/review-log\.sh`:
#
#   1. ARBITRARY CODE EXECUTION via env prefix. The `NAME=value` group admitted
#      `BASH_ENV=/tmp/evil.sh .claude/hooks/review-log.sh …`. review-log.sh has a
#      `#!/bin/bash` shebang, so running it starts a NON-INTERACTIVE bash, which
#      sources $BASH_ENV before the script body — attacker code runs with the
#      session's full privileges. (LD_PRELOAD is the Linux-consumer equivalent.)
#   2. TOTAL BYPASS via compound command. The `(^|[;&|]…)` alternative meant the
#      match could begin after ANY separator, and there was no end anchor, so
#      `git commit -am pwned; .claude/hooks/review-log.sh` was admitted whole.
#
# Both are the exact classes the sibling escapes were already hardened against —
# the ship-pr-cycle escape's own comment reasons that "a BASH_ENV=/LD_PRELOAD=
# prefix would be arbitrary code exec". This one predated that reasoning and was
# never retrofitted, and its position above _cmd_launders_mutation's definition
# is why. Now anchored at ^ with NO env-assignment prefix, restricted to the
# canonical path, and screened by the same shared launder check. Arguments are
# still allowed (the call is `review-log.sh phase1 <round> <agent> <n> ok`) —
# _cmd_launders_mutation is what keeps them from smuggling a second command.
if printf '%s' "$CMD" | grep -qE '^(bash[[:space:]]+)?(\./)?(\.claude/)?hooks/review-log\.sh([[:space:]]|$)' &&
	! _cmd_launders_mutation "$CMD"; then
	exit 0
fi

# (#2535) Allow the sanctioned-bypass APPROVAL WRITE:
#   touch <...>/.claude/.session-state/skip-approvals/<hash>.txt
#
# WHY: hooks/skip-env-approval-gate.sh is the SSOT for authorizing a `*_SKIP=1`
# bypass. It only ever CONSUMES an approval file; creating one is delegated to
# the operator, and its own deny message instructs `touch "$APPROVAL_FILE"`.
# But `touch` is not a read-only verb, so while a phase1 directive marker was
# pending THIS guard denied that touch — making the entire sanctioned bypass
# unreachable at exactly the moment it is needed. That is the second jaw of the
# #2531 deadlock: the escape hatch could not be opened from inside. This guard's
# own comments already name it ("the bypass's approval-file write is itself
# blocked by THIS guard → an unrecoverable in-session deadlock").
#
# Same lib-independent plain-grep shape as the review-log.sh allowlist above, so
# it works even when cmd-anchor did not load. Tightly bounded (#2535 phase2 CR):
# anchored at `^` with NO env-assignment prefix (a `BASH_ENV=`/`LD_PRELOAD=`
# prefix is arbitrary code exec); EXACTLY ONE argument; the basename must be the
# EXACT sha256 form skip-env-approval-gate writes — `[0-9a-f]{64}.txt`, not a
# loose `[A-Za-z0-9._-]+` (the gate keys on sha256("$SKIP_VAR|$CMD"), so nothing
# else is a real approval file); the path may be the canonical relative form or
# an absolute path ENDING in that exact segment; `..` anywhere is rejected so the
# segment cannot be reached via traversal; and _cmd_launders_mutation screens
# separators/pipes/substitutions/redirects. Worst case this admits is creating
# one empty hash.txt in a skip-approvals dir, and skip-env-approval-gate only
# ever reads the one under $REPO_ROOT.
if printf '%s' "$CMD" | grep -qE '^touch[[:space:]]+"?(/[^"[:space:]]*/)?\.claude/\.session-state/skip-approvals/[0-9a-f]{64}\.txt"?[[:space:]]*$' &&
	! printf '%s' "$CMD" | grep -qF '..' &&
	! _cmd_launders_mutation "$CMD"; then
	exit 0
fi

# v0.30.E (#191): allow a SINGLE, SIMPLE read-only INSPECTION command through
# while a directive is pending. The guard's purpose is to stop the main loop
# from doing PRODUCTIVE work (Edit/Write/commit/push) or stalling before
# firing the Phase 1 agents — NOT to block harmless reads. Critically, this
# PreToolUse hook ALSO fires inside the Phase 1 subagents (code-reviewer et
# al.), whose job is to run `git diff`/`cat`/`grep` over the diff; denying
# those reads mid-review was the #191 bug. Non-Bash write tools (Edit, Write,
# MultiEdit, NotebookEdit) are never read-only — the [ "$TOOL" = Bash ] guard
# means they fall straight through to the deny.
#
# SECURITY (v0.30.E r2, #191 Phase 1): a read verb at the FRONT does NOT make
# a COMPOUND command read-only. `git diff && git push`, `cat $(rm -rf x)`,
# `git diff | tee f`, `git diff --output=f`, and `find . -delete` all launder
# a mutation behind a leading read verb. So we REJECT (fall through to deny)
# any command that can chain, substitute, pipe, background, redirect to a
# file, or invoke a per-tool write action — and only THEN allowlist the
# leading verb of what remains (which is now guaranteed a single simple cmd).
if [ "$TOOL" = "Bash" ] && declare -f match_cmd_at_anchor >/dev/null 2>&1; then
	# THREAT MODEL (#191 P1 r1-r3): this guard is a WORKFLOW NUDGE for a
	# cooperative agent — it stops the main loop from doing productive work
	# (commit/push/Edit/Write) or stalling before firing Phase 1 agents. It is
	# NOT an adversarial sandbox: the realistic failure is Claude absent-
	# mindedly committing before agents fire, not Claude crafting `find -rm`
	# to evade its own guard. Prompt-injection of a subagent is defended by
	# the auto-mode classifier + other gates, not here. So the screen below is
	# BEST-EFFORT for the known write/exec-via-flag classes; it does not
	# attempt to be exhaustive against every tool implementation's flag zoo
	# (the local `find` is bfs with `-rm`, `grep` is ugrep with `--filter` —
	# implementations vary and cannot all be enumerated).
	#
	# Reject when the command either (a) LAUNDERS a mutation via separator /
	# background / pipe / backtick / command-or-process substitution / a
	# surviving file redirect — DELEGATED to _cmd_launders_mutation so the
	# laundering definition lives in ONE place (#2531 CR r1 code-simplifier;
	# the helper pre-strips harmless 2>/dev/null|2>&1|&>/dev/null discards), or
	# (b) carries a cross-tool write/exec-via-flag:
	#   --*output=  — git --output + semgrep --json-output/--sarif-output/...
	#                 (the whole --<fmt>-output family writes a file / POSTs to
	#                 a URL). BOUNDED so the READ flag --output-indicator-* is
	#                 NOT false-rejected.
	#   --autofix / --allow-local-builds — semgrep source rewrite / local exec
	#   --pre / --hostname-bin — ripgrep exec-a-command flags (#191 r2)
	#   -delete / -rm / -exec* / -ok* / -fprint* / -fls — find write/exec
	#                 actions (-rm is the bfs alias for -delete, #191 r3)
	# semgrep's SHORT -o is NOT screened here — it is a benign read flag for
	# grep (-o=only-matching) / find (-o=OR) / ls (-o); a blanket reject here
	# regressed those reads (#2531 CR r1 Finding A). It is rejected VERB-AWARE
	# in the allowlist loop below (via _semgrep_has_write_flag).
	#
	# RULE for adding a verb to the allowlist below: its subprocess-spawn /
	# file-write flags must be EITHER absent OR screened (universal above /
	# per-verb below). cat/head/tail/ls/wc/grep qualify with no such flag;
	# find + semgrep qualify because their write/exec flags ARE screened (find
	# above; semgrep both above + verb-aware below); rg / git-grep did NOT
	# (--pre / --open-files-in-pager exec). git read subcmds qualify with
	# --output screened above.
	if _cmd_launders_mutation "$CMD" ||
		printf '%s' "$CMD" | grep -qE '(^|[[:space:]])--[a-z-]*output([[:space:]=]|$)|(^|[[:space:]])--(autofix|allow-local-builds)([[:space:]=]|$)|(^|[[:space:]])--(pre|hostname-bin)([[:space:]=]|$)|(^|[[:space:]])-(delete|rm|exec|execdir|ok|okdir|fprint|fprintf|fprint0|fls)([[:space:]]|$)'; then
		: # laundered mutation / exec-or-write-flag — deny
	else
		# Single simple command: allowlist its leading read-only verb. git
		# mutating verbs (commit/push/add/reset/...) are excluded — only read
		# subcommands listed. sed/awk/jq/yq excluded (write modes: sed -i,
		# sed -n 'w', awk redirects). `rg` excluded too (--pre/--hostname-bin
		# exec — #191 r2); subagents use the Grep TOOL (unaffected by this
		# Bash-only hook) or `grep`, plus the Read tool + git diff.
		# NB: `git grep` is intentionally NOT here — it has
		# --open-files-in-pager[=<cmd>] which execs a pager (same exec-flag
		# class as rg --pre, #191 r2). Plain `grep` (no such flag) covers
		# search. git diff's `-O<orderfile>` (read) is fine — only --output
		# writes, and that's screened above.
		#
		# v0.31 #225 (silent-failure-hunter #4): the sanctioned test runners
		# scripts/test.sh + scripts/test-touched.sh are allowed so a Phase-1
		# REVIEW subagent can verify behaviorally (red/green) WITHOUT resorting to
		# PHASE1_DIRECTIVE_GUARD_SKIP. They are read-only w.r.t. source — they write
		# only gitignored verification artifacts under .claude/ (bats-run.jsonl,
		# test-run-summary.jsonl, the .review-cache ledger) + temp dirs, not the
		# productive commit/push/Edit work this guard exists to defer. The single
		# pattern accepts an optional env-prefix (e.g. `BASE=main
		# scripts/test-touched.sh` — the documented scope-vs-main form) and the
		# `bash <runner>` form, reusing the env-prefix idiom of the review-log
		# allowlist above + _lib/cmd-anchor.sh. The compound/redirect/exec-flag
		# screen above still runs FIRST (so `scripts/test.sh; rm …` is denied).
		for _ro in \
			'git[[:space:]]+(diff|log|show|status|rev-parse|for-each-ref|branch|merge-base|ls-files|cat-file|describe|blame)' \
			'cat' 'head' 'tail' 'grep' 'find' 'ls' 'wc' 'semgrep' \
			'([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(bash[[:space:]]+)?(\./)?scripts/test(-touched)?\.sh'; do
			if match_cmd_at_anchor "$_ro" "$CMD"; then
				# semgrep ALONE can write via its short -o (a benign read flag
				# for the other verbs, so screened per-verb HERE — #2531 CR r1
				# Finding A/B). Its long write flags are caught above.
				if [ "$_ro" = 'semgrep' ] && _semgrep_has_write_flag "$CMD"; then
					break # deny — semgrep with a write/exfil flag
				fi
				exit 0
			fi
		done
	fi
fi

# Inline-sentinel bypass.
if hook_inline_sentinel_check "PHASE1_DIRECTIVE_GUARD_SKIP" "$CMD" "phase1-directive-pending"; then
	exit 0
fi

hook_deny "phase1-directive-pending-guard" \
	"$pending_count Phase 1 round directive(s) pending — fire Phase 1 agents BEFORE next non-Agent/Skill tool call:
$pending_list
Required action: fire the 5 parallel Agent calls (code-reviewer, code-simplifier,
comment-analyzer, pr-test-analyzer, silent-failure-hunter) + run semgrep + fire
Skill(security-review). See ship-pr-cycle.sh directive output for round number.

Bypass (audit-logged): PHASE1_DIRECTIVE_GUARD_SKIP=1 <cmd>"
