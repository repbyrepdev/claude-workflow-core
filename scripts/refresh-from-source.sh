#!/bin/bash
set -euo pipefail
# v0.21.0 (#151) — producer→consumer cascade primitive.
#
# Copies plugin SSOT files (every path in .claude/.source-hashes.json)
# into a consumer directory, honoring the consumer's local-overrides.yml
# skip-list. Atomic per-file. Re-runnable. Writes an audit log.
#
# Usage:
#   scripts/refresh-from-source.sh --consumer <name>          # by consumers.yml name
#   scripts/refresh-from-source.sh --consumer-path <path>     # by absolute path
#   scripts/refresh-from-source.sh --all-consumers            # iterate consumers.yml
#   scripts/refresh-from-source.sh --dry-run                  # show what would change
#   scripts/refresh-from-source.sh --files file1,file2        # subset
#
# Exit codes:
#   0 — refresh succeeded (or dry-run completed)
#   2 — precondition error (missing yq/jq, consumer not found, bad args,
#       parse failure on consumers.yml / local-overrides.yml /
#       .source-hashes.json)
#   3 — partial failure (some file copies failed mid-cascade — audit log
#       lists which; consumer left in inconsistent state, manual recovery
#       required)
#
# Deferred behaviors (gated on other unshipped subs):
#   - settings.json re-render via templates/settings.json.tpl — Sub 12
#   - Post-cascade hash-drift.sh --verify validation — Sub 10
#   Both are TODO no-ops here; the cascade copy logic stands alone.

CONSUMER=""
CONSUMER_PATH=""
ALL_CONSUMERS=0
DRY_RUN=0
FILES_FILTER=""

while [ $# -gt 0 ]; do
	case "$1" in
	--consumer)
		[ $# -lt 2 ] && {
			echo "refresh-from-source: --consumer requires a name" >&2
			exit 2
		}
		CONSUMER=$2
		shift 2
		;;
	--consumer-path)
		[ $# -lt 2 ] && {
			echo "refresh-from-source: --consumer-path requires a path" >&2
			exit 2
		}
		CONSUMER_PATH=$2
		shift 2
		;;
	--all-consumers)
		ALL_CONSUMERS=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--files)
		[ $# -lt 2 ] && {
			echo "refresh-from-source: --files requires a comma-separated list" >&2
			exit 2
		}
		FILES_FILTER=$2
		shift 2
		;;
	-h | --help)
		# Emit the leading comment header as usage text. Same pattern as
		# scripts/list-consumers.sh --help.
		awk '
			NR == 1 { next }
			/^set / { next }
			/^# (event|auto-register):/ { next }
			/^#/ { in_header = 1; sub(/^# ?/, ""); print; next }
			NF == 0 && in_header { print; next }
			in_header { exit }
		' "$0"
		exit 0
		;;
	*)
		echo "refresh-from-source: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

# Mutual-exclusion validation: exactly ONE of --consumer / --consumer-path
# / --all-consumers must be set.
N_TARGETS=0
[ -n "$CONSUMER" ] && N_TARGETS=$((N_TARGETS + 1))
[ -n "$CONSUMER_PATH" ] && N_TARGETS=$((N_TARGETS + 1))
[ "$ALL_CONSUMERS" -eq 1 ] && N_TARGETS=$((N_TARGETS + 1))
if [ "$N_TARGETS" -eq 0 ]; then
	echo "refresh-from-source: must specify ONE of --consumer / --consumer-path / --all-consumers" >&2
	exit 2
fi
if [ "$N_TARGETS" -gt 1 ]; then
	echo "refresh-from-source: --consumer / --consumer-path / --all-consumers are mutually exclusive" >&2
	exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
REGISTRY="$PLUGIN_ROOT/.github/consumers.yml"
HASHES="$PLUGIN_ROOT/.claude/.source-hashes.json"

[ -f "$REGISTRY" ] || {
	echo "refresh-from-source: $REGISTRY missing (Sub 3 must ship)" >&2
	exit 2
}
[ -f "$HASHES" ] || {
	echo "refresh-from-source: $HASHES missing (Sub 2 must ship)" >&2
	exit 2
}

for cmd in yq jq; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "refresh-from-source: $cmd required" >&2
		exit 2
	}
done

yq_err=$(mktemp -t rfs-yq.XXXXXX) || {
	echo "refresh-from-source: mktemp failed" >&2
	exit 2
}
# shellcheck disable=SC2329,SC2317
_cleanup() { rm -f "$yq_err"; }
trap _cleanup EXIT INT TERM HUP

_resolve_consumer_path() {
	# Resolve --consumer <name> against consumers.yml; expand ~/.
	local name=$1
	local consumers_json
	if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
		echo "refresh-from-source: yq failed parsing $REGISTRY:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	local found
	found=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .local_path' <<<"$consumers_json")
	if [ -z "$found" ] || [ "$found" = "null" ]; then
		echo "refresh-from-source: consumer '$name' not found in $REGISTRY" >&2
		exit 2
	fi
	# Expand leading ~. shellcheck flags SC2088 (tilde doesn't expand
	# in quotes) but the intent here is to match a LITERAL '~/' prefix
	# in YAML-loaded text, then strip it manually. Disable applies to
	# the whole function.
	# shellcheck disable=SC2088
	case "$found" in
	"~/"*) found="$HOME/${found#"~/"}" ;;
	"~") found="$HOME" ;;
	esac
	printf '%s' "$found"
}

_list_all_consumer_paths() {
	# Emit one consumer-path per line (expanded).
	local consumers_json
	if ! consumers_json=$(yq -o=json '.consumers' "$REGISTRY" 2>"$yq_err"); then
		echo "refresh-from-source: yq failed parsing $REGISTRY:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
	# shellcheck disable=SC2088
	jq -r '.[].local_path' <<<"$consumers_json" | while read -r p; do
		case "$p" in
		"~/"*) p="$HOME/${p#"~/"}" ;;
		"~") p="$HOME" ;;
		esac
		printf '%s\n' "$p"
	done
}

_load_overrides_paths() {
	# Read consumer's .claude/local-overrides.yml; emit one skip-path per
	# line. Empty if the file doesn't exist.
	local cpath=$1
	local ov="$cpath/.claude/local-overrides.yml"
	[ -f "$ov" ] || return 0
	if ! yq -r '.overrides // [] | .[].path' "$ov" 2>"$yq_err"; then
		echo "refresh-from-source: yq failed parsing $ov:" >&2
		cat "$yq_err" >&2
		exit 2
	fi
}

_refresh_one_consumer() {
	local cpath=$1
	if [ ! -d "$cpath" ]; then
		echo "refresh-from-source: consumer path $cpath does not exist" >&2
		return 2
	fi

	echo "==> Refresh: $cpath"

	# Build skip-list from consumer's overrides (one path per line).
	local overrides
	overrides=$(_load_overrides_paths "$cpath")

	# Materialize the SSOT path list (every file in .source-hashes.json).
	local ssot_paths
	if ! ssot_paths=$(jq -r '.files | keys[]' "$HASHES" 2>"$yq_err"); then
		echo "refresh-from-source: jq failed reading $HASHES:" >&2
		cat "$yq_err" >&2
		return 2
	fi

	local n_clean=0 n_replaced=0 n_overridden=0 n_failed=0
	local files_replaced_list=""
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local plugin_version
	plugin_version=$(jq -r '.version' "$PLUGIN_ROOT/.claude-plugin/plugin.json")

	# Filter to --files subset if requested.
	local filter_arr=()
	if [ -n "$FILES_FILTER" ]; then
		IFS=',' read -ra filter_arr <<<"$FILES_FILTER"
	fi
	_is_in_filter() {
		local f=$1
		[ "${#filter_arr[@]}" -eq 0 ] && return 0
		local x
		for x in "${filter_arr[@]}"; do
			[ "$x" = "$f" ] && return 0
		done
		return 1
	}

	while IFS= read -r relpath; do
		[ -n "$relpath" ] || continue
		_is_in_filter "$relpath" || continue

		# Overrides skip — consumer's path may or may not have the
		# `.claude/` prefix on the SSOT-tracked file. Plugin tracks paths
		# like `_lib/foo.sh`; consumer mirrors at `.claude/_lib/foo.sh`.
		# Check both forms in the overrides list.
		local consumer_rel=".claude/${relpath}"
		if echo "$overrides" | grep -Fxq "$consumer_rel" || echo "$overrides" | grep -Fxq "$relpath"; then
			n_overridden=$((n_overridden + 1))
			echo "  [OVERRIDE] $relpath"
			continue
		fi

		local src="$PLUGIN_ROOT/$relpath"
		local dst="$cpath/$consumer_rel"

		if [ ! -f "$src" ]; then
			echo "  [SKIP] $relpath (source missing in plugin)"
			continue
		fi

		# Existing consumer copy hash vs plugin source hash.
		local src_hash dst_hash
		src_hash=$(shasum -a 256 "$src" | awk '{print $1}')
		if [ -f "$dst" ]; then
			dst_hash=$(shasum -a 256 "$dst" | awk '{print $1}')
		else
			dst_hash="(missing)"
		fi

		if [ "$src_hash" = "$dst_hash" ]; then
			n_clean=$((n_clean + 1))
			continue
		fi

		# Differs — copy atomically (.new + mv).
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "  [DIFF] $relpath (would copy; src=${src_hash:0:8} dst=${dst_hash:0:8})"
			n_replaced=$((n_replaced + 1))
			continue
		fi

		mkdir -p "$(dirname "$dst")"
		if ! cp "$src" "$dst.new"; then
			echo "  [FAIL] $relpath (cp source → .new failed)" >&2
			n_failed=$((n_failed + 1))
			continue
		fi
		if ! mv "$dst.new" "$dst"; then
			echo "  [FAIL] $relpath (atomic mv .new → live failed)" >&2
			rm -f "$dst.new"
			n_failed=$((n_failed + 1))
			continue
		fi
		# Preserve executable bit if source is executable.
		[ -x "$src" ] && chmod +x "$dst"
		echo "  [REPLACED] $relpath (dst=${dst_hash:0:8} → src=${src_hash:0:8})"
		n_replaced=$((n_replaced + 1))
		files_replaced_list="${files_replaced_list}${relpath}\\n"
	done <<<"$ssot_paths"

	# Audit log to consumer.
	if [ "$DRY_RUN" -eq 0 ]; then
		local audit_dir="$cpath/.claude/logs"
		mkdir -p "$audit_dir"
		local audit_file="$audit_dir/refresh-from-source.jsonl"
		local entry
		entry=$(jq -cn --arg ts "$now" --arg pv "$plugin_version" \
			--argjson clean "$n_clean" \
			--argjson replaced "$n_replaced" \
			--argjson overridden "$n_overridden" \
			--argjson failed "$n_failed" \
			--arg cpath "$cpath" \
			'{ts: $ts, plugin_version: $pv, consumer_path: $cpath, files_clean: $clean, files_replaced: $replaced, files_overridden: $overridden, files_failed: $failed}')
		printf '%s\n' "$entry" >>"$audit_file"
	fi

	echo "  Summary: clean=$n_clean replaced=$n_replaced overridden=$n_overridden failed=$n_failed"

	# TODO (deferred to other unshipped subs):
	#   * Re-render consumer's settings.json from templates/settings.json.tpl
	#     (Sub 12) — preserves operator-only voice/marketplace sections.
	#   * Post-cascade `hash-drift.sh --verify` (Sub 10) to confirm zero
	#     drift on cascade-target paths.

	if [ "$n_failed" -gt 0 ]; then
		return 3
	fi
	return 0
}

# Resolve target consumer paths.
target_paths=()
if [ -n "$CONSUMER" ]; then
	target_paths+=("$(_resolve_consumer_path "$CONSUMER")")
elif [ -n "$CONSUMER_PATH" ]; then
	target_paths+=("$CONSUMER_PATH")
elif [ "$ALL_CONSUMERS" -eq 1 ]; then
	while IFS= read -r p; do
		[ -n "$p" ] && target_paths+=("$p")
	done < <(_list_all_consumer_paths)
fi

overall_rc=0
for p in "${target_paths[@]}"; do
	rc=0
	_refresh_one_consumer "$p" || rc=$?
	if [ "$rc" -ne 0 ]; then
		overall_rc=$rc
	fi
done

exit "$overall_rc"
