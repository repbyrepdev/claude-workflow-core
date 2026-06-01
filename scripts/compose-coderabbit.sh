#!/bin/bash
set -euo pipefail
# Compose a repo's .coderabbit.yaml from the canonical base + per-repo overlay.
# #234 (Wave H) — the AI-reviewer analog of the Wave G .github byte-SSOT.
#
#   .coderabbit.yaml = .coderabbit.base.yaml  [ *+ .coderabbit.overlay.yaml ]
#
# Merge semantics (yq `*+`): overlay SCALARS win; overlay ARRAYS append to the
# base arrays (so a repo's domain area:* labels / path rules EXTEND the base,
# never silently drop it); base-only keys are preserved. With NO overlay (a
# fresh repo), the base is emitted verbatim (comments preserved) — that IS the
# new-repo starter config.
#
# The BASE is byte-SSOT (hashed: true in scripts/bootstrap-manifest.yml →
# Wave G hash-drift gates + propagates it). The OVERLAY and the COMPOSED
# .coderabbit.yaml are per-repo (NOT gated): a repo owns its domain bits.
#
# Usage:
#   scripts/compose-coderabbit.sh --base <path> [--overlay <path>] [--out <path>]
#     --base     required; the canonical .coderabbit.base.yaml
#     --overlay  optional; per-repo .coderabbit.overlay.yaml (absent/empty ⇒
#                base verbatim)
#     --out      optional; write here atomically (.new + mv). Default: stdout.
#
# Exit codes:
#   0 — composed (written or printed). A present-but-NON-mapping overlay
#       (empty / comments-only / unparseable) is NON-fatal: a NOTE is emitted
#       and the base is used verbatim (exit 0).
#   2 — precondition error: yq missing, base missing / not-a-mapping, an
#       overlay that would clobber a base mapping-key with a non-mapping
#       (deep-merge would gut the subtree), or a write failure.

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
