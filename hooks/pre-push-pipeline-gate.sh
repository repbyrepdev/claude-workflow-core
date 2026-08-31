#!/bin/bash
# auto-register: false
# (Invoked by .git/hooks/pre-push, not a Claude tool-use hook —
#  install-hooks.sh skips opted-out files.)
# v4.3.F (#372) + v4.15.C (#491): git pre-push hook — refuses push unless
# the local review pipeline has left evidence of convergence for the sha
# being pushed.
#
# git pre-push receives one line per ref being pushed on stdin:
#   <local_ref> <local_sha> <remote_ref> <remote_sha>
#
# Gate logic (v4.15.C hardened — expected vs actual agent set + rounds + streak):
#   - 0000...0000 local_sha → branch deletion, allow
#   - Log file missing for local_sha → refuse (pipeline never ran)
#   - No phase:2 entry in log → refuse (Phase 2 CR CLI never ran)
#   - Fewer than MIN_ROUNDS Phase 1 rounds → refuse (MIN_ROUNDS =
#     PHASE1_MIN_ROUNDS override, else auto-scaled per diff via
#     _auto_scale_min_rounds — LOC tiers 0-6, sensitive-path floor 3)
#   - Last MIN_CLEAN_STREAK (default 1; PHASE1_MIN_CLEAN_STREAK to raise)
#     rounds not all-agents-clean → refuse
#   - Any round is missing an expected agent per list-phase1-agents.sh → refuse
#     (prior version only checked "round where agents-that-ran are clean" —
#     fabricatable by logging 1 fake agent; now requires every expected
#     agent to be present per round)
#
# Override: set PIPELINE_GATE_SKIP=1 to bypass (e.g., emergency hotfix,
# docs-only touch-up, first-push-of-a-new-branch scratch). Recorded to
# stderr for visibility.
set -euo pipefail

# Resolve THIS script's real directory even when git invokes us through a
# `.git/hooks/pre-push` SYMLINK (one consumer install shape — install-hooks.sh
# itself writes a wrapper, handled below). Under a symlink
# `$0`/`${BASH_SOURCE[0]}` point at `.git/hooks/`, a DIFFERENT depth than the
# real hook, so `dirname/../_lib` resolves to a nonexistent `.git/_lib` and the
# _lib + sibling sourcing below silently no-ops → fail-closed push (#2252).
# The loop below follows the symlink chain so the BARE-SYMLINK shape resolves to
# the real hook's dir. The OTHER install shapes need no loop and fall straight
# through it: the install-hooks.sh wrapper `exec`s the absolute real path, a
# whole-tree copy keeps `_lib` as a sibling, and `bats` sources the real .sh —
# in each `${BASH_SOURCE[0]}` is already the real file (not a symlink). Empty/
# wrong PPG_DIR (unresolvable) falls through to the existing `[ -r ]` / `[ -x ]`
# guards → fail-safe, never a silent pass. `readlink` (not `readlink -f`) keeps
# this portable to stock macOS/BSD.
_ppg_self="${BASH_SOURCE[0]:-$0}"
# Bounded hop count terminates even on a pathological symlink CYCLE (`readlink`,
# unlike `-f`, has no ELOOP detection). 40 ≫ any real install chain; on overrun
# the loop exits with `_ppg_self` still a symlink, so PPG_DIR resolves to a
# non-canonical dir whose `../_lib` won't exist → the guards fail-closed.
_ppg_hops=0
while [ -L "$_ppg_self" ] && [ "$_ppg_hops" -lt 40 ]; do
	_ppg_hops=$((_ppg_hops + 1))
	_ppg_link="$(readlink "$_ppg_self" 2>/dev/null)" || break
	case "$_ppg_link" in
	/*) _ppg_self="$_ppg_link" ;;
	*)
		# Relative link: resolve against the link's OWN directory (on a multi-
		# hop chain that dir derives from the prior hop's target, re-canonicalized
		# by the cd/pwd below). If it
		# can't be resolved, STOP following rather than fabricate `/$_ppg_link`
		# from a bare target (#2252 phase0.5 silent-failure-hunter). Final
		# PPG_DIR stays fail-safe.
		_ppg_parent="$(cd "$(dirname "$_ppg_self")" 2>/dev/null && pwd)" || _ppg_parent=""
		[ -n "$_ppg_parent" ] || break
		_ppg_self="$_ppg_parent/$_ppg_link"
		;;
	esac
done
if ! PPG_DIR="$(cd "$(dirname "$_ppg_self")" 2>/dev/null && pwd)"; then
	PPG_DIR="" # unresolvable → existing [ -r ]/[ -x ] guards fail-safe
fi

# v4.23-A (#547): change-type-aware Phase 1 round floor. Prior fixed
# MIN_ROUNDS=5 cost ~1.75M tokens per PR regardless of size or nature.
# Decision tree (first match wins):
#
#   0 rounds — commit-msg-only (no diff), auto-revert of branch commit,
#              docs-only (*.md, docs/**), generated-files-only (lockfiles, *.pb.go)
#   1 round  — tests-only (*.bats), comments/docstrings-only (100% comment+ws),
#              refactor-only (no semantic change per --ignore-all-space),
#              code ≤50 LOC
#   2 rounds — config-only (YAML/TOML/JSON/conf/ini, no code), code 51-150 LOC
#   3 rounds — code 151-400 LOC, or SENSITIVE path touched (floor up from
#              any lower tier — see _touches_sensitive_path below)
#   4 rounds — code 401-800 LOC
#   5 rounds — code 801-1500 LOC
#   6 rounds — code 1501+ LOC
#
# Override precedence: explicit PHASE1_MIN_ROUNDS env > auto-derivation.
#
# All helpers below are local to this script — not sourced elsewhere.

# Pick the best available base ref for diffing. origin/main preferred (catches
# locally-unpushed state). Returns the ref name on stdout, empty + rc=1 if
# no usable base exists (e.g., fresh clone pre-first-fetch).
# Takes one arg: the sha/ref being pushed (unused in this function but kept for signature consistency).
_base_ref() {
	# $1 = sha (unused here, base is always origin/main or main)
	if git rev-parse --verify origin/main >/dev/null 2>&1; then
		echo origin/main
	elif git rev-parse --verify main >/dev/null 2>&1; then
		echo main
	else
		return 1
	fi
}

# Count insertions+deletions in the diff. Takes base ref and sha as args.
# Returns 0 if parse fails (safe — triggers highest-tier review).
_diff_loc() {
	local base=$1 sha=$2 loc=0
	loc=$(git diff --shortstat "$base".."$sha" 2>/dev/null |
		awk '{
			ins=0; del=0
			for (i=1;i<=NF;i++) {
				if ($i ~ /insertion/) ins=$(i-1)
				if ($i ~ /deletion/) del=$(i-1)
			}
			print ins+del
		}')
	case "$loc" in '' | *[!0-9]*)
		echo 999999
		return
		;;
	esac
	echo "$loc"
}

# All changed file paths relative to repo root. Empty if no commits/diff.
_diff_files() {
	local base=$1 sha=$2
	git diff --name-only "$base".."$sha" 2>/dev/null
}

# True when every changed file matches at least one pattern in $@.
# Patterns use bash glob. Returns 0 on all-match (and at least 1 file),
# 1 otherwise.
_all_files_match() {
	local base=$1 sha=$2
	shift 2
	local files
	files=$(_diff_files "$base" "$sha")
	[ -n "$files" ] || return 1
	while IFS= read -r f; do
		local matched=0
		for pat in "$@"; do
			# shellcheck disable=SC2053  # intentional glob match
			[[ $f == $pat ]] && matched=1 && break
		done
		[ "$matched" -eq 1 ] || return 1
	done <<<"$files"
	return 0
}

# Detects "touching a sensitive path". These are files where bypass
# risk is high enough that floor=3 regardless of LOC.
_touches_sensitive_path() {
	local base=$1 sha=$2
	_diff_files "$base" "$sha" | grep -qE '^(\.github/workflows/|\.pre-commit-config\.yaml$|scripts/(maintain|restore)\.sh$|\.claude/hooks/skill-bypass-guard\.sh$|\.claude/hooks/.*-pipeline-gate\.sh$|config/.*\.enc$)'
}

# Detects generated files. Lockfiles + compiled artifacts + minified bundles.
_is_generated_only() {
	local base=$1 sha=$2
	_all_files_match "$base" "$sha" '*.lock' '*-lock.json' 'package-lock.json' 'yarn.lock' \
		'poetry.lock' 'Cargo.lock' 'go.sum' '*.pb.go' '*.generated.*' '*.min.js' '*.min.css'
}

# Detects "commit message only" — same tree as base, only SHA differs
# (git commit --amend --no-edit with message change).
_is_commit_msg_only() {
	local base=$1 sha=$2
	# If no non-merge commits ahead of base have any file change, tree is identical.
	local changed
	changed=$(git diff --stat "$base".."$sha" 2>/dev/null)
	[ -z "$changed" ]
}

# Detects auto-revert: topmost commit is a git revert of another commit
# on the same branch since main.
_is_auto_revert() {
	local base=$1 sha=$2
	local msg
	msg=$(git log -1 --pretty=%B "$sha" 2>/dev/null)
	# `git revert` emits messages starting "Revert \"...\""
	[[ $msg =~ ^Revert\ \" ]] || return 1
	# And the reverted sha must be on this branch.
	local reverted
	reverted=$(printf '%s' "$msg" | grep -oE 'This reverts commit [0-9a-f]+' | head -1 | awk '{print $NF}')
	[ -n "$reverted" ] || return 1
	# Ensure reverted commit is actually an ancestor of this branch HEAD
	git merge-base --is-ancestor "$reverted" "$sha" 2>/dev/null || return 1
	git merge-base --is-ancestor "$reverted" "$base" 2>/dev/null && return 1
	return 0
}

# Detects refactor-only (no semantic change): diff with --ignore-all-space
# shows 0 stats. Pure renames, whitespace, import reorders.
_is_refactor_only() {
	local base=$1 sha=$2
	local stat
	stat=$(git diff --ignore-all-space --ignore-blank-lines --shortstat "$base".."$sha" 2>/dev/null)
	[ -z "$stat" ]
}

# Detects "comments/docstrings only": 100% of added/removed non-context
# lines start with comment markers (#, //) or are whitespace.
_is_comments_only() {
	local base=$1 sha=$2
	local non_comment_lines
	# --unified=0 drops context, `^[+-]` lines are the actual diff content.
	# Strip leading +/-, trim, skip blank/comment lines. If anything remains,
	# it's a code change.
	non_comment_lines=$(git diff --unified=0 "$base".."$sha" 2>/dev/null |
		grep -E '^[+-][^+-]' |
		sed -E 's/^[+-]//' |
		awk '{
			line=$0
			sub(/^[[:space:]]+/,"",line)
			sub(/[[:space:]]+$/,"",line)
			if (length(line) == 0) next
			if (line ~ /^#/) next
			if (line ~ /^\/\//) next
			if (line ~ /^\*/) next    # inside /* */ blocks
			if (line ~ /^\/\*/) next
			print line
		}' | wc -l | tr -d ' ')
	[ "$non_comment_lines" = "0" ]
}

# v4.24-Q2 (#609): When the SHA being pushed has an entry in
# cr-local-review.jsonl with findings=0 (i.e. CR CLI reviewed AND found
# nothing), delegate round count to phase1-scaler.sh. Rationale: if CR
# CLI agrees the code is clean, the scaler's upstream-signal-aware tier
# is the right counter; the LOC heuristic fires 4 rounds on small fix-up
# commits to a CR-converged branch, which caused 5+ PIPELINE_GATE_SKIP=1
# bypasses on epic v4.24 on a single day (the mechanism was paper-tiger).
#
# Returns 0 + scaler's round count on stdout when delegation fires.
# Returns 1 when no match OR findings>0 OR scaler missing — caller falls
# back to the LOC tier.
# v0.32.7 (#238): the CR Phase 2 coverage check is now SSOT in
# _lib/cr-phase2-coverage.sh, SHARED with ship-pr-cycle's Phase 2 round-cap so
# the cap never advances to a push this gate would refuse (and the two can't
# drift). Resolved via the symlink-safe PPG_DIR preamble (top of file) so it
# works whether the gate is executed (pre-push — including through a
# `.git/hooks/pre-push` symlink) or sourced-for-test under bats.
# (#2642) The bats-scope SSOT, sourced beside the other shared libs. The
# consumer install keeps it at .claude/_lib/; the plugin's own repo at
# top-level _lib/. Absence is NOT silently tolerated — the check-5 block
# below refuses the push rather than treating an unknown scope as empty.
_ppg_scope_lib=""
if [ -r "$PPG_DIR/../_lib/bats-scope.sh" ]; then
	_ppg_scope_lib="$PPG_DIR/../_lib/bats-scope.sh"
elif [ -r "$PPG_DIR/../../_lib/bats-scope.sh" ]; then
	_ppg_scope_lib="$PPG_DIR/../../_lib/bats-scope.sh"
fi
if [ -n "$_ppg_scope_lib" ]; then
	# shellcheck source=../_lib/bats-scope.sh
	. "$_ppg_scope_lib" || true
fi

_ppg_cov_lib="$PPG_DIR/../_lib/cr-phase2-coverage.sh"
if [ -r "$_ppg_cov_lib" ]; then
	# shellcheck source=../_lib/cr-phase2-coverage.sh
	. "$_ppg_cov_lib"
fi

# v4.24-Q3 (#610): predicate form — rc 0 when this SHA's Phase 2 review is clean
# (findings=0) OR all findings are addressed (delegates to the shared SSOT
# above). Preserves the prior operator-visible acceptance line. Fail-CLOSED if
# the shared lib didn't load (never silently pass an unverified Phase 2).
_cr_cli_clean_for_sha() {
	if ! command -v cr_phase2_clean_for_sha >/dev/null 2>&1; then
		echo "pre-push-pipeline-gate: ERROR: _lib/cr-phase2-coverage.sh not sourced — cannot verify Phase 2 (fail-closed)" >&2
		return 1
	fi
	cr_phase2_clean_for_sha "$1" || return 1
	echo "pre-push-pipeline-gate: Phase 2 clean/covered for $(printf '%s' "$1" | cut -c1-7) (shared #238 coverage check) — accepting." >&2
	return 0
}

_scaler_says() {
	local sha=$1
	# Resolve repo root inside the function so bats tests can source this
	# before the main body sets REPO_ROOT. Tests can override by exporting
	# REPO_ROOT explicitly (which takes precedence).
	local repo_root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
	local scaler="$repo_root/.claude/hooks/phase1-scaler.sh"
	_cr_cli_clean_for_sha "$sha" || return 1
	[ -x "$scaler" ] || return 1
	local r
	r=$("$scaler" 2>/dev/null) || return 1
	[[ $r =~ ^[0-9]+$ ]] || return 1
	echo "$r"
}

# The main decision function. Echoes the round count on stdout.
# Takes one arg: the sha being pushed.
_auto_scale_min_rounds() {
	local sha=$1
	local base loc

	# v4.24-Q2: scaler delegation fires when CR CLI already converged on
	# this SHA. Falls through to LOC tier otherwise.
	local scaler_rounds
	if scaler_rounds=$(_scaler_says "$sha"); then
		echo "$scaler_rounds"
		return 0
	fi

	base=$(_base_ref "$sha") || {
		echo 3
		return 0
	}

	# Tier 0: zero-review changes.
	_is_commit_msg_only "$base" "$sha" && {
		echo 0
		return
	}
	_is_auto_revert "$base" "$sha" && {
		echo 0
		return
	}
	_all_files_match "$base" "$sha" '*.md' 'docs/*' 'docs/**' && {
		echo 0
		return
	}
	_is_generated_only "$base" "$sha" && {
		echo 0
		return
	}

	# Compute sensitive-floor once for the tiers below.
	local sensitive_floor=0
	_touches_sensitive_path "$base" "$sha" && sensitive_floor=3

	local tier_rounds
	# Tier 1: one-round changes.
	if _all_files_match "$base" "$sha" '*.bats'; then
		tier_rounds=1
	elif _is_comments_only "$base" "$sha"; then
		tier_rounds=1
	elif _is_refactor_only "$base" "$sha"; then
		tier_rounds=1
	else
		# Code-LOC-based tier.
		loc=$(_diff_loc "$base" "$sha")
		if _all_files_match "$base" "$sha" '*.yml' '*.yaml' '*.toml' '*.json' '*.conf' '*.ini'; then
			tier_rounds=2
		elif [ "$loc" -le 50 ]; then
			tier_rounds=1
		elif [ "$loc" -le 150 ]; then
			tier_rounds=2
		elif [ "$loc" -le 400 ]; then
			tier_rounds=3
		elif [ "$loc" -le 800 ]; then
			tier_rounds=4
		elif [ "$loc" -le 1500 ]; then
			tier_rounds=5
		else
			tier_rounds=6
		fi
	fi

	# Sensitive-path floor never reduces rounds.
	if [ "$tier_rounds" -lt "$sensitive_floor" ]; then
		echo "$sensitive_floor"
	else
		echo "$tier_rounds"
	fi
}

# v0.31 #228: fail-soft hook-wiring drift advisory. Defined ABOVE the
# SOURCED_FOR_TEST early-return so bats can source + exercise it. Runs the orphan
# detector (--strict exits 1 on any auto-register:true hook missing from
# ~/.claude/settings.json) and WARNS to stderr — it NEVER blocks the push (the
# wiring is per-machine; a hard block would wedge a fresh clone). Always rc 0.
_orphan_hook_advisory() {
	local repo_root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
	[ "${ORPHAN_HOOK_CHECK_SKIP:-0}" = "1" ] && return 0
	local detect="$repo_root/scripts/discover-orphan-hooks.sh"
	[ -x "$detect" ] || return 0
	local out rc=0
	out=$("$detect" --strict 2>&1) || rc=$?
	# discover-orphan-hooks exit codes: 0=clean, 1=orphans found, 2=precondition
	# error (missing settings.json / jq / hooks dir). #228 r1: distinguish them —
	# a tooling/precondition error must NOT be framed as "drift" with a
	# register-hook remediation that wouldn't resolve it (misleading on a fresh
	# clone). All paths still return 0 — the advisory never blocks the push.
	case "$rc" in
	0) : ;; # clean — silent
	1)
		echo "pre-push-pipeline-gate: hook-wiring drift (advisory — NOT blocking the push):" >&2
		printf '%s\n' "$out" | sed 's/^/  /' >&2
		echo "  → Run: scripts/register-hook.sh --all-auto-register" >&2
		;;
	*)
		echo "pre-push-pipeline-gate: orphan-hook check could not run (detector rc=$rc, advisory skipped):" >&2
		printf '%s\n' "$out" | sed 's/^/  /' >&2
		;;
	esac
	return 0
}

# v0.34.84 #2295: force-push / history-rewrite → graduation invalidation.
# A non-fast-forward push (the remote ref EXISTS and is NOT an ancestor of the
# pushed SHA) means the branch history was rewritten — rebase, reset, or an
# amend that was already pushed. Any graduation marker certifies Phase 0.5/1
# passed at a now-discarded SHA, so it is stale and must be cleared BEFORE the
# graduation short-circuit consults it — otherwise a rewritten branch skips the
# Phase 1 log walk on the strength of a review that no longer describes its code.
# `graduation_invalidate` must be in scope (caller sources phase-graduation.sh).
# Returns 0 when a force-push was DETECTED (marker invalidation is attempted,
# a failure WARNs to stderr per #2483; the caller's _grad_forced then bypasses
# the graduation short-circuit regardless of rm success, so the push takes the
# standard non-graduated gate path — see #2295), 1
# otherwise (fast-forward, brand-new branch, or no branch). Defined above the
# SOURCED_FOR_TEST early-return so bats can exercise it in isolation (ZERO is
# passed in, not read from the global, which is set below the early-return).
_grad_invalidate_on_force_push() {
	local branch=${1:-} remote_sha=${2:-} local_sha=${3:-} zero=${4:-}
	[ -n "$branch" ] || return 1
	# All-zeros (or empty) remote ⇒ the remote ref does not exist yet (first
	# push of this branch) — a create, never a force-push.
	[ -n "$remote_sha" ] && [ "$remote_sha" != "$zero" ] || return 1
	# Fast-forward ⇒ remote_sha is an ancestor of local_sha — history extended,
	# not rewritten. Silent failure on an unresolvable remote_sha is acceptable:
	# the zero case is already guarded, and an unknown remote falling through to
	# "force-push" only over-invalidates (fail-safe — re-review, never skip).
	if git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
		return 1
	fi
	echo "pre-push-pipeline-gate: force-push detected for $branch — invalidating graduation marker" >&2
	# #2483: WARN (don't fail) when marker removal fails — enforcement for THIS
	# push is already guaranteed by the caller's _grad_forced flag (graduation
	# short-circuit bypassed; the gate then requires the Phase 1 log walk or a
	# fresh CR-CLI findings=0 verdict for the NEW sha), but a persisting marker
	# would silently re-graduate a FUTURE fast-forward push, so the operator
	# must see it.
	if ! graduation_invalidate "$branch"; then
		echo "pre-push-pipeline-gate: WARN — graduation_invalidate failed for $branch (re-review IS enforced for this push via _grad_forced; the stale marker persists and will wrongly graduate the next fast-forward push — remove it manually: see _lib/phase-graduation.sh graduation_marker_path)" >&2
	fi
	return 0
}

# #2483: content-based staleness check for the graduation short-circuit. The
# marker certifies Phase 0.5/1 at graduated_sha; if that sha is no longer an
# ancestor of the pushed sha, history was REWRITTEN through a path the
# event-based detectors above cannot see — a create-push (all-zeros remote) is
# never a force-push, and a fast-forward push after amending a never-pushed
# tip keeps the remote an ancestor. Ancestry is the authoritative signal.
# rc 0 = STALE (caller invalidates + runs the full gate) · rc 1 = the marker
# exists and still describes an ancestor of the pushed sha. Fail-closed: a
# MISSING, unreadable, or unparseable marker and an unresolvable graduated_sha
# ALL count as STALE — re-review, never skip (the missing case is a TOCTOU
# guard; the caller checks graduation_check first). `graduation_marker_path`
# must be in scope (caller sources phase-graduation.sh). Defined above the
# SOURCED_FOR_TEST early-return so bats can exercise it in isolation.
_grad_marker_stale() {
	local branch=${1:-} local_sha=${2:-}
	{ [ -n "$branch" ] && [ -n "$local_sha" ]; } || return 0 # fail-safe: stale
	local path gsha
	path=$(graduation_marker_path "$branch" 2>/dev/null) || return 0
	# CR #2485: a MISSING marker is fail-closed STALE too. The only caller runs
	# right after graduation_check confirmed the file exists, so this is a
	# TOCTOU guard (marker invalidated between the two checks ⇒ re-review) and
	# keeps the helper self-contained fail-closed for any future caller.
	[ -f "$path" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0 # cannot parse → fail-safe stale
	gsha=$(jq -r '.graduated_sha // empty' "$path" 2>/dev/null) || return 0
	[ -n "$gsha" ] || return 0 # malformed marker → fail-safe stale
	if git merge-base --is-ancestor "$gsha" "$local_sha" 2>/dev/null; then
		return 1 # graduated_sha still in the pushed history → marker valid
	fi
	return 0 # rewritten past the graduation point → stale
}

# v4.29 #792: hoist MIN_CLEAN_STREAK above SOURCED_FOR_TEST early-return
# so bats can assert the default behaviorally (was source-grep only).
MIN_CLEAN_STREAK="${PHASE1_MIN_CLEAN_STREAK:-1}"

[ "${SOURCED_FOR_TEST:-0}" = "1" ] && return 0

# #2263: fail CLOSED when the repo root is unresolvable — whether git
# rev-parse FAILED (the `|| REPO_ROOT=""` keeps set -e from exiting with git's
# opaque rc=128) or returned empty. A pre-push hook is always invoked inside a
# work tree, so an unresolvable REPO_ROOT is pathological — refuse the push with
# a clear diagnostic rather than BYPASS the gate (old: exit 0) or die cryptically.
# The SOURCED_FOR_TEST guard above returns before this, so tests are unaffected.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
if [ -z "$REPO_ROOT" ]; then
	echo "pre-push-pipeline-gate: cannot resolve repo root (git rev-parse --show-toplevel failed or returned empty) — refusing to bypass the pipeline gate; failing closed" >&2
	exit 1
fi

# v0.31 #228: surface hook-wiring drift at the push checkpoint (fail-soft).
_orphan_hook_advisory "$REPO_ROOT"

LOG_DIR="$REPO_ROOT/.claude/review-log"
ZERO="0000000000000000000000000000000000000000"

if [ "${PIPELINE_GATE_SKIP:-0}" = "1" ]; then
	echo "pre-push-pipeline-gate: PIPELINE_GATE_SKIP=1 set — bypassing gate" >&2
	# v4.23-O (#561): log each bypass so routine use surfaces. Routine
	# bypass = defeating the point of the gate; data from this log feeds
	# the session-start-report warning + the I/J/K enforcement design.
	# #2545: the append moved to the shared _lib/pipeline-skip.sh writer —
	# one row shape for every gate (this producer emits gate:"pre-push",
	# the phase2 round-cap emits gate:"phase2-round-cap") so the report
	# can segment overrides instead of conflating them.
	# #2567-r2 (deferred to this batch): NO AUDIT ROW → NO BYPASS. This
	# gate is the last line protecting origin, and the audit row is the
	# only durable record that the operator approved this specific skip —
	# an unlogged bypass is indistinguishable from a silent one. The
	# prior warn-and-proceed contradicted the cap-override writers in
	# ship-pr-cycle.sh, which already refuse UNLOGGED overrides; this
	# aligns the last gate with that fail-closed contract.
	_ppg_skip_lib="$PPG_DIR/../_lib/pipeline-skip.sh"
	_ppg_skip_sourced=0
	if [ -r "$_ppg_skip_lib" ]; then
		# shellcheck source=../_lib/pipeline-skip.sh
		# Source failures surface distinctly (phase2 r2: 2>/dev/null || true
		# swallowed them into the generic 'unavailable' fallback below —
		# a broken lib and an absent lib are different repairs).
		if . "$_ppg_skip_lib"; then
			_ppg_skip_sourced=1
		else
			echo "pre-push-pipeline-gate: WARN: sourcing _lib/pipeline-skip.sh returned non-zero — the audit writer is unavailable" >&2
		fi
	fi
	# p2r1: require the SOURCED shell function specifically — `command -v`
	# is also satisfied by a PATH executable named pipeline_skip_log, so a
	# same-named binary could stand in for the audit writer. declare -F
	# matches only functions, and the sourced flag pins where it came from.
	if [ "$_ppg_skip_sourced" = "1" ] && declare -F pipeline_skip_log >/dev/null 2>&1; then
		if ! pipeline_skip_log "pre-push"; then
			echo "pre-push-pipeline-gate: ERROR: bypass audit append FAILED (see writer error above) — refusing an UNLOGGED bypass (fix .claude/logs perms, or drop PIPELINE_GATE_SKIP)" >&2
			exit 1
		fi
	else
		echo "pre-push-pipeline-gate: ERROR: _lib/pipeline-skip.sh unavailable — refusing an UNLOGGED bypass (fix the plugin install, or drop PIPELINE_GATE_SKIP)" >&2
		exit 1
	fi
	exit 0
fi

FAILED=0
while read -r local_ref local_sha _remote_ref remote_sha; do
	[ -z "$local_sha" ] && continue
	[ "$local_sha" = "$ZERO" ] && continue # branch deletion
	# v4.4.E: tag refs don't go through the review pipeline — they point at
	# an already-merged commit that ALREADY had its review-log checked
	# during the branch-merge push. Re-gating on tag push would require
	# PIPELINE_GATE_SKIP=1 every `git push origin vX.Y.Z`, which was caught
	# during v4.3.0 release dogfood.
	#
	# v4.22 PR-A (#521): tag refs DO get a separate tag-eligibility gate.
	# Distinct from the review-log gate — this one verifies the code is
	# actually deployable (milestone closed, deploy-verify passed,
	# fusion-e2e passed). Closes the "tag ≠ deployed-state" hole from #530.
	# Bypass: PIPELINE_GATE_SKIP=1 git push --tags (emergency only).
	case "$local_ref" in
	refs/tags/v[0-9]*)
		tag_name="${local_ref#refs/tags/}"
		# REPO_ROOT + gate path from the top-of-file declarations —
		# PIPELINE_GATE_SKIP=1 already exited at L34 so no re-check here.
		GATE="$REPO_ROOT/.claude/scripts/deploy/tag-eligibility.sh"
		if [ -x "$GATE" ]; then
			if ! "$GATE" "$tag_name" >&2; then
				echo "" >&2
				echo "pre-push-pipeline-gate: tag $tag_name failed deploy-eligibility checks (see above)" >&2
				echo "  Emergency bypass: PIPELINE_GATE_SKIP=1 git push --tags" >&2
				FAILED=1
			fi
		fi
		continue
		;;
	refs/tags/*)
		# Non-version tags (e.g. rc-candidates, annotations) skip eligibility.
		continue
		;;
	esac

	# v4.29 #792: branch-graduation delegation. Once a branch passes Phase
	# 0.5 + Phase 1 (one clean round), the marker is written and further
	# commits on the branch skip the per-SHA Phase 1 log walk. Phase 2 is
	# still required per-push via the CR CLI clean check below. code-reviewer
	# r1 conf 9: derive the graduation branch from the pushed ref (local_ref),
	# not workspace HEAD — multi-ref pushes must apply graduation per-ref.
	_grad_branch="${local_ref#refs/heads/}"
	[ "$_grad_branch" = "$local_ref" ] && _grad_branch=""
	_grad_lib="$PPG_DIR/../_lib/phase-graduation.sh"
	if [ -n "$_grad_branch" ] && [ -r "$_grad_lib" ]; then
		# shellcheck source=/dev/null
		. "$_grad_lib"
		# #2295: invalidate a stale graduation marker on force-push BEFORE the
		# short-circuit below reads it. Runs regardless of PHASE1_MIN_ROUNDS so
		# an override push can't leave a stale marker behind for a later
		# non-override push to honor (the lib is sourced for this path too).
		# The call is in an `if` (NOT bare): rc=1 "not a force-push" is the
		# COMMON path, and a bare call under `set -e` would abort the whole gate
		# on every fast-forward push. _grad_forced records detection so a
		# force-push ALSO bypasses the graduation short-circuit below even if the
		# marker rm failed — detection must ENFORCE re-review, not just attempt
		# invalidation and then trust graduation_check to come up empty.
		_grad_forced=0
		if _grad_invalidate_on_force_push "$_grad_branch" "$remote_sha" "$local_sha" "$ZERO"; then
			_grad_forced=1
		fi
		if [ "$_grad_forced" = 0 ] && [ -z "${PHASE1_MIN_ROUNDS:-}" ] && graduation_check "$_grad_branch"; then
			# #2483: content-based staleness gate. The event detectors above
			# miss a create-push (all-zeros remote) and a fast-forward push
			# after amending a never-pushed tip; in both, a stale marker would
			# wrongly skip Phase 1 for rewritten, never-re-reviewed code. If
			# graduated_sha is no longer an ancestor of the pushed sha, the
			# marker certifies discarded history: invalidate + full gate.
			if _grad_marker_stale "$_grad_branch" "$local_sha"; then
				echo "pre-push-pipeline-gate: graduation marker for $_grad_branch is STALE (graduated_sha is not an ancestor of $local_sha — history rewritten); invalidating + running the full gate" >&2
				if ! graduation_invalidate "$_grad_branch"; then
					echo "pre-push-pipeline-gate: WARN — graduation_invalidate failed for $_grad_branch (this push still runs the full gate; remove the marker manually — see _lib/phase-graduation.sh graduation_marker_path)" >&2
				fi
			else
				echo "pre-push-pipeline-gate: branch $_grad_branch graduated past Phase 0.5/1 — skipping log walk (Phase 2 still required)" >&2
				# Still enforce Phase 2 cleanliness for current SHA.
				if ! _cr_cli_clean_for_sha "$local_sha"; then
					echo "  Phase 2 not clean for $local_sha — run \`coderabbit review --agent -t committed --base main\` and address findings." >&2
					FAILED=1
				fi
				continue
			fi
		fi
	fi

	# v4.23-A: compute MIN_ROUNDS per pushed ref using its local_sha.
	MIN_ROUNDS="${PHASE1_MIN_ROUNDS:-$(_auto_scale_min_rounds "$local_sha")}"

	# v4.24-Q3 (#610): full gate delegation to CR CLI when it has a
	# findings=0 verdict for this SHA. CR CLI uses the same engine as
	# CR-in-CI; a clean verdict means the Phase 2 review passed against
	# the actual code. Phase 1 rounds are the scaler's call (covered by
	# #609 delegation), and when scaler says rounds=1 with CR clean,
	# requiring a separate review-log is busywork — the CR CLI log
	# IS the evidence. Honor override via PHASE1_MIN_ROUNDS env so
	# explicit overrides (tests, manual reviews) still enforce the full
	# log-walk. Only auto-delegate when MIN_ROUNDS came from the scaler.
	if [ -z "${PHASE1_MIN_ROUNDS:-}" ] && _cr_cli_clean_for_sha "$local_sha"; then
		echo "pre-push-pipeline-gate: CR CLI clean for $local_sha (findings=0) — full delegation, skipping review-log walk" >&2
		continue
	fi

	# v4.24-Q3: cap MIN_CLEAN_STREAK at MIN_ROUNDS. When the scaler says 1
	# round is enough but the operator raised the streak (the pre-#792
	# default of 2 made this contradiction the default posture), you can't
	# have 2 consecutive clean rounds in 1 total round. Cap ensures the
	# streak is reachable given the round count. (#2486: default is 1.)
	EFFECTIVE_STREAK="$MIN_CLEAN_STREAK"
	if [ "$MIN_ROUNDS" -lt "$EFFECTIVE_STREAK" ]; then
		EFFECTIVE_STREAK="$MIN_ROUNDS"
	fi

	LOG="$LOG_DIR/${local_sha}.jsonl"
	if [ ! -f "$LOG" ]; then
		echo "pre-push-pipeline-gate: no review log for $local_sha" >&2
		echo "  Run Phase 1 agents + Phase 2 CR CLI before pushing." >&2
		echo "  Log-append helper: .claude/hooks/review-log.sh" >&2
		FAILED=1
		continue
	fi

	# Phase 2 entry present?
	if ! jq -e 'select(.phase == 2)' "$LOG" >/dev/null 2>&1; then
		echo "pre-push-pipeline-gate: no Phase 2 entry in $LOG" >&2
		echo "  Run coderabbit review locally + log via review-log.sh phase2 ..." >&2
		FAILED=1
		continue
	fi

	# v4.15.C hardened check: expected-vs-actual agents per round + rounds-count + clean-streak.
	LIST_SCRIPT="$PPG_DIR/list-phase1-agents.sh"
	if [ ! -x "$LIST_SCRIPT" ]; then
		echo "pre-push-pipeline-gate: $LIST_SCRIPT missing — cannot determine expected agents" >&2
		FAILED=1
		continue
	fi
	if ! EXPECTED=$("$LIST_SCRIPT" main | sort -u); then
		echo "pre-push-pipeline-gate: list-phase1-agents.sh failed — failing closed" >&2
		FAILED=1
		continue
	fi
	if [ -z "$EXPECTED" ]; then
		echo "pre-push-pipeline-gate: list-phase1-agents.sh returned no agents — config broken?" >&2
		FAILED=1
		continue
	fi

	# v4.15.Y: aggregate across all commits on branch since main — not just
	# local_sha's log. Rounds persist as (sha, round) tuples.
	COLLECT="$PPG_DIR/_phase1-collect-logs.sh"
	if [ ! -x "$COLLECT" ]; then
		echo "pre-push-pipeline-gate: $COLLECT missing" >&2
		FAILED=1
		continue
	fi
	# v4.15.Z: fail-closed + surface collector stderr.
	if ! COMBINED=$("$COLLECT" main); then
		echo "pre-push-pipeline-gate: collector failed — failing closed" >&2
		FAILED=1
		continue
	fi
	if [ -n "$COMBINED" ] && ! printf '%s\n' "$COMBINED" | jq empty >/dev/null 2>&1; then
		echo "pre-push-pipeline-gate: aggregated JSONL malformed" >&2
		FAILED=1
		continue
	fi
	TUPLES=$(printf '%s\n' "$COMBINED" | jq -r 'select(.phase==1 and .round!=null) | "\(.sha)|\(.round)"' | awk '!seen[$0]++')
	ROUND_COUNT=0
	[ -n "$TUPLES" ] && ROUND_COUNT=$(printf '%s\n' "$TUPLES" | wc -l | tr -d ' ')

	if [ "$ROUND_COUNT" -lt "$MIN_ROUNDS" ]; then
		echo "pre-push-pipeline-gate: only $ROUND_COUNT Phase 1 invocation(s) across branch (minimum: $MIN_ROUNDS)" >&2
		echo "  Run more rounds — each re-reviews the whole git diff main..HEAD." >&2
		FAILED=1
		continue
	fi

	# Walk tuples newest-to-oldest; accumulate clean streak across commits.
	CLEAN_STREAK=0
	BROKEN_AT=""
	for tuple in $(printf '%s\n' "$TUPLES" | awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'); do
		tsha="${tuple%%|*}"
		tround="${tuple##*|}"
		RE=$(printf '%s\n' "$COMBINED" | jq -c --arg s "$tsha" --arg r "$tround" 'select(.phase==1 and .sha==$s and (.round|tostring)==$r)')
		LOGGED=$(printf '%s\n' "$RE" | jq -r '.agent' | sort -u)
		MISSING=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$LOGGED"))
		if [ -n "$MISSING" ]; then
			BROKEN_AT="invocation ${tsha:0:8}@round${tround}: missing agents: $(echo "$MISSING" | tr '\n' ',' | sed 's/,$//')"
			break
		fi
		# v4.28-W4 PR-C: mirror phase1-before-cr.sh's not-installed clean
		# predicate (the parallel hook ships this fix; pre-push-pipeline-gate
		# was missed and rejects convergence the same way phase1-before-cr
		# did before PR #755 r4). phase1-launcher.sh tells operators to log
		# security-review as `0 not-installed` when the skill isn't
		# installed; treat that as clean here too.
		# v4.30 #772: also accept `not-applicable` (auto-logged by
		# phase1-launcher for file-type-filtered agents).
		DIRTY=$(printf '%s\n' "$RE" | jq -c 'select((.findings // 0) != 0 or (.status != "ok" and .status != "not-installed" and .status != "not-applicable"))')
		if [ -n "$DIRTY" ]; then
			BROKEN_AT="invocation ${tsha:0:8}@round${tround}: not all-clean"
			break
		fi
		CLEAN_STREAK=$((CLEAN_STREAK + 1))
		[ "$CLEAN_STREAK" -ge "$EFFECTIVE_STREAK" ] && break
	done

	if [ "$CLEAN_STREAK" -lt "$EFFECTIVE_STREAK" ]; then
		echo "pre-push-pipeline-gate: Phase 1 not convergent for $local_sha" >&2
		echo "  Need $EFFECTIVE_STREAK consecutive clean rounds (capped by MIN_ROUNDS=$MIN_ROUNDS, ceiling=$MIN_CLEAN_STREAK), have $CLEAN_STREAK." >&2
		echo "  Last break: ${BROKEN_AT:-unknown}" >&2
		echo "  Expected agents: $(echo "$EXPECTED" | tr '\n' ',' | sed 's/,$//')" >&2
		FAILED=1
		continue
	fi

	# v4.23-J (#556): check 5 — every .sh in diff has a bats pass at
	# current content hash. Complements v4.23-I commit-gate by catching
	# "committed via bypass OR amended without re-testing" cases.
	# Accepts either:
	#   (a) fresh pass (<1h) — normal case, just ran tests
	#   (b) baseline-blessed pass (<7d + baseline:true) — weekly cron covers
	#       scripts you didn't touch locally
	BATS_LOG="$REPO_ROOT/.claude/logs/bats-run.jsonl"
	base_ref=$(_base_ref "$local_sha") || {
		echo "pre-push-pipeline-gate: v4.23-J check 5 — cannot determine base ref, failing closed" >&2
		FAILED=1
		continue
	}
	CHANGED_SH=$(git diff --name-only "${base_ref}..${local_sha}" 2>/dev/null | grep -E '\.sh$' || true)
	# Filter to in-scope paths only. Append with a preceding-newline only
	# if INSCOPE_SH is already non-empty — avoids the leading-blank-line
	# that the prior `INSCOPE_SH="${INSCOPE_SH}${sh}\n"` pattern produced.
	INSCOPE_SH=""
	# (#2642) Scope from _lib/bats-scope.sh. The local copy here listed
	# consumer paths, so this gate — which hashes the blob and demands a
	# recorded pass at THAT content, the strongest check in the repo — was
	# guarding 22% of production.
	#
	# FAIL CLOSED: an unloadable predicate would leave INSCOPE_SH empty,
	# and an empty in-scope set reads as "nothing needs verifying", which
	# passes every push.
	if ! command -v bats_in_scope >/dev/null 2>&1; then
		echo "pre-push-pipeline-gate: ERROR: _lib/bats-scope.sh did not load — refusing to push with an unknown scope (an empty scope would pass every push silently). Fix the plugin install." >&2
		FAILED=1
		continue
	fi
	while IFS= read -r sh; do
		[ -z "$sh" ] && continue
		if bats_in_scope "$sh"; then
			if [ -z "$INSCOPE_SH" ]; then
				INSCOPE_SH="$sh"
			else
				INSCOPE_SH="$INSCOPE_SH
$sh"
			fi
		fi
	done <<<"$CHANGED_SH"
	if [ -n "$INSCOPE_SH" ] && [ ! -f "$BATS_LOG" ]; then
		echo "pre-push-pipeline-gate: v4.23-J check 5 — .sh files changed but $BATS_LOG missing" >&2
		echo "  Run: scripts/test.sh (at least once to initialize the log)" >&2
		FAILED=1
		continue
	fi
	if [ -f "$BATS_LOG" ] && [ -n "$INSCOPE_SH" ]; then
		NOW_S=$(date -u +%s)
		CUTOFF_1H=$((NOW_S - 3600))
		CUTOFF_7D=$((NOW_S - 604800))
		UNVERIFIED=""
		while IFS= read -r sh; do
			[ -z "$sh" ] && continue
			# Skip deleted files (blob no longer exists at local_sha)
			if ! git cat-file -e "${local_sha}:${sh}" 2>/dev/null; then
				continue
			fi
			# Skip files with bats-required:0 (check the blob at local_sha, not working tree)
			if git show "${local_sha}:${sh}" 2>/dev/null | head -5 | grep -qE '^#[[:space:]]*bats-required:[[:space:]]*0\b'; then
				continue
			fi
			# Compute current content hash from the blob at local_sha
			SH_HASH=""
			if command -v sha256sum >/dev/null 2>&1; then
				SH_HASH=$(git show "${local_sha}:${sh}" 2>/dev/null | sha256sum | awk '{print $1}')
			elif command -v shasum >/dev/null 2>&1; then
				SH_HASH=$(git show "${local_sha}:${sh}" 2>/dev/null | shasum -a 256 | awk '{print $1}')
			fi
			[ -n "$SH_HASH" ] || continue
			# Look for matching pass: fresh OR baseline-blessed
			found=$(jq -r --arg p "$sh" --arg h "$SH_HASH" \
				--argjson fresh "$CUTOFF_1H" --argjson baseline_cutoff "$CUTOFF_7D" '
				select(
					.status == "pass" and
					((.tested_files // []) | any(.path == $p and .hash == $h))
				) |
				(.ts | fromdateiso8601? // 0) as $ts |
				select(
					$ts > $fresh or
					((.baseline // false) and $ts > $baseline_cutoff)
				) |
				.ts
			' "$BATS_LOG" 2>/dev/null | tail -1)
			if [ -z "$found" ]; then
				UNVERIFIED="${UNVERIFIED}
    $sh"
			fi
		done <<<"$INSCOPE_SH"
		if [ -n "$UNVERIFIED" ]; then
			echo "pre-push-pipeline-gate: v4.23-J check 5 — .sh content not verified by bats:${UNVERIFIED}" >&2
			echo "  Run scripts/test.sh <matching-bats> OR rely on weekly baseline cron (check: scripts/install-bats-baseline-scheduler.sh --verify)" >&2
			FAILED=1
			continue
		fi
	fi
done

if [ "$FAILED" -eq 1 ]; then
	echo "" >&2
	echo "Push refused. Bypass with PIPELINE_GATE_SKIP=1 git push ..." >&2
	# r7 Option E: write per-ack diagnostic artifact at a known location
	# (always exists; carries the diagnostic operator needs to address +
	# clear). Prior version passed review-log/${HEAD_SHA}.jsonl which DID
	# NOT exist when the failure mode was "log missing" → Read-to-clear
	# deadlock. The diagnostic file replaces that paradox.
	LIB_HOOK_ACK="$PPG_DIR/../_lib/hook-ack.sh"
	# shellcheck source=../_lib/hook-ack.sh
	[ -f "$LIB_HOOK_ACK" ] && source "$LIB_HOOK_ACK"
	if command -v hook_ack_append >/dev/null 2>&1 &&
		command -v hook_ack_diagnostic_write >/dev/null 2>&1; then
		HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
		BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
		diag=$(hook_ack_diagnostic_write "pre-push-pipeline-gate" "push-refused" \
			"# pre-push-pipeline-gate refused the push.

HEAD: $HEAD_SHA
Branch: $BRANCH

# What the gate checks
- A Phase 1 review-log exists for the SHA being pushed
- Phase 2 (CR-CLI) ran cleanly for that SHA
- ≥ MIN_ROUNDS Phase 1 rounds with the last MIN_CLEAN_STREAK clean
- All expected agents per .claude/hooks/list-phase1-agents.sh ran

# Where to look
- Review-log for this SHA (may not exist yet — that's often the cause):
  .claude/review-log/${HEAD_SHA}.jsonl
- Most recent round directives:
  .claude/hooks/phase1-launcher.sh \$NEXT_ROUND
- Push-skip audit log: .claude/logs/pipeline-skip.jsonl

# How to fix
1. Run Phase 0.5 + Phase 1 rounds until the required clean streak (default 1) converges
2. Run Phase 2 CR-CLI cleanly
3. Re-attempt the push

# Bypass (audit-logged, used sparingly)
PIPELINE_GATE_SKIP=1 git push ...
")
		[ -n "$diag" ] && hook_ack_append "pre-push-pipeline-gate" "push-refused" "$diag"
	fi
	exit 1
fi

exit 0
