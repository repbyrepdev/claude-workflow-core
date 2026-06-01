#!/bin/bash
set -euo pipefail
# Introduced in #90 — producer-consumer hash-drift gate.
#
# Detects content drift between plugin-source files and their consumer-repo
# siblings. Covered set (#232):
#   - hooks/*.sh, _lib/*.sh — mirror at the consumer's .claude/hooks|_lib/.
#   - the .github "process templates" declared `hashed: true` in
#     scripts/bootstrap-manifest.yml (pull_request_template.md, commit-
#     template.yml, ISSUE_TEMPLATE/*) — byte-SSOT; these map VERBATIM to the
#     consumer repo root, NOT under .claude/. (labels/required-checks/labeler/
#     workflows are template-with-overrides and are NOT hashed here.)
#   - scripts/*.sh are NOT hashed (#247): consumers do NOT mirror them — the
#     bootstrap consumer wrapper `exec`s the orchestrator from the plugin cache
#     by PIN ($PLUGIN_CACHE/$PIN/scripts/...), so there is no consumer-side copy
#     that could drift. Only mirrored files (hooks/_lib/.github-hashed) are tracked.
#
# Two modes:
#   --generate (producer-side): compute SHA256 of each plugin source file
#       (hooks/ + _lib/ walked via find, plus the manifest's hashed:true
#       .github files) and write to .claude/.source-hashes.json. Committed
#       alongside source so consumers can verify against it after plugin
#       install.
#   --verify (consumer-side): for each entry in
#       <plugin-cache>/.claude/.source-hashes.json, compute the local
#       consumer-path hash (hooks/_lib → .claude/<path>; .github/* → <path>
#       verbatim) and warn on drift.
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

# Portable SHA256: prefer sha256sum (Linux/coreutils); fall back to
# shasum (macOS). CR PR #90 r1 HIGH: capture rc + assert non-empty so
# I/O failures don't silently produce empty hashes (would emit phantom
# drift on the consumer side).
_hash_file() {
	local f=$1 out
	if command -v sha256sum >/dev/null 2>&1; then
		out=$(sha256sum "$f" 2>&1) || {
			echo "hash-drift: sha256sum failed on $f: $out" >&2
			return 2
		}
	else
		out=$(shasum -a 256 "$f" 2>&1) || {
			echo "hash-drift: shasum -a 256 failed on $f: $out" >&2
			return 2
		}
	fi
	local hex
	hex=$(printf '%s\n' "$out" | awk '{print $1}')
	[ -n "$hex" ] || {
		echo "hash-drift: hash extraction empty for $f" >&2
		return 2
	}
	printf '%s\n' "$hex"
}

# Hash $1 and emit one JSON `  "path": "hash"` entry to stdout, prefixing a
# comma after the first entry. Reads + mutates the generate-scoped globals
# `first`, `tmp`, `entries_tmp`. A file that can't be hashed (or yields a
# non-sha256 string) is a HARD error: clean the temps and exit 2 — never a
# silent omission, which would punch a coverage hole in the consumer drift
# gate. Only called inside the generate `{ }` redirect block.
_emit_hashed_entry() {
	local f=$1 hash
	hash=$(_hash_file "$f") || {
		echo "hash-drift: failed to hash $f" >&2
		rm -f "$tmp" "$entries_tmp"
		exit 2
	}
	# Hash-format validation: refuse anything that's not 64-char lowercase
	# hex (sha256). Catches silently-broken _hash_file output before ship.
	if ! [[ $hash =~ ^[0-9a-f]{64}$ ]]; then
		echo "hash-drift: invalid hash for $f: '$hash' (expected 64-char lowercase sha256 hex)" >&2
		rm -f "$tmp" "$entries_tmp"
		exit 2
	fi
	if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
	printf '  %s: %s' \
		"$(jq -Rn --arg p "$f" '$p')" \
		"$(jq -Rn --arg h "$hash" '$h')"
}

if [ "$MODE" = "generate" ]; then
	# Producer mode: walk hooks/ and _lib/, plus the manifest's hashed:true
	# .github files (#232), relative to the current repo.
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
		echo "hash-drift: not in a git repo" >&2
		exit 2
	}
	cd "$REPO_ROOT"
	OUT=".claude/.source-hashes.json"
	mkdir -p .claude
	# v0.18.1 (#140) schema-wrap — type-design-analyzer caught that a bare
	# {path: hash} map is non-versionable: any future metadata key (e.g.
	# schema_version, algorithm) would collide with a real path. Wrapping
	# entries under `files: {...}` reserves the top-level namespace for
	# metadata. Bare-map format was never released; this is the canonical
	# initial shape.
	tmp=$(mktemp "$OUT.XXXXXX") || {
		echo "hash-drift: mktemp failed" >&2
		exit 2
	}
	# Build entries first as a JSON object, then wrap with metadata.
	# mktemp at a path OUTSIDE the OUT prefix so shellcheck SC2094 doesn't
	# confuse it with the OUT.XXXXXX tmp above.
	# shellcheck disable=SC2094  # entries_tmp + tmp are distinct files
	entries_tmp=$(mktemp "${OUT%/*}/.source-hashes.entries.XXXXXX") || {
		echo "hash-drift: mktemp entries failed" >&2
		rm -f "$tmp"
		exit 2
	}
	# .github byte-SSOT coverage: read the files declared `hashed: true` in
	# the bootstrap manifest — the single SSOT for what is byte-identical
	# across repos. Producer-only; requires yq. Materialize the list NOW (and
	# verify each declared file exists) so a yq parse failure or a missing
	# declared file fails CLOSED before we emit a partial manifest. A silent
	# coverage hole would disable the consumer drift gate for those files.
	MANIFEST="scripts/bootstrap-manifest.yml"
	GH_HASHED=""
	if [ -f "$MANIFEST" ]; then
		command -v yq >/dev/null 2>&1 || {
			echo "hash-drift: yq required to read hashed paths from $MANIFEST" >&2
			rm -f "$tmp" "$entries_tmp"
			exit 2
		}
		# Guard a malformed `hashed:` VALUE (e.g. a typo'd `ture`, or `yes`)
		# from silently dropping coverage: yq's `== true` selector skips any
		# non-`true` value, so a typo would exclude the file with NO signal
		# (#232 silent-failure-hunter). Every declared `hashed` must be a real
		# boolean — fail CLOSED on anything else.
		bad_hashed=$(yq -r '.files[] | select(.hashed != null) | select((.hashed | tag) != "!!bool") | .path' "$MANIFEST") || {
			echo "hash-drift: yq failed validating hashed: values in $MANIFEST" >&2
			rm -f "$tmp" "$entries_tmp"
			exit 2
		}
		[ -z "$bad_hashed" ] || {
			echo "hash-drift: non-boolean hashed: value(s) in $MANIFEST (typo? must be true/false):" >&2
			printf '  %s\n' "$bad_hashed" >&2
			rm -f "$tmp" "$entries_tmp"
			exit 2
		}
		GH_HASHED=$(yq -r '.files[] | select(.hashed == true) | .path' "$MANIFEST" | sort) || {
			echo "hash-drift: yq failed enumerating hashed paths in $MANIFEST" >&2
			rm -f "$tmp" "$entries_tmp"
			exit 2
		}
		while IFS= read -r ghf; do
			[ -n "$ghf" ] || continue
			[ -f "$ghf" ] || {
				echo "hash-drift: manifest declares hashed file '$ghf' but it is missing under $REPO_ROOT — refusing a coverage hole" >&2
				rm -f "$tmp" "$entries_tmp"
				exit 2
			}
		done <<<"$GH_HASHED"
	else
		# Manifest absent — a generic (non-plugin) repo, OR the plugin's own
		# manifest was moved/deleted. hooks/_lib still hash, but NO .github
		# byte-SSOT coverage is produced. Emit a NOTE so a missing manifest
		# can't silently drop .github coverage in a repo that expected it
		# (#232 silent-failure-hunter).
		echo "hash-drift: NOTE: $MANIFEST absent — hashing hooks/_lib only, no .github byte-SSOT coverage" >&2
	fi
	# shellcheck disable=SC2094  # tmp + entries_tmp are distinct files; rm -f below
	{
		printf '{\n'
		first=1
		for dir in hooks _lib; do
			[ -d "$dir" ] || continue
			while IFS= read -r f; do
				[ -f "$f" ] || continue
				_emit_hashed_entry "$f"
			done < <(find "$dir" -name '*.sh' -type f | sort)
		done
		# .github byte-SSOT files (manifest `hashed: true`), validated above.
		# Iterate the materialized list; emit alongside hooks/_lib so the
		# producer-relative path (e.g. .github/commit-template.yml) lands in
		# the same `files` map. --verify + refresh map it back to repo-root.
		while IFS= read -r ghf; do
			[ -n "$ghf" ] || continue
			_emit_hashed_entry "$ghf"
		done <<<"$GH_HASHED"
		printf '\n}\n'
	} >"$entries_tmp"
	# Validate entries before wrapping.
	if ! jq empty "$entries_tmp" 2>/dev/null; then
		echo "hash-drift: generated entries JSON is invalid (refusing to overwrite $OUT)" >&2
		rm -f "$tmp" "$entries_tmp"
		exit 2
	fi
	# Wrap with metadata: schema_version, algorithm, producer_root,
	# then files. NOTE: deliberately NO `generated_at` field — including
	# a timestamp would break byte-equality of regenerations of the same
	# content, defeating the pre-commit + release-time idempotency check.
	if ! jq -S \
		--arg algo "sha256" \
		--arg producer_root "." \
		--argjson schema 1 \
		'{schema_version: $schema, algorithm: $algo, producer_root: $producer_root, files: .}' \
		"$entries_tmp" >"$tmp" 2>/dev/null; then
		echo "hash-drift: failed to wrap entries with schema metadata" >&2
		rm -f "$tmp" "$entries_tmp"
		exit 2
	fi
	rm -f "$entries_tmp"
	mv "$tmp" "$OUT"
	count=$(jq '.files | length' "$OUT") || {
		echo "hash-drift: failed to count entries in $OUT" >&2
		exit 2
	}
	# CR PR #90 r1: refuse empty manifest — likely 'wrong directory'
	# misuse (neither hooks/ nor _lib/ present). Don't ship a no-op
	# manifest that silently disables the consumer drift gate.
	if [ "$count" -eq 0 ]; then
		echo "hash-drift: manifest empty (no .sh files in hooks/ or _lib/ under $REPO_ROOT) — refusing to ship a no-op manifest" >&2
		rm -f "$OUT"
		exit 2
	fi
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

# v0.18.1 (#140) — detect schema. Wrapped form has {schema_version, files: {...}};
# legacy bare-map form has {path: hash, path: hash, ...}. The bare-map form
# never shipped to consumers (pre-v0.18.1 manifest was never produced); supporting
# it here is defense against test fixtures that pre-date the schema-wrap.
SCHEMA_VERSION=$(jq -r '.schema_version // empty' "$SOURCE_HASHES" 2>/dev/null)
if [ -n "$SCHEMA_VERSION" ]; then
	# Wrapped schema. Validate schema_version is one we understand.
	if [ "$SCHEMA_VERSION" != "1" ]; then
		echo "hash-drift: $SOURCE_HASHES schema_version=$SCHEMA_VERSION not supported by this hash-drift.sh (expected 1)" >&2
		exit 2
	fi
	HASHES_QUERY='.files | to_entries[] | "\(.key)\t\(.value)"'
	HASHES_SIZE_QUERY='.files | length'
else
	# Legacy bare-map form (pre-v0.18.1; not in any released cache).
	HASHES_QUERY='to_entries[] | "\(.key)\t\(.value)"'
	HASHES_SIZE_QUERY='keys | length'
fi

# Load override list (optional). CR PR #90 r1 fixes:
# - POSIX character class [[:space:]] for BSD grep compat (was \s).
# - [^#[:space:]] guard against indented `# comment: x` lines that
#   would otherwise capture phantom paths.
OVERRIDE_PATHS=()
if [ -f .claude/local-overrides.yml ]; then
	while IFS= read -r ov; do
		[ -n "$ov" ] && OVERRIDE_PATHS+=("$ov")
	done < <(grep -E '^[[:space:]]*[^#[:space:]].*:' .claude/local-overrides.yml |
		sed -E 's/^[[:space:]]*"?([^:"]+)"?[[:space:]]*:.*/\1/')
fi

_is_overridden() {
	local target=$1
	for ov in "${OVERRIDE_PATHS[@]:-}"; do
		[ "$ov" = "$target" ] && return 0
	done
	return 1
}

# For each entry in source-hashes, compare against the consumer-local copy.
# Path mapping (see the case statement below, #232): hooks/ and _lib/ mirror
# under .claude/<relpath>; .github/* (and any other repo-root path) map
# verbatim to the consumer root.
# CR PR #90 r1: track processed-rows count + assert against manifest
# size after the loop to catch partial jq-stream failures.
drift_count=0
missing_count=0
clean_count=0
overridden_count=0
processed_count=0
DRIFT_REPORT=""
while IFS=$'\t' read -r src_path src_hash; do
	# Map producer-relative <path> → consumer location. hooks/ and _lib/
	# mirror under the consumer's .claude/; .github/ files (and any other
	# repo-root path) map VERBATIM to the consumer root. Before #232 this
	# hardcoded `.claude/$src_path`, which mis-resolved .github/* entries to
	# a nonexistent `.claude/.github/*` — a silent missing-file that was
	# never gated.
	if [ -z "$src_path" ] || [ -z "$src_hash" ]; then
		echo "hash-drift: malformed manifest row (empty path or hash)" >&2
		exit 2
	fi
	processed_count=$((processed_count + 1))
	case "$src_path" in
	hooks/* | _lib/*) consumer_path=".claude/$src_path" ;;
	*) consumer_path="$src_path" ;;
	esac
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
done < <(jq -r "$HASHES_QUERY" "$SOURCE_HASHES")

# CR PR #90 r1 HIGH: verify the loop processed every manifest entry.
# Process substitution doesn't propagate rc, so a mid-stream jq panic
# would silently truncate the comparison and we'd report ✓ clean on
# partial coverage. Cross-check row count against manifest size.
manifest_size=$(jq "$HASHES_SIZE_QUERY" "$SOURCE_HASHES" 2>/dev/null) || manifest_size=""
if [ -z "$manifest_size" ] || [ "$processed_count" -ne "$manifest_size" ]; then
	echo "hash-drift: ⚠ partial verification — processed $processed_count of $manifest_size manifest entries — refusing to report status" >&2
	exit 2
fi

if [ $drift_count -gt 0 ]; then
	cat >&2 <<EOF
hash-drift: ⚠ $drift_count file(s) drifted from plugin source-of-truth
$DRIFT_REPORT
  Clean: $clean_count, missing: $missing_count, overridden: $overridden_count
  Plugin source: $PLUGIN_CACHE
  Remediation: refresh the file from plugin source, OR add to
  .claude/local-overrides.yml if the local copy is intentional.
EOF
	exit 1
fi
echo "hash-drift: ✓ clean ($clean_count files match; $overridden_count overridden; $missing_count not-installed)"
exit 0
