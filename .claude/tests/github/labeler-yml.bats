#!/usr/bin/env bats
# covers: .github/labeler.yml
#
# #2381: mechanical glob-coverage drift guard for .github/labeler.yml so the
# #2314 class of bug cannot recur — a top-level path matching NO labeler glob
# gets no `labeled` event, so pr-lint stays pending and the merge is silently
# blocked. yamllint/actionlint cannot catch this (the YAML is valid; it is just
# missing a glob). Sibling of labels-yml.bats; bash-3.2 compatible (no mapfile).

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd to repo root failed: $REPO_ROOT" >&2
		return 1
	}
	[ -d "$REPO_ROOT/.github" ] || {
		echo "FATAL: bad REPO_ROOT=$REPO_ROOT (no .github/)" >&2
		return 1
	}
	LABELER="${REPO_ROOT}/.github/labeler.yml"
	LABELS="${REPO_ROOT}/.github/labels.yml"
	[ -f "$LABELER" ] || {
		echo "FATAL: labeler.yml not at $LABELER" >&2
		return 1
	}
	[ -f "$LABELS" ] || {
		echo "FATAL: labels.yml not at $LABELS" >&2
		return 1
	}

	# Top-level tracked paths intentionally WITHOUT an area label. Empty today
	# (every top-level path is globbed after #2314/#2315). Add a path here with
	# a one-line reason if a genuinely non-PR-relevant top-level file appears.
	LABELER_COVERAGE_EXCEPT=()
}

# Match a top-level path against a labeler glob, at top-level granularity:
#   "dir/**" or "dir/*" → the top-level dir "dir"
#   "**/<pat>"          → reduce to the trailing pattern for top-level files
#   file globs / exact names → bash glob compare
_labeler_path_matches() {
	local path="$1"
	shift
	local glob stripped
	for glob in "$@"; do
		stripped="$glob"
		case "$stripped" in
		*/'**') stripped="${stripped%/'**'}" ;;
		*/'*') stripped="${stripped%/'*'}" ;;
		esac
		stripped="${stripped#'**/'}"
		# shellcheck disable=SC2053  # intentional glob match (RHS unquoted)
		[[ $path == $stripped ]] && return 0
	done
	return 1
}

@test "labeler.yml exists and is valid YAML" {
	run yq -o=json '.' "$LABELER"
	[ "$status" -eq 0 ]
}

@test "every labeler.yml key is an area:* label declared in labels.yml" {
	keys=$(yq -r 'keys[]' "$LABELER") || {
		echo "FAIL: yq failed reading keys from $LABELER" >&2
		return 1
	}
	[ -n "$keys" ] || {
		echo "FAIL: labeler.yml has no keys" >&2
		return 1
	}
	names=$(yq -r '.[].name' "$LABELS") || {
		echo "FAIL: yq failed reading label names from $LABELS" >&2
		return 1
	}
	n=0
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		case "$key" in
		area:*) ;;
		*)
			echo "FAIL: labeler.yml key '$key' is not an area:* label" >&2
			return 1
			;;
		esac
		echo "$names" | grep -Fxq "$key" || {
			echo "FAIL: labeler.yml key '$key' is not declared in labels.yml" >&2
			return 1
		}
		n=$((n + 1))
	done <<<"$keys"
	[ "$n" -gt 0 ] || {
		echo "FAIL: zero labeler keys validated" >&2
		return 1
	}
}

@test "every top-level tracked path maps to a labeler glob (coverage drift guard)" {
	# Hoist the glob extraction: a yq failure here would otherwise mark every
	# path unmatched with a misleading diagnostic.
	globs=()
	while IFS= read -r g; do
		[ -n "$g" ] && globs+=("$g")
	done < <(yq -r 'to_entries[].value[]."changed-files"[]."any-glob-to-any-file"[]' "$LABELER")
	[ "${#globs[@]}" -gt 0 ] || {
		echo "FAIL: extracted zero globs from $LABELER (yq path wrong or file empty?)" >&2
		return 1
	}

	unmatched=()
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		skip=
		if [ "${#LABELER_COVERAGE_EXCEPT[@]}" -gt 0 ]; then
			for e in "${LABELER_COVERAGE_EXCEPT[@]}"; do
				[ "$path" = "$e" ] && skip=1 && break
			done
		fi
		[ -n "$skip" ] && continue
		_labeler_path_matches "$path" "${globs[@]}" || unmatched+=("$path")
	done < <(git -C "$REPO_ROOT" ls-tree --name-only HEAD)

	# Key assertion last: every top-level path is covered; name the gaps loudly.
	[ "${#unmatched[@]}" -eq 0 ] || {
		echo "FAIL: top-level path(s) match NO labeler glob — a PR touching only" >&2
		echo "  these gets no area label, so pr-lint stays pending and merge blocks:" >&2
		echo "    ${unmatched[*]}" >&2
		echo "  Fix: add a glob to .github/labeler.yml, or (if genuinely" >&2
		echo "  non-PR-relevant) add the path to LABELER_COVERAGE_EXCEPT in this test." >&2
		return 1
	}
}
