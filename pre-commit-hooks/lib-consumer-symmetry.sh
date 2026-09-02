#!/bin/bash
set -euo pipefail
# lib-consumer-symmetry — surface a shared-library contract change that lands
# on one of N consumers but not the others (#2644, #2653; epic #2640).
#
# Anchor case: on branch fix/v0.34.228, a guard landed on one of two callers
# of _lib/issue-trailers.sh FOUR times; the fourth (a788b2f) shipped a real
# regression — `${ISSUE_TRAILER_MAX:-50}` became a bare `$ISSUE_TRAILER_MAX`
# in one caller whose OWN dependency gate never learned to require the
# variable (the sibling's gate already did — that asymmetry is exactly the
# shape this gate exists to catch). The library-keyed trigger ("you changed
# _lib/X.sh, sweep the consumers") is structurally blind to it: a788b2f did
# not touch the library at all. Detection must be CONSUMER-side (trigger B,
# validated 14/16 counterfactuals on that branch — see #2644).
#
# Two layers:
#
#   1. STAGING symmetry (trigger B, #2644): a staged .sh consumer C of
#      _lib/X.sh whose staged hunk +/- lines mention an identifier OWNED by
#      X (top-level `^name()` or `^UPPER_CASE=` in X's INDEX blob) while a
#      sibling consumer of X is NOT staged → finding naming the sibling.
#   2. GUARD-TOKEN symmetry (#2653): a per-library map of required guard
#      tokens (for _lib/issue-trailers.sh: the guarded `. "$_it_lib"`
#      source, the ISSUE_TRAILER_MAX numeric check, the `command -v
#      issue_trailers_for_pr` symbol probe). When the library or any of its
#      consumers is staged, every consumer's INDEX blob must contain every
#      token → finding per missing token. Consumers are DISCOVERED, never
#      listed — a checked-in consumer registry would need its own staleness
#      gate (#2644 "no manifest"), and the token list lives once, here.
#
# A "consumer" needs POSITIVE EVIDENCE in both layers: naming the lib's
# basename AND referencing at least one identifier the lib owns. Basename
# alone cannot tell sourcing from prose (#2644 measured a 25% overcount on
# hook-ack.sh), and layer 2 imposing tokens on a prose-mentioner would
# manufacture findings for files that never call the library.
#
# Consumer discovery is `git grep --cached`, NEVER `grep -r`: .claude/_lib,
# .claude/hooks and .claude/scripts are untracked symlinks into the root, so
# a filesystem walk returns log JSONL, .source-hashes.json and bats files as
# "consumers". The cached form returns exactly the real ones (#2644 repro).
# Library enumeration is anchored to the tracked top-level `_lib/*.sh`
# layout — repos without that layout (plain consumer installs run gates from
# the plugin cache against their own tree) enumerate zero libs and both
# layers no-op; the gate is meaningful where _lib/*.sh is tracked.
#
# WARN-ONLY this cycle (#2644 "ship warn-only, count fires, then flip the
# fan-out ≤3 band to blocking"): findings print + append to the fires
# ledger (.claude/logs/lib-consumer-symmetry.jsonl) and the hook exits 0.
# LIB_CONSUMER_SYMMETRY_ENFORCE=1 makes ENFORCEABLE findings exit 1 —
# staging findings in the fan-out ≤3 band and token findings; high-fan-out
# staging findings stay advisory even then, as their own message says
# (#2644: not all high-fan-out fires are false, but they only buy a look).
# Tool failures ALWAYS exit 2 — a warn that silently could not look is
# indistinguishable from clean, which is the reporting-without-performing
# class this epic exists to kill. The ledger append itself fails closed
# (exit 2): the ledger is the data the warn cycle exists to collect.
#
# Known blind spot, stated plainly (#2644): identifier-text driven, so a
# semantic change that alters no identifier (sort order, dedup behavior)
# passes. That still needs the shared-contract test; this is the cheap
# mechanical prompt layered under it.
#
# Env:
#   LIB_CONSUMER_SYMMETRY_SKIP=1          bypass for one invocation.
#   LIB_CONSUMER_SYMMETRY_SKIP_REASON=…   rationale, recorded with it.
#   LIB_CONSUMER_SYMMETRY_ENFORCE=1       enforceable findings exit 1.
#
# Exit: 0 clean or warn-only findings · 1 enforceable findings under
# ENFORCE=1 · 2 the gate could not run (not a git repo, unreadable index
# blob, git/grep failure, unwritable ledger). 1-vs-2 per
# bats-assertion-gate.sh:37-47.
#
# Requires git >= 2.19 (the `--output-indicator-*` diff options used for
# unambiguous hunk prefixes). Older git rejects the flag, the diff call
# fails, and the gate exits 2 with the git error visible — attributable,
# never a silent downgrade.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "lib-consumer-symmetry: not in a git repo" >&2
	exit 2
}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ "${LIB_CONSUMER_SYMMETRY_SKIP:-0}" = "1" ]; then
	echo "lib-consumer-symmetry: SKIPPED via LIB_CONSUMER_SYMMETRY_SKIP=1" >&2
	# Skip is recorded through the shared writer; an unrecordable skip does
	# not happen (symlink-write-guard precedent: an unlogged bypass is not a
	# bypass this gate offers). The lib resolves script-relative so consumer
	# installs keep working; missing lib refuses the skip, not the gate.
	if [ ! -r "$SCRIPT_DIR/../_lib/pipeline-skip.sh" ]; then
		echo "lib-consumer-symmetry: _lib/pipeline-skip.sh missing — cannot record the skip, refusing it" >&2
		exit 2
	fi
	# shellcheck source=../_lib/pipeline-skip.sh
	. "$SCRIPT_DIR/../_lib/pipeline-skip.sh"
	# pipeline_skip_log honors SKIP_LOG as a test seam; here the same actor
	# invoking the skip controls the environment, so an inherited
	# SKIP_LOG=/dev/null would void the audit row while the skip proceeds
	# (phase1 security review, verified). Pin the target to the default.
	unset SKIP_LOG
	PIPELINE_GATE_SKIP_REASON="${LIB_CONSUMER_SYMMETRY_SKIP_REASON:-}" \
		pipeline_skip_log "lib-consumer-symmetry-skip" || {
		echo "lib-consumer-symmetry: skip audit append failed — refusing the skip" >&2
		exit 2
	}
	exit 0
fi

cd "$REPO_ROOT"

# This file names library basenames and owned identifiers by necessity (the
# token map, this header) — it must never count as a consumer of them, or
# the gate fires on its own commit forever. Derived from our own location so
# a rename cannot silently break the exclusion; literal fallback for runs
# from outside the tracked tree (plugin-cache installs).
# `|| true`: outside the tracked tree git exits 128 ("outside repository")
# and set -e would kill the gate before the fallback could apply.
SELF_PATH=$(git ls-files --cached --full-name -- "${BASH_SOURCE[0]}" 2>/dev/null | head -n1) || true
[ -n "$SELF_PATH" ] || SELF_PATH="pre-commit-hooks/lib-consumer-symmetry.sh"

LEDGER_DIR="$REPO_ROOT/.claude/logs"
LEDGER="$LEDGER_DIR/lib-consumer-symmetry.jsonl"
FINDINGS_ENFORCEABLE=0
FINDINGS_ADVISORY=0
_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
# One mode predicate, used by BOTH the ledger rows and the verdict — the
# two diverging (`:+enforce` labeling vs an exact-"1" verdict) mislabeled
# the dataset the flip decision depends on (phase1 silent-failure-hunter).
_MODE=warn
[ "${LIB_CONSUMER_SYMMETRY_ENFORCE:-0}" = "1" ] && _MODE=enforce

# _ledger_row <layer> <lib> <consumer> <detail> <unstaged-csv> <fanout>
# Uniform 6-field shape across layers (readers segment on .layer).
_ledger_row() {
	mkdir -p "$LEDGER_DIR" || {
		echo "lib-consumer-symmetry: cannot create ledger dir — the warn cycle's data cannot be dropped" >&2
		exit 2
	}
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg layer "$1" \
		--arg lib "$2" --arg consumer "$3" --arg detail "$4" \
		--arg unstaged "$5" --arg fanout "$6" --arg branch "$_BRANCH" \
		--arg mode "$_MODE" \
		'{ts: $ts, layer: $layer, lib: $lib, consumer: $consumer,
		  detail: $detail, unstaged: $unstaged, fanout: $fanout,
		  branch: $branch, mode: $mode}' \
		>>"$LEDGER" || {
		echo "lib-consumer-symmetry: ledger append FAILED ($LEDGER) — refusing to warn unrecorded" >&2
		exit 2
	}
}

# _blob_has <blob> <fixed-string> / _blob_has_re <blob> <ere> — match
# helpers that keep the fail-closed contract: rc 1 (no match) is the only
# tolerated failure; rc >=2 is a tool error and exits 2. Herestrings, not
# `printf | grep -q`: under pipefail, grep -q exiting on an early match
# SIGPIPEs the printf and the pipeline returns 141 — precisely on MATCHING
# pairs — which a bare `|| continue` then swallows as no-match (phase1
# silent-failure-hunter, reproduced 40/40 on large blobs).
_blob_has() {
	local _rc=0
	grep -qF -- "$2" <<<"$1" || _rc=$?
	if [ "$_rc" -ge 2 ]; then
		echo "lib-consumer-symmetry: grep -F failed (rc $_rc)" >&2
		exit 2
	fi
	return "$_rc"
}
_blob_has_re() {
	local _rc=0
	grep -Eq -- "$2" <<<"$1" || _rc=$?
	if [ "$_rc" -ge 2 ]; then
		echo "lib-consumer-symmetry: grep -E failed (rc $_rc)" >&2
		exit 2
	fi
	return "$_rc"
}

# _index_blob <path> — the INDEX version (staged content when staged,
# HEAD content otherwise; a pre-commit gate must judge what will be
# committed, not the worktree — bats-assertion-gate.sh:20-23).
_index_blob() {
	git show ":0:$1" 2>/dev/null || {
		echo "lib-consumer-symmetry: cannot read index blob :0:$1" >&2
		exit 2
	}
}

# _owned_of <lib-path> — identifiers the lib OWNS: top-level `name()` or
# `UPPER_CASE=`. The sed classes guarantee ERE-safe output (word chars
# only), so extracted names can sit inside a grep -E pattern. Memoized in
# a file-backed cache keyed by the flattened lib path (phase2 CR: layer 1
# re-derived the same set for every staged consumer), shared by both
# layers and removed by the EXIT trap.
_owned_of() {
	local _cache="${_OWNED_CACHE_DIR:?}/${1//\//_}"
	if [ ! -f "$_cache" ]; then
		_index_blob "$1" | sed -n \
			-e 's/^\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' \
			-e 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' | sort -u >"$_cache" || exit 2
	fi
	cat "$_cache"
}

# _consumers_of <lib-path> <owned-idents> — tracked .sh files whose INDEX
# blob names the lib's basename AND references at least one owned
# identifier (positive evidence — see header). Excludes the lib itself,
# this gate, and tests. git grep rc 1 (no candidate) is a normal empty
# result; rc >=2 is a tool failure. `-e` pins the basename to pattern
# position and `:(exclude,literal)` disables glob magic in the excludes
# (phase1 security review: a dash- or glob-shaped tracked name must not
# become an option or widen an exclusion).
_consumers_of() {
	local _lib="$1" _owned_list="$2" _rc=0 _out _cand _cand_blob _sym
	# Memoized like _owned_of (phase2 CR r2): both layers ask for the same
	# lib's consumer set; the evidence pass re-reads every candidate blob.
	# An existing (possibly empty) cache file IS the answer.
	local _cache="${_OWNED_CACHE_DIR:?}/consumers_${_lib//\//_}"
	if [ -f "$_cache" ]; then
		cat "$_cache"
		return 0
	fi
	_out=$(git grep --cached -l --fixed-strings -e "${_lib##*/}" -- \
		'*.sh' ":(exclude,literal)$_lib" ":(exclude,literal)$SELF_PATH" \
		':(exclude).claude/tests/*' 2>/dev/null) || _rc=$?
	if [ "$_rc" -ge 2 ]; then
		echo "lib-consumer-symmetry: git grep --cached failed (rc $_rc) enumerating consumers of $_lib" >&2
		exit 2
	fi
	if [ -z "$_out" ] || [ -z "$_owned_list" ]; then
		: >"$_cache"
		return 0
	fi
	while IFS= read -r _cand; do
		[ -n "$_cand" ] || continue
		_cand_blob=$(_index_blob "$_cand")
		while IFS= read -r _sym; do
			[ -n "$_sym" ] || continue
			if _blob_has_re "$_cand_blob" "(^|[^A-Za-z0-9_])${_sym}([^A-Za-z0-9_]|$)"; then
				printf '%s\n' "$_cand"
				break
			fi
		done <<<"$_owned_list"
	done <<<"$_out" >"$_cache"
	cat "$_cache"
	return 0
}

# Mapped libraries, newline-delimited — the ONE list layer 2 iterates.
# The run-time check below is ONE-directional: a list entry whose
# _required_tokens_for arm is missing exits 2, but a case arm added
# WITHOUT extending this list is silently inert — so extend the list
# first, and the empty-set check forces the arm to follow.
_LCS_TOKEN_LIBS='_lib/issue-trailers.sh'

# Required guard tokens per mapped library (#2653). Newline-delimited fixed
# strings; the single authoritative copy — consumers must each carry every
# line verbatim.
_required_tokens_for() {
	case "$1" in
	_lib/issue-trailers.sh)
		printf '%s\n' \
			'. "$_it_lib"' \
			'[[ ${ISSUE_TRAILER_MAX:-} =~ ^[0-9]+$ ]]' \
			'command -v issue_trailers_for_pr'
		;;
	esac
}

# ---- staged set (NUL-safe; git rc checked) --------------------------------
_staged_tmp=$(mktemp -t lcs-staged.XXXXXX) || exit 2
_OWNED_CACHE_DIR=$(mktemp -d -t lcs-owned.XXXXXX) || exit 2
trap 'rm -f "$_staged_tmp"; rm -rf "$_OWNED_CACHE_DIR"' EXIT
if ! git diff --cached --name-only --no-renames \
	--diff-filter=ACMR -z -- '*.sh' >"$_staged_tmp"; then
	echo "lib-consumer-symmetry: git diff --cached failed enumerating staged files" >&2
	exit 2
fi
STAGED=()
while IFS= read -r -d '' _f; do
	STAGED+=("$_f")
done <"$_staged_tmp"
[ "${#STAGED[@]}" -gt 0 ] || exit 0

_is_staged() {
	local _s
	for _s in "${STAGED[@]}"; do
		[ "$_s" = "$1" ] && return 0
	done
	return 1
}

# _any_staged — reads newline paths on stdin; rc 0 if any is staged.
_any_staged() {
	local _p
	while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		if _is_staged "$_p"; then
			return 0
		fi
	done
	return 1
}

# All tracked libraries (the INDEX view, so a lib added in this very commit
# participates immediately). Membership in this rc-checked list is also the
# layer-2 existence test — a separate `git cat-file -e` probe cannot tell
# benign absence from a real git failure (both rc 128; phase1
# silent-failure-hunter).
_libs=$(git ls-files --cached -- '_lib/*.sh') || {
	echo "lib-consumer-symmetry: git ls-files failed enumerating _lib" >&2
	exit 2
}
_lib_tracked() {
	local _l
	while IFS= read -r _l; do
		[ "$_l" = "$1" ] && return 0
	done <<<"$_libs"
	return 1
}

# ---- layer 1: staging symmetry (trigger B, #2644) -------------------------
for _c in "${STAGED[@]}"; do
	[ "$_c" = "$SELF_PATH" ] && continue
	case "$_c" in .claude/tests/*) continue ;; esac
	_c_blob=$(_index_blob "$_c")
	# The diff itself fails closed (phase0.5: `diff | grep || true` under
	# pipefail swallowed a git failure identically to the benign no-match).
	# Custom output indicators (phase2 CR r2): with the default +/-, a
	# DELETED content line whose text begins `--` renders as `---…`,
	# indistinguishable from the file header the next grep strips — the
	# change would be scanned as if that line never moved. O/N/C prefixes
	# cannot collide with any header line. Unsupported flag = git error =
	# exit 2 (visible), not a silent downgrade.
	_diff_out=$(git diff --cached -U0 --no-renames \
		--output-indicator-new=N --output-indicator-old=O \
		--output-indicator-context=C -- "$_c") || {
		echo "lib-consumer-symmetry: git diff --cached failed for $_c" >&2
		exit 2
	}
	# O/N content lines of the staged change, indicator stripped so a
	# symbol at column 0 keeps its word boundary. These commands read
	# their whole input (no -q → no early-exit SIGPIPE); rc 1 (no hunk
	# lines) is the benign case, anything above is a tool error.
	_hunk_rc=0
	_hunk=$(printf '%s\n' "$_diff_out" |
		grep -E '^[ON]' | sed 's/^.//') || _hunk_rc=$?
	if [ "$_hunk_rc" -ge 2 ]; then
		echo "lib-consumer-symmetry: hunk extraction failed (rc $_hunk_rc) for $_c" >&2
		exit 2
	fi
	[ -n "$_hunk" ] || continue
	while IFS= read -r _lib; do
		[ -n "$_lib" ] || continue
		[ "$_lib" = "$_c" ] && continue
		# Prefilter: the consumer names the lib's basename at all.
		_blob_has "$_c_blob" "${_lib##*/}" || continue
		_owned=$(_owned_of "$_lib")
		[ -n "$_owned" ] || continue
		_hit_sym=""
		while IFS= read -r _sym; do
			[ -n "$_sym" ] || continue
			if _blob_has_re "$_hunk" "(^|[^A-Za-z0-9_])${_sym}([^A-Za-z0-9_]|$)"; then
				_hit_sym="$_sym"
				break
			fi
		done <<<"$_owned"
		[ -n "$_hit_sym" ] || continue
		# The staged consumer touches an owned symbol — are the siblings
		# staged too?
		_siblings=$(_consumers_of "$_lib" "$_owned")
		_fanout=0
		_unstaged=""
		while IFS= read -r _sib; do
			[ -n "$_sib" ] || continue
			_fanout=$((_fanout + 1))
			[ "$_sib" = "$_c" ] && continue
			_is_staged "$_sib" || _unstaged="${_unstaged:+$_unstaged,}$_sib"
		done <<<"$_siblings"
		[ -n "$_unstaged" ] || continue
		_band=""
		if [ "$_fanout" -gt 3 ]; then
			_band=" [high fan-out: advisory even under ENFORCE]"
			FINDINGS_ADVISORY=$((FINDINGS_ADVISORY + 1))
		else
			FINDINGS_ENFORCEABLE=$((FINDINGS_ENFORCEABLE + 1))
		fi
		echo "lib-consumer-symmetry: $_c touches '$_hit_sym' (owned by $_lib) but sibling consumer(s) NOT staged: $_unstaged (fan-out $_fanout)$_band" >&2
		echo "  If the siblings are already correct, say so in the commit message; if not, this is the a788b2f regression shape (#2644)." >&2
		_ledger_row "staging" "$_lib" "$_c" "$_hit_sym" "$_unstaged" "$_fanout"
	done <<<"$_libs"
done

# ---- layer 2: guard-token symmetry (#2653) --------------------------------
while IFS= read -r _lib; do
	[ -n "$_lib" ] || continue
	if ! _lib_tracked "$_lib"; then
		# Map-drift probe (phase2 CR + CR-in-CI r1/r2): a mapped lib that
		# is GONE while a tracked script still references its basename in
		# NON-COMMENT lines means the map references a removed/renamed
		# library — silently skipping would produce a clean result
		# forever. Comment-only mentions do not count (the gate's own
		# positive-evidence rule; owned-symbol evidence is impossible for
		# a removed lib, so a non-comment mention is the nearest honest
		# proxy — a lingering comment after a legitimate removal must not
		# wedge every commit). Driven purely by the mapped entry's own
		# evidence — NOT by whether unrelated `_lib/*.sh` files exist
		# (CR-in-CI r2: gating on a non-empty _libs skipped the probe
		# exactly when the removed mapped lib was the LAST one). A tree
		# with no non-comment references no-ops regardless of layout.
		_drift_rc=0
		_drift_cands=$(git grep --cached -l --fixed-strings -e "${_lib##*/}" -- \
			'*.sh' ":(exclude,literal)$SELF_PATH" \
			':(exclude).claude/tests/*' 2>/dev/null) || _drift_rc=$?
		if [ "$_drift_rc" -ge 2 ]; then
			echo "lib-consumer-symmetry: git grep --cached failed (rc $_drift_rc) probing map drift for $_lib" >&2
			exit 2
		fi
		_drift_hit=""
		if [ "$_drift_rc" -eq 0 ]; then
			while IFS= read -r _dc; do
				[ -n "$_dc" ] || continue
				# Strip TRAILING comments before the whole-line delete:
				# an inline `code  # old ref` otherwise survives the
				# strip and hard-blocks every commit, the exact
				# availability bug the comment-only carve-out exists to
				# avoid (backup review r1). Shell starts a comment
				# wherever `#` begins a WORD — after whitespace, or
				# glued to ANY operator character: `;` `&` `|` `(` `)`
				# `{` `}` (CR-in-CI r4 `;#`, r5 `)#` — the class carries
				# the full practical set so the enumeration ends here).
				# Over-strip corners (`#` inside quotes, `${#var}`)
				# under-detect, never wedge.
				_dc_stripped=$(_index_blob "$_dc" |
					sed -E -e 's/[[:space:]]+#.*$//' \
						-e 's/([;&|(){}])[[:space:]]*#.*$/\1/' \
						-e '/^[[:space:]]*#/d') || {
					echo "lib-consumer-symmetry: comment-strip failed for $_dc during drift probe" >&2
					exit 2
				}
				if _blob_has "$_dc_stripped" "${_lib##*/}"; then
					_drift_hit="$_dc"
					break
				fi
			done <<<"$_drift_cands"
		fi
		if [ -n "$_drift_hit" ]; then
			echo "lib-consumer-symmetry: mapped lib $_lib is not tracked but $_drift_hit still references it outside comments — _LCS_TOKEN_LIBS references a removed/renamed library, fix the map" >&2
			exit 2
		fi
		continue
	fi
	_toks=$(_required_tokens_for "$_lib")
	if [ -z "$_toks" ]; then
		echo "lib-consumer-symmetry: mapped lib $_lib has no token set — _LCS_TOKEN_LIBS gained an entry without a _required_tokens_for arm, fix the map" >&2
		exit 2
	fi
	_owned=$(_owned_of "$_lib")
	_consumers=$(_consumers_of "$_lib" "$_owned")
	[ -n "$_consumers" ] || continue
	# Scoped to commits that touch the mapped surface: the lib or one of
	# its consumers must be staged, else this commit cannot have moved
	# their symmetry.
	if ! _is_staged "$_lib" && ! _any_staged <<<"$_consumers"; then
		continue
	fi
	while IFS= read -r _cons; do
		[ -n "$_cons" ] || continue
		_cons_blob=$(_index_blob "$_cons")
		while IFS= read -r _tok; do
			[ -n "$_tok" ] || continue
			_blob_has "$_cons_blob" "$_tok" && continue
			FINDINGS_ENFORCEABLE=$((FINDINGS_ENFORCEABLE + 1))
			echo "lib-consumer-symmetry: $_cons is missing required guard token for $_lib: $_tok" >&2
			echo "  Every consumer carries every token (single list in this gate, #2653) — the sibling already has it." >&2
			_ledger_row "token" "$_lib" "$_cons" "$_tok" "" ""
		done <<<"$_toks"
	done <<<"$_consumers"
done <<<"$_LCS_TOKEN_LIBS"

# ---- verdict --------------------------------------------------------------
_total=$((FINDINGS_ENFORCEABLE + FINDINGS_ADVISORY))
if [ "$_total" -gt 0 ]; then
	echo "lib-consumer-symmetry: $_total finding(s) ($FINDINGS_ENFORCEABLE enforceable, $FINDINGS_ADVISORY advisory) — ledger: .claude/logs/lib-consumer-symmetry.jsonl" >&2
	if [ "$_MODE" = "enforce" ] && [ "$FINDINGS_ENFORCEABLE" -gt 0 ]; then
		exit 1
	fi
	echo "lib-consumer-symmetry: WARN-ONLY (#2644 rollout) — not blocking this commit." >&2
fi
exit 0
