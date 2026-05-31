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
#   0 — composed (written or printed)
#   2 — precondition error (yq missing, base missing/unparseable, overlay
#       present-but-unparseable, write failure)

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
	# Deep-merge: overlay scalars win, arrays append. Pass the overlay path via
	# the environment so a path with metacharacters can't break the yq filter.
	if ! result=$(OVL="$OVERLAY" yq '. *+ load(strenv(OVL))' "$BASE" 2>&1); then
		echo "compose-coderabbit: yq merge failed:" >&2
		printf '%s\n' "$result" >&2
		exit 2
	fi
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
