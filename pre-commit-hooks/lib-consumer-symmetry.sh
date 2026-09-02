#!/bin/bash
set -euo pipefail
# lib-consumer-symmetry — surface a shared-library contract change that lands
# on one of N consumers but not the others (#2644, #2653; epic #2640).
#
# Anchor case: on branch fix/v0.34.228, a guard landed on one of two callers
# of _lib/issue-trailers.sh FOUR times; the fourth (a788b2f) shipped a real
# regression — `${ISSUE_TRAILER_MAX:-50}` became a bare `$ISSUE_TRAILER_MAX`
# in one caller while the sibling's dependency gate never learned to require
# the variable. The library-keyed trigger ("you changed _lib/X.sh, sweep the
# consumers") is structurally blind to it: a788b2f did not touch the library
# at all. Detection must be CONSUMER-side (trigger B, validated 14/16
# counterfactuals on that branch — see #2644).
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
# Consumer discovery is `git grep --cached`, NEVER `grep -r`: .claude/_lib,
# .claude/hooks and .claude/scripts are untracked symlinks into the root, so
# a filesystem walk returns log JSONL, .source-hashes.json and bats files as
# "consumers". The cached form returns exactly the real ones (#2644 repro).
# All sourcing idioms in this repo name the literal basename somewhere in
# the consumer file, so basename matching is sound — but it cannot tell
# sourcing from prose, hence the owned-symbol requirement in layer 1.
#
# WARN-ONLY this cycle (#2644 "ship warn-only, count fires, then flip the
# fan-out ≤3 band to blocking"): findings print + append to the fires
# ledger (.claude/logs/lib-consumer-symmetry.jsonl) and the hook exits 0.
# LIB_CONSUMER_SYMMETRY_ENFORCE=1 flips findings to exit 1 (the planned
# default once the ledger review lands). Tool failures ALWAYS exit 2 — a
# warn that silently could not look is indistinguishable from clean, which
# is the reporting-without-performing class this epic exists to kill. The
# ledger append itself fails closed (exit 2): the ledger is the data the
# warn cycle exists to collect.
#
# Known blind spot, stated plainly (#2644): identifier-text driven, so a
# semantic change that alters no identifier (sort order, dedup behavior)
# passes. That still needs the shared-contract test; this is the cheap
# mechanical prompt layered under it.
#
# Env:
#   LIB_CONSUMER_SYMMETRY_SKIP=1          bypass for one invocation.
#   LIB_CONSUMER_SYMMETRY_SKIP_REASON=…   rationale, recorded with it.
#   LIB_CONSUMER_SYMMETRY_ENFORCE=1       findings exit 1 instead of 0.
#
# Exit: 0 clean or warn-only findings · 1 findings under ENFORCE=1 · 2 the
# gate could not run (not a git repo, unreadable index blob, git/grep
# failure, unwritable ledger). 1-vs-2 per bats-assertion-gate.sh:37-47.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "lib-consumer-symmetry: not in a git repo" >&2
	exit 2
}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# This file names library basenames and owned identifiers by necessity (the
# token map, this header) — it must never count as a consumer of them, or
# the gate fires on its own commit forever.
SELF_PATH="pre-commit-hooks/lib-consumer-symmetry.sh"

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
	PIPELINE_GATE_SKIP_REASON="${LIB_CONSUMER_SYMMETRY_SKIP_REASON:-}" \
		pipeline_skip_log "lib-consumer-symmetry-skip" || {
		echo "lib-consumer-symmetry: skip audit append failed — refusing the skip" >&2
		exit 2
	}
	exit 0
fi

LEDGER="$REPO_ROOT/.claude/logs/lib-consumer-symmetry.jsonl"
FINDINGS=0
_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)

# _ledger_row <layer> <lib> <consumer> <detail> <unstaged-csv> <fanout>
_ledger_row() {
	mkdir -p "$(dirname "$LEDGER")" || {
		echo "lib-consumer-symmetry: cannot create ledger dir — the warn cycle's data cannot be dropped" >&2
		exit 2
	}
	jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg layer "$1" \
		--arg lib "$2" --arg consumer "$3" --arg detail "$4" \
		--arg unstaged "$5" --arg fanout "$6" --arg branch "$_BRANCH" \
		--arg mode "${LIB_CONSUMER_SYMMETRY_ENFORCE:+enforce}" \
		'{ts: $ts, layer: $layer, lib: $lib, consumer: $consumer,
		  detail: $detail, unstaged: $unstaged, fanout: $fanout,
		  branch: $branch, mode: (if $mode == "" then "warn" else $mode end)}' \
		>>"$LEDGER" || {
		echo "lib-consumer-symmetry: ledger append FAILED ($LEDGER) — refusing to warn unrecorded" >&2
		exit 2
	}
}

# _consumers_of <lib-path> — tracked .sh files whose INDEX blob names the
# lib's basename, excluding the lib itself, this gate, and tests. rc 1 (no
# match) is a normal empty result; rc >=2 is a tool failure.
_consumers_of() {
	local _lib="$1" _rc=0 _out
	_out=$(git grep --cached -l --fixed-strings "$(basename "$_lib")" -- \
		'*.sh' ":(exclude)$_lib" ":(exclude)$SELF_PATH" \
		':(exclude).claude/tests/*' 2>/dev/null) || _rc=$?
	if [ "$_rc" -ge 2 ]; then
		echo "lib-consumer-symmetry: git grep --cached failed (rc $_rc) enumerating consumers of $_lib" >&2
		exit 2
	fi
	printf '%s\n' "$_out"
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

# Mapped libraries, newline-delimited — the ONE list layer 2 iterates.
# _required_tokens_for must return a non-empty token set for every entry;
# that is checked at run time (empty set for a mapped lib = map drift =
# exit 2), so this list and the case arms below cannot desync silently
# (phase0.5 on this branch: two parallel structures, no validation).
_LCS_TOKEN_LIBS='_lib/issue-trailers.sh'

# Required guard tokens per mapped library (#2653). Newline-delimited fixed
# strings; the single authoritative copy — consumers must each carry every
# line verbatim. Add libraries by extending _LCS_TOKEN_LIBS AND adding a
# case arm here (the run-time check catches doing only one).
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
trap 'rm -f "$_staged_tmp"' EXIT
if ! git -C "$REPO_ROOT" diff --cached --name-only --no-renames \
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

cd "$REPO_ROOT"

# All tracked libraries (the INDEX view, so a lib added in this very commit
# participates immediately).
_libs=$(git ls-files --cached -- '_lib/*.sh') || {
	echo "lib-consumer-symmetry: git ls-files failed enumerating _lib" >&2
	exit 2
}

# ---- layer 1: staging symmetry (trigger B, #2644) -------------------------
for _c in "${STAGED[@]}"; do
	[ "$_c" = "$SELF_PATH" ] && continue
	case "$_c" in .claude/tests/*) continue ;; esac
	_c_blob=$(_index_blob "$_c")
	# The diff itself fails closed (phase0.5: `diff | grep || true` under
	# pipefail swallowed a git failure identically to the benign no-match);
	# only the greps' rc-1 no-match is tolerated.
	_diff_out=$(git diff --cached -U0 --no-renames -- "$_c") || {
		echo "lib-consumer-symmetry: git diff --cached failed for $_c" >&2
		exit 2
	}
	# +/- hunk lines of the staged change, context stripped.
	_hunk=$(printf '%s\n' "$_diff_out" |
		grep -E '^[+-]' | grep -Ev '^\+\+\+|^---' || true)
	[ -n "$_hunk" ] || continue
	while IFS= read -r _lib; do
		[ -n "$_lib" ] || continue
		[ "$_lib" = "$_c" ] && continue
		# Prefilter: the consumer names the lib's basename at all.
		printf '%s' "$_c_blob" | grep -qF "$(basename "$_lib")" || continue
		# Identifiers OWNED by the lib: top-level `name()` or `UPPER=`.
		_owned=$(_index_blob "$_lib" | sed -n \
			-e 's/^\([A-Za-z_][A-Za-z0-9_]*\)().*/\1/p' \
			-e 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' | sort -u)
		[ -n "$_owned" ] || continue
		_hit_sym=""
		while IFS= read -r _sym; do
			[ -n "$_sym" ] || continue
			if printf '%s\n' "$_hunk" |
				grep -Eq "(^|[^A-Za-z0-9_])${_sym}([^A-Za-z0-9_]|$)"; then
				_hit_sym="$_sym"
				break
			fi
		done <<<"$_owned"
		[ -n "$_hit_sym" ] || continue
		# The staged consumer touches an owned symbol — are the siblings
		# staged too?
		_siblings=$(_consumers_of "$_lib")
		_fanout=0
		_unstaged=""
		while IFS= read -r _sib; do
			[ -n "$_sib" ] || continue
			_fanout=$((_fanout + 1))
			[ "$_sib" = "$_c" ] && continue
			_is_staged "$_sib" || _unstaged="${_unstaged:+$_unstaged,}$_sib"
		done <<<"$_siblings"
		[ -n "$_unstaged" ] || continue
		FINDINGS=$((FINDINGS + 1))
		_band=""
		[ "$_fanout" -gt 3 ] && _band=" [high fan-out: stays advisory after the enforce flip]"
		echo "lib-consumer-symmetry: $_c touches '$_hit_sym' (owned by $_lib) but sibling consumer(s) NOT staged: $_unstaged (fan-out $_fanout)$_band" >&2
		echo "  If the siblings are already correct, say so in the commit message; if not, this is the a788b2f regression shape (#2644)." >&2
		_ledger_row "staging" "$_lib" "$_c" "$_hit_sym" "$_unstaged" "$_fanout"
	done <<<"$_libs"
done

# ---- layer 2: guard-token symmetry (#2653) --------------------------------
while IFS= read -r _lib; do
	[ -n "$_lib" ] || continue
	git cat-file -e ":0:$_lib" 2>/dev/null || continue
	_toks=$(_required_tokens_for "$_lib")
	if [ -z "$_toks" ]; then
		echo "lib-consumer-symmetry: mapped lib $_lib has no token set — _LCS_TOKEN_LIBS and _required_tokens_for drifted, fix the map" >&2
		exit 2
	fi
	_consumers=$(_consumers_of "$_lib")
	[ -n "$_consumers" ] || continue
	# Scoped to commits that touch the mapped surface: the lib or one of
	# its consumers must be staged, else this commit cannot have moved
	# their symmetry.
	_touched=0
	_is_staged "$_lib" && _touched=1
	if [ "$_touched" -eq 0 ]; then
		while IFS= read -r _cons; do
			[ -n "$_cons" ] || continue
			if _is_staged "$_cons"; then
				_touched=1
				break
			fi
		done <<<"$_consumers"
	fi
	[ "$_touched" -eq 1 ] || continue
	while IFS= read -r _cons; do
		[ -n "$_cons" ] || continue
		_cons_blob=$(_index_blob "$_cons")
		while IFS= read -r _tok; do
			[ -n "$_tok" ] || continue
			printf '%s' "$_cons_blob" | grep -qF -- "$_tok" && continue
			FINDINGS=$((FINDINGS + 1))
			echo "lib-consumer-symmetry: $_cons is missing required guard token for $_lib: $_tok" >&2
			echo "  Every consumer carries every token (single list in this gate, #2653) — the sibling already has it." >&2
			_ledger_row "token" "$_lib" "$_cons" "$_tok" "" ""
		done <<<"$_toks"
	done <<<"$_consumers"
done <<<"$_LCS_TOKEN_LIBS"

# ---- verdict --------------------------------------------------------------
if [ "$FINDINGS" -gt 0 ]; then
	echo "lib-consumer-symmetry: $FINDINGS finding(s) — ledger: .claude/logs/lib-consumer-symmetry.jsonl" >&2
	if [ "${LIB_CONSUMER_SYMMETRY_ENFORCE:-0}" = "1" ]; then
		exit 1
	fi
	echo "lib-consumer-symmetry: WARN-ONLY cycle (#2644) — not blocking this commit." >&2
fi
exit 0
