#!/bin/bash
set -euo pipefail
# Introduced in #90 — producer-consumer hash-drift gate.
#
# Detects content drift between plugin-source files (hooks/*.sh,
# _lib/*.sh under the plugin repo root) and consumer-repo siblings
# (.claude/hooks/*.sh, .claude/_lib/*.sh).
#
# Two modes:
#   --generate (producer-side): compute SHA256 of each plugin source
#       file, write to .claude/.source-hashes.json. Committed
#       alongside source so consumers can verify against it after
#       plugin install.
#   --verify (consumer-side): for each entry in
#       <plugin-cache>/.claude/.source-hashes.json, compute the local
#       .claude/hooks|_lib/X.sh hash. Drift → warn.
#
# Override list: .claude/local-overrides.yml at consumer repo root
# (YAML list of `<path>: <reason>` entries). Files in the override
# list are skipped from drift checks.
#
# Usage:
#   scripts/hash-drift.sh --generate         # producer mode
#   scripts/hash-drift.sh --verify           # consumer mode (default)
#   scripts/hash-drift.sh --verify --plugin-cache <path>
#                                            # explicit cache dir
#
# Exit codes:
#   0 — no drift / clean
#   1 — drift detected (caller decides whether to block)
#   2 — precondition error (jq missing, files unreadable, etc.)

MODE="verify"
PLUGIN_CACHE=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--generate)
		MODE="generate"
		shift
		;;
	--verify)
		MODE="verify"
		shift
		;;
	--plugin-cache)
		[ -n "${2:-}" ] || {
			echo "hash-drift: --plugin-cache requires arg" >&2
			exit 2
		}
		PLUGIN_CACHE=$2
		shift 2
		;;
	--help | -h)
		grep -E '^# ' "$0" | sed 's/^# //'
		exit 0
		;;
	*)
		echo "hash-drift: unknown arg: $1" >&2
		exit 2
		;;
	esac
done

command -v jq >/dev/null 2>&1 || {
	echo "hash-drift: jq required" >&2
	exit 2
}

# Portable SHA256: shasum (macOS) or sha256sum (Linux).
_hash_file() {
	local f=$1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$f" | awk '{print $1}'
	else
		shasum -a 256 "$f" | awk '{print $1}'
	fi
}

if [ "$MODE" = "generate" ]; then
	# Producer mode: walk hooks/ and _lib/ relative to current repo.
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
		echo "hash-drift: not in a git repo" >&2
		exit 2
	}
	cd "$REPO_ROOT"
	OUT=".claude/.source-hashes.json"
	mkdir -p .claude
	# Collect via find — entries are <relpath>: <sha256>.
	tmp=$(mktemp "$OUT.XXXXXX") || {
		echo "hash-drift: mktemp failed" >&2
		exit 2
	}
	{
		printf '{\n'
		first=1
		for dir in hooks _lib; do
			[ -d "$dir" ] || continue
			while IFS= read -r f; do
				[ -f "$f" ] || continue
				hash=$(_hash_file "$f")
				if [ $first -eq 1 ]; then first=0; else printf ',\n'; fi
				# JSON-quote the path via jq to handle any edge chars.
				printf '  %s: %s' \
					"$(jq -Rn --arg p "$f" '$p')" \
					"$(jq -Rn --arg h "$hash" '$h')"
			done < <(find "$dir" -name '*.sh' -type f | sort)
		done
		printf '\n}\n'
	} >"$tmp"
	# Validate before clobbering.
	if ! jq empty "$tmp" 2>/dev/null; then
		echo "hash-drift: generated JSON is invalid (refusing to overwrite $OUT)" >&2
		rm -f "$tmp"
		exit 2
	fi
	mv "$tmp" "$OUT"
	count=$(jq 'keys | length' "$OUT")
	echo "hash-drift: wrote $count entries to $OUT"
	exit 0
fi

# Consumer-verify mode.
CONSUMER_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "hash-drift: not in a git repo" >&2
	exit 2
}
cd "$CONSUMER_ROOT"

# Discover plugin cache if not provided.
if [ -z "$PLUGIN_CACHE" ]; then
	PLUGIN_CACHE_BASE="${HASH_DRIFT_PLUGIN_CACHE_BASE:-$HOME/.claude/plugins/cache/claude-workflow-core/claude-workflow-core}"
	if [ -d "$PLUGIN_CACHE_BASE" ]; then
		# Pick highest semver subdir.
		shopt -s nullglob
		cands=("$PLUGIN_CACHE_BASE"/*)
		shopt -u nullglob
		latest=""
		for c in "${cands[@]:-}"; do
			n=${c##*/}
			[[ $n =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
			if [ -z "$latest" ]; then
				latest=$n
			else
				higher=$(printf '%s\n%s\n' "$latest" "$n" | sort -V | tail -1)
				latest=$higher
			fi
		done
		[ -n "$latest" ] && PLUGIN_CACHE="$PLUGIN_CACHE_BASE/$latest"
	fi
fi

[ -n "$PLUGIN_CACHE" ] || {
	echo "hash-drift: no plugin cache found (set --plugin-cache or HASH_DRIFT_PLUGIN_CACHE_BASE)" >&2
	exit 2
}
[ -d "$PLUGIN_CACHE" ] || {
	echo "hash-drift: plugin cache dir not found: $PLUGIN_CACHE" >&2
	exit 2
}

SOURCE_HASHES="$PLUGIN_CACHE/.claude/.source-hashes.json"
[ -f "$SOURCE_HASHES" ] || {
	echo "hash-drift: $SOURCE_HASHES missing — plugin source predates #90 hash-drift (no-op)" >&2
	exit 0
}
jq empty "$SOURCE_HASHES" 2>/dev/null || {
	echo "hash-drift: $SOURCE_HASHES malformed JSON" >&2
	exit 2
}

# Load override list (optional).
declare -a OVERRIDE_PATHS=()
if [ -f .claude/local-overrides.yml ]; then
	while IFS= read -r ov; do
		[ -n "$ov" ] && OVERRIDE_PATHS+=("$ov")
	done < <(grep -E '^\s*[^#].*:' .claude/local-overrides.yml | sed -E 's/^\s*([^:]+):.*/\1/' | sed 's/^"//;s/"$//')
fi

_is_overridden() {
	local target=$1
	for ov in "${OVERRIDE_PATHS[@]:-}"; do
		[ "$ov" = "$target" ] && return 0
	done
	return 1
}

# For each entry in source-hashes, compare against consumer-local
# .claude/hooks|_lib/<basename>.
drift_count=0
missing_count=0
clean_count=0
overridden_count=0
DRIFT_REPORT=""
while IFS=$'\t' read -r src_path src_hash; do
	# Map producer-side hooks/X.sh → consumer-side .claude/hooks/X.sh.
	# Same for _lib/X.sh.
	consumer_path=".claude/$src_path"
	if _is_overridden "$consumer_path"; then
		overridden_count=$((overridden_count + 1))
		continue
	fi
	if [ ! -f "$consumer_path" ]; then
		# Producer has file, consumer doesn't — not necessarily drift
		# (consumer may not need all plugin files). Skip silently.
		missing_count=$((missing_count + 1))
		continue
	fi
	local_hash=$(_hash_file "$consumer_path")
	if [ "$local_hash" = "$src_hash" ]; then
		clean_count=$((clean_count + 1))
	else
		drift_count=$((drift_count + 1))
		DRIFT_REPORT+=$'  - '$consumer_path$'\n    plugin sha: '${src_hash:0:12}$'...\n    local sha:  '${local_hash:0:12}$'...\n'
	fi
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$SOURCE_HASHES")

if [ $drift_count -gt 0 ]; then
	cat >&2 <<EOF
hash-drift: ⚠ $drift_count file(s) drifted from plugin source-of-truth
$(printf '%s' "$DRIFT_REPORT" | tr '\0' '\n')
  Clean: $clean_count, missing: $missing_count, overridden: $overridden_count
  Plugin source: $PLUGIN_CACHE
  Remediation: refresh the file from plugin source, OR add to
  .claude/local-overrides.yml if the local copy is intentional.
EOF
	exit 1
fi
echo "hash-drift: ✓ clean ($clean_count files match; $overridden_count overridden; $missing_count not-installed)"
exit 0
