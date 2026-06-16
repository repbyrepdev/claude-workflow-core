#!/bin/bash
set -euo pipefail
# Compose a repo's .coderabbit.yaml from the canonical base + per-repo overlay.
# #234 (Wave H) — the AI-reviewer analog of the Wave G .github byte-SSOT.
#
#   .coderabbit.yaml = .coderabbit.base.yaml  [ *+ .coderabbit.overlay.yaml ]
#
# Merge semantics (yq `*+`): overlay SCALARS win; overlay ARRAYS append to the
# base arrays (so a repo's domain area:* labels / path rules EXTEND the base,
# never silently drop it); base-only keys are preserved. The composed config is
# then post-processed (#2254): a per-file `!.claude/hooks/<name>` exclusion is
# appended to reviews.auto_review.path_filters for every CANONICAL hook (the
# sibling hooks/ set) so CR-in-CI skips the byte-identical mirror hooks a
# consumer carries. With NO overlay AND no resolvable sibling hooks/ dir, the
# base is emitted verbatim (comments preserved) — the new-repo starter case.
#
# The BASE is byte-SSOT (hashed: true in scripts/bootstrap-manifest.yml →
# Wave G hash-drift gates + propagates it). The OVERLAY and the COMPOSED
# .coderabbit.yaml are per-repo (NOT gated): a repo owns its domain bits.
#
# Usage:
#   scripts/compose-coderabbit.sh --base <path> [--overlay <path>] [--out <path>]
#     --base     required; the canonical .coderabbit.base.yaml
#     --overlay  optional; per-repo .coderabbit.overlay.yaml (absent/empty ⇒
#                base + the #2254 canonical-hook exclusions; byte-verbatim only
#                when ALSO no sibling hooks/ dir is resolvable)
#     --out      optional; write here atomically (.new + mv). Default: stdout.
#
# Exit codes:
#   0 — composed (written or printed). A present-but-NON-mapping overlay
#       (empty / comments-only / unparseable) is NON-fatal: a NOTE is emitted
#       and the base is used verbatim (exit 0).
#   2 — precondition error: yq missing, base missing / not-a-mapping, an
#       overlay that would clobber a base mapping-key with a non-mapping
#       (deep-merge would gut the subtree), or a write failure.

# Resolve this script's own dir so we can enumerate the sibling canonical
# hooks/ set for the CR-in-CI mirror-hook exclusion (#2254). The `|| SCRIPT_DIR=""`
# keeps a resolution failure NON-FATAL under `set -e`: a bare `SCRIPT_DIR=$(cd …)`
# whose subshell fails would abort the whole compose, so this falls back to an
# empty value and the injection guard below skips cleanly (base verbatim).
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || SCRIPT_DIR=""

BASE=""
OVERLAY=""
OUT=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--base)
		[ -n "${2:-}" ] || {
			echo "compose-coderabbit: --base requires a path" >&2
			exit 2
		}
		BASE=$2
		shift 2
		;;
	--overlay)
		[ -n "${2:-}" ] || {
			echo "compose-coderabbit: --overlay requires a path" >&2
			exit 2
		}
		OVERLAY=$2
		shift 2
		;;
	--out)
		[ -n "${2:-}" ] || {
			echo "compose-coderabbit: --out requires a path" >&2
			exit 2
		}
		OUT=$2
		shift 2
		;;
	-h | --help)
		grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "compose-coderabbit: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

command -v yq >/dev/null 2>&1 || {
	echo "compose-coderabbit: yq required" >&2
	exit 2
}

[ -n "$BASE" ] || {
	echo "compose-coderabbit: --base is required" >&2
	exit 2
}
[ -f "$BASE" ] || {
	echo "compose-coderabbit: base not found: $BASE" >&2
	exit 2
}
yq -e 'tag == "!!map"' "$BASE" >/dev/null 2>&1 || {
	echo "compose-coderabbit: base is not a valid YAML mapping: $BASE" >&2
	exit 2
}

# Determine whether a usable overlay exists. An absent OR empty overlay
# (whitespace/comments only ⇒ yq tag != !!map) ⇒ emit base verbatim.
_overlay_usable() {
	[ -n "$OVERLAY" ] && [ -f "$OVERLAY" ] || return 1
	yq -e 'tag == "!!map"' "$OVERLAY" >/dev/null 2>&1
}

result=""
if _overlay_usable; then
	# yq stderr → a temp file, NOT into the captured stdout var (#234 r2 cr
	# minor): a yq warning merged via `2>&1` would corrupt the composed config
	# / the clobber list. Capture stdout only; surface stderr on failure.
	yqerr=$(mktemp -t compose-cr-yqerr.XXXXXX) || {
		echo "compose-coderabbit: mktemp failed" >&2
		exit 2
	}
	# Type-clobber guard (#234 r2 cr MAJOR — now RECURSIVE): _overlay_usable
	# only checks the overlay's TOP level is a map. An overlay that turns a base
	# MAPPING at ANY depth into a non-mapping (e.g. `reviews: "x"` OR
	# `reviews: {auto_review: "x"}`) would, under `*+`, let the overlay value WIN
	# and silently gut that subtree. Detect it: every map-path present in base
	# must remain a map after merge (set-difference of base-map-paths minus
	# merged-map-paths). Fail CLOSED before composing.
	if ! clobbered=$(BASEF="$BASE" OVL="$OVERLAY" yq -n '
		load(strenv(BASEF)) as $b | load(strenv(OVL)) as $o | ($b *+ $o) as $m
		| ([ $b | .. | select(tag == "!!map") | (path | join(".")) ]) as $bm
		| ([ $m | .. | select(tag == "!!map") | (path | join(".")) ]) as $mm
		| ($bm - $mm) | join(" ")
	' 2>"$yqerr"); then
		echo "compose-coderabbit: failed validating overlay type-compatibility:" >&2
		cat "$yqerr" >&2
		rm -f "$yqerr"
		exit 2
	fi
	if [ -n "$clobbered" ]; then
		echo "compose-coderabbit: overlay turns base mapping path(s) into a non-mapping" >&2
		echo "  (deep-merge would silently gut the base subtree): $clobbered" >&2
		echo "  Keep those paths as mappings in the overlay, or override leaf scalars instead." >&2
		rm -f "$yqerr"
		exit 2
	fi
	# Deep-merge: overlay scalars win, arrays append. Overlay path via env so a
	# path with metacharacters can't break the yq filter.
	if ! result=$(OVL="$OVERLAY" yq '. *+ load(strenv(OVL))' "$BASE" 2>"$yqerr"); then
		echo "compose-coderabbit: yq merge failed:" >&2
		cat "$yqerr" >&2
		rm -f "$yqerr"
		exit 2
	fi
	rm -f "$yqerr"
elif [ -n "$OVERLAY" ] && [ -f "$OVERLAY" ]; then
	# Overlay present but not a mapping (empty / comments only) — use base
	# verbatim, but tell the operator so a malformed overlay isn't silent.
	echo "compose-coderabbit: NOTE: overlay $OVERLAY has no mapping content — using base verbatim" >&2
	result=$(cat "$BASE")
else
	# No overlay → base verbatim (preserves header comments; byte-identical).
	result=$(cat "$BASE")
fi

# #2254/#2257/#2427: CR-in-CI canonical-MIRROR exclusion. .claude/hooks/ +
# .claude/_lib/ carry byte-identical plugin mirrors a consumer cannot modify
# (hash-drift forbids it), so re-reviewing them is the "verbatim treadmill"
# that floods every consumer re-pin PR. CR-in-CI is server-side + glob-only and
# (empirically, #2241) IGNORES a `!.claude/_lib/**` dir-glob while honoring
# EXACT-PATH per-file `!<dir>/<name>` excludes — so emit a per-file exclusion
# for every CANONICAL file (sibling hooks/ + _lib/ — the authoritative set,
# resolvable from a dev-checkout OR the pinned cache) whose consumer mirror is
# BYTE-IDENTICAL. Consumer-OVERRIDDEN (differ) + consumer-AUTHORED (no canonical
# sibling) files stay REVIEWED — no blind spot. Idempotent: recomputed each run.
#
# _emit_canonical_exclusions <canonical_dir> <consumer_dir> <yaml_path_prefix>
#   stdout: newline-sorted `!<prefix><name>` for each *.sh in <canonical_dir>
#           whose <consumer_dir>/<name> is absent OR byte-identical (cmp -s).
#   rc 0 = enumerated (list may be empty); rc 2 = cd into canonical dir failed.
# Absent consumer file → exclude (byte-identical mirror assumed). cmp rc 1
# (differ) → consumer override → keep reviewed. cmp rc>=2 (error) → keep
# reviewed + WARN (fail SAFE toward more review; rc captured via `|| _c=$?` so a
# bare `cmp; _c=$?` cannot abort under set -e). Called in $(...) so the `cd` is
# isolated to the command-substitution subshell.
_emit_canonical_exclusions() {
	local _canon=$1 _consumer=$2 _prefix=$3 _f _c
	cd "$_canon" || return 2
	for _f in *.sh; do
		[ -e "$_f" ] || continue
		if [ -e "$_consumer/$_f" ]; then
			_c=0
			cmp -s "$_f" "$_consumer/$_f" || _c=$?
			if [ "$_c" -eq 1 ]; then
				continue
			elif [ "$_c" -ge 2 ]; then
				echo "compose-coderabbit: WARNING: cmp failed comparing canonical '$_canon/$_f' to consumer mirror (rc=$_c); keeping it REVIEWED (not excluded)" >&2
				continue
			fi
		fi
		printf '!%s%s\n' "$_prefix" "$_f"
	done | LC_ALL=C sort
}

# Resolve the consumer repo root ONCE — the dir CONTAINING the output
# .coderabbit.yaml when --out is given, else $PWD; normalized to absolute so a
# relative value still compares the right files (#2257 r2). The per-dir env
# overrides (COMPOSE_CR_CONSUMER_{HOOKS,LIB}_DIR) win below for tests.
_consumer_root="${OUT:+$(dirname "$OUT")}"
_consumer_root="${_consumer_root:-$PWD}"
case "$_consumer_root" in /*) ;; *) _consumer_root="$PWD/$_consumer_root" ;; esac

# Two canonical-mirror dirs get per-file exclusions: hooks/ (MIXED — only
# byte-identical mirrors excluded, consumer-authored stay reviewed) and _lib/
# (#2241 — PURE mirror, but per-file because CR-in-CI drops the dir-glob).
# COMPOSE_CR_{HOOKS,LIB}_DIR override the canonical dir; with no override + empty
# SCRIPT_DIR the dir is empty and the guard skips cleanly. Enumeration failure
# fails CLOSED (exit 2) — a silently-empty list would re-enable the treadmill.
_all_excl=""
_hooks_canon="${COMPOSE_CR_HOOKS_DIR:-${SCRIPT_DIR:+$SCRIPT_DIR/../hooks}}"
if [ -n "$_hooks_canon" ] && [ -d "$_hooks_canon" ]; then
	_hooks_consumer="${COMPOSE_CR_CONSUMER_HOOKS_DIR:-$_consumer_root/.claude/hooks}"
	case "$_hooks_consumer" in /*) ;; *) _hooks_consumer="$PWD/$_hooks_consumer" ;; esac
	[ -d "$_hooks_consumer" ] || echo "compose-coderabbit: NOTE: consumer hooks dir '$_hooks_consumer' not found — every canonical hook will be excluded; set COMPOSE_CR_CONSUMER_HOOKS_DIR (or run from the consumer repo root) if that is wrong" >&2
	if ! _hx=$(_emit_canonical_exclusions "$_hooks_canon" "$_hooks_consumer" ".claude/hooks/"); then
		echo "compose-coderabbit: failed enumerating canonical hooks in $_hooks_canon" >&2
		exit 2
	fi
	[ -n "$_hx" ] && _all_excl="${_all_excl:+$_all_excl
}$_hx"
fi
_lib_canon="${COMPOSE_CR_LIB_DIR:-${SCRIPT_DIR:+$SCRIPT_DIR/../_lib}}"
if [ -n "$_lib_canon" ] && [ -d "$_lib_canon" ]; then
	_lib_consumer="${COMPOSE_CR_CONSUMER_LIB_DIR:-$_consumer_root/.claude/_lib}"
	case "$_lib_consumer" in /*) ;; *) _lib_consumer="$PWD/$_lib_consumer" ;; esac
	[ -d "$_lib_consumer" ] || echo "compose-coderabbit: NOTE: consumer _lib dir '$_lib_consumer' not found — every canonical _lib file will be excluded; set COMPOSE_CR_CONSUMER_LIB_DIR (or run from the consumer repo root) if that is wrong" >&2
	if ! _lx=$(_emit_canonical_exclusions "$_lib_canon" "$_lib_consumer" ".claude/_lib/"); then
		echo "compose-coderabbit: failed enumerating canonical _lib in $_lib_canon" >&2
		exit 2
	fi
	[ -n "$_lx" ] && _all_excl="${_all_excl:+$_all_excl
}$_lx"
fi

if [ -n "$_all_excl" ]; then
	_yqe=$(mktemp -t compose-cr-excl.XXXXXX) || {
		echo "compose-coderabbit: mktemp failed for canonical-mirror exclusion pass" >&2
		exit 2
	}
	if ! result=$(printf '%s\n' "$result" | EXCL="$_all_excl" yq '
		.reviews.auto_review.path_filters =
			((.reviews.auto_review.path_filters // []) +
				(strenv(EXCL) | split("\n") | map(select(. != "")))) |
		.reviews.auto_review.path_filters head_comment =
			"#2254/#2257/#2427: the trailing !.claude/hooks/<name> + !.claude/_lib/<name> entries are per-file canonical-mirror exclusions auto-appended by compose-coderabbit.sh (byte-identical mirrors ONLY; consumer-overridden/authored files stay reviewed). CR-in-CI ignores the !.claude/_lib/** dir-glob (#2241) so per-file is required. Earlier entries are from base/overlay. Regenerated each compose."
	' 2>"$_yqe"); then
		echo "compose-coderabbit: failed appending canonical-mirror exclusions:" >&2
		cat "$_yqe" >&2
		rm -f "$_yqe"
		exit 2
	fi
	rm -f "$_yqe"
fi

if [ -n "$OUT" ]; then
	mkdir -p "$(dirname "$OUT")"
	tmp=$(mktemp "$OUT.XXXXXX") || {
		echo "compose-coderabbit: mktemp failed for $OUT" >&2
		exit 2
	}
	if ! printf '%s\n' "$result" >"$tmp"; then
		echo "compose-coderabbit: write to temp failed" >&2
		rm -f "$tmp"
		exit 2
	fi
	mv "$tmp" "$OUT" || {
		echo "compose-coderabbit: atomic mv failed for $OUT" >&2
		rm -f "$tmp"
		exit 2
	}
	echo "compose-coderabbit: wrote $OUT" >&2
else
	printf '%s\n' "$result"
fi
