#!/usr/bin/env bats
# covers: .github/labels.yml .github/labels-spec.md scripts/cr/auto-parse-plans.sh

setup() {
	# r2 silent-failure-hunter: capture cd-stderr so a cd failure (perm
	# denied, missing intermediate dir, symlink-to-file) surfaces in the
	# diagnostic instead of just an empty REPO_ROOT.
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd to repo root failed: $REPO_ROOT" >&2
		return 1
	}
	[ -d "$REPO_ROOT/.github" ] || {
		echo "FATAL: bad REPO_ROOT=$REPO_ROOT (no .github/)" >&2
		return 1
	}
	LABELS="${REPO_ROOT}/.github/labels.yml"
	SPEC="${REPO_ROOT}/.github/labels-spec.md"
	[ -f "$LABELS" ] || {
		echo "FATAL: labels.yml not at $LABELS" >&2
		return 1
	}
}

@test "labels.yml exists and is valid YAML" {
	run yq -o=json '.' "$LABELS"
	[ "$status" -eq 0 ]
}

@test "labels.yml is a non-empty list" {
	count=$(yq -r '. | length' "$LABELS")
	[ "$count" -gt 0 ]
}

# Phase 1 r1 silent-failure-hunter: prior version had vacuous-pass risk
# on yq failure (empty input → while loop never executes → status=0).
# Capture yq output explicitly, assert non-empty + status=0, count rows.
@test "every label has name + color + description (with row-count assertion)" {
	rows=$(yq -r '.[] | "\(.name)\t\(.color)\t\(.description)"' "$LABELS") || {
		echo "FAIL: yq failed parsing labels.yml" >&2
		return 1
	}
	[ -n "$rows" ] || {
		echo "FAIL: yq returned empty rows" >&2
		return 1
	}
	n=0
	while IFS=$'\t' read -r name color desc; do
		[ -n "$name" ] && [ "$name" != "null" ] || {
			echo "FAIL: row $n has missing/null name" >&2
			return 1
		}
		[ -n "$color" ] && [ "$color" != "null" ] || {
			echo "FAIL: label '$name' missing color" >&2
			return 1
		}
		[ -n "$desc" ] && [ "$desc" != "null" ] || {
			echo "FAIL: label '$name' missing description" >&2
			return 1
		}
		n=$((n + 1))
	done <<<"$rows"
	[ "$n" -gt 0 ] || {
		echo "FAIL: zero labels validated" >&2
		return 1
	}
}

@test "every color is a 6-char hex string" {
	rows=$(yq -r '.[] | "\(.name)\t\(.color)"' "$LABELS")
	[ -n "$rows" ] || {
		echo "FAIL: yq empty" >&2
		return 1
	}
	n=0
	while IFS=$'\t' read -r name color; do
		[[ $color =~ ^[0-9a-fA-F]{6}$ ]] || {
			echo "FAIL: label '$name' color '$color' is not 6-char hex" >&2
			return 1
		}
		n=$((n + 1))
	done <<<"$rows"
	[ "$n" -gt 0 ] || {
		echo "FAIL: zero colors validated" >&2
		return 1
	}
}

@test "no duplicate label names" {
	names=$(yq -r '.[].name' "$LABELS")
	[ -n "$names" ] || {
		echo "FAIL: empty name list" >&2
		return 1
	}
	dups=$(echo "$names" | sort | uniq -d)
	[ -z "$dups" ] || {
		echo "FAIL: duplicate label names: $dups" >&2
		return 1
	}
}

# Phase 1 r1 code-reviewer: canonical generic-set assertion — single
# source of truth in this test so adding a new generic label means
# editing both labels.yml AND this list. Drift between the two surfaces
# as a test failure (mechanical enforcement of the promotion rule).
@test "labels.yml contains the full generic-tier canonical set" {
	REQUIRED=(
		# Type
		bug enhancement epic brainstorm documentation question
		# Priority
		priority:p0 priority:p0-proposed priority:p1 priority:p2 priority:p3 priority:needs-triage
		# Status
		status:in-review status:blocked
		# Area (generic only)
		area:infrastructure area:docs area:plugin-manifest
		# Auto (generic only)
		auto:renovate auto:trivy-scan auto:trivy-post-merge auto:plugin-release-cascade
		# Renovate semver
		patch minor major
		# CR Issue Planner
		plan-me no-plan plan-parsed
	)
	# r2 silent-failure-hunter: hoist yq outside the loop. Prior code
	# called yq 25 times AND silently swallowed yq failures as "every
	# label missing" — misleading diagnostic blamed phantom label
	# removals when the real cause was a yq parse error.
	names=$(yq -r '.[].name' "$LABELS") || {
		echo "FAIL: yq failed extracting label names from $LABELS" >&2
		return 1
	}
	[ -n "$names" ] || {
		echo "FAIL: yq returned empty name list" >&2
		return 1
	}
	missing=()
	for lbl in "${REQUIRED[@]}"; do
		echo "$names" | grep -Fxq "$lbl" || missing+=("$lbl")
	done
	[ "${#missing[@]}" -eq 0 ] || {
		echo "FAIL: missing required labels: ${missing[*]}" >&2
		return 1
	}
}

# Phase 1 r1 code-reviewer: total count assertion catches accidental
# label addition/removal that drifts from labels-spec.md audit table.
# Adjust EXPECTED_COUNT when intentionally promoting/dropping labels +
# update spec table in the same commit.
@test "labels.yml total count matches spec" {
	EXPECTED_COUNT=27
	actual=$(yq -r '. | length' "$LABELS")
	[ "$actual" -eq "$EXPECTED_COUNT" ] || {
		echo "FAIL: labels.yml has $actual labels, expected $EXPECTED_COUNT" >&2
		echo "  If intentional, update EXPECTED_COUNT here AND labels-spec.md audit table." >&2
		return 1
	}
}

# Phase 1 r1 code-reviewer + comment-analyzer: cross-check palette
# comment block against the data. Every color used in labels.yml must
# appear in the palette comment near the top of the file (8-color Primer palette).
@test "every label color is in the 8-color Primer palette comment" {
	palette_colors=$(grep -oE '^#[[:space:]]*[A-Za-z]+[[:space:]]+[0-9a-fA-F]{6}' "$LABELS" |
		grep -oE '[0-9a-fA-F]{6}$' |
		sort -u)
	[ -n "$palette_colors" ] || {
		echo "FAIL: no palette colors extracted from comment block" >&2
		return 1
	}
	used_colors=$(yq -r '.[].color' "$LABELS" | sort -u)
	while IFS= read -r c; do
		echo "$palette_colors" | grep -Fxq "$c" || {
			echo "FAIL: color '$c' used by a label but not declared in palette comment" >&2
			return 1
		}
	done <<<"$used_colors"
}

# Phase 1 r1 comment-analyzer + code-reviewer: labels-spec.md must
# document the two-tier model + audit table. Strong assertions, not
# weak substring matches.
@test "labels-spec.md exists with structural markers" {
	# r2 silent-failure-hunter: explicit FAIL messages per assertion so a
	# regression points at the specific structural marker that broke.
	[ -f "$SPEC" ] || {
		echo "FAIL: labels-spec.md missing at $SPEC" >&2
		return 1
	}
	[ "$(wc -l <"$SPEC")" -gt 50 ] || {
		echo "FAIL: labels-spec.md unexpectedly short ($(wc -l <"$SPEC") lines)" >&2
		return 1
	}
	for marker in '^## Two-tier model' '^## Promotion criteria' '^## Cross-repo audit' '^## What stays in consumer local-overrides' 'Generic tier' 'Domain-extension tier'; do
		grep -qE "$marker" "$SPEC" || {
			echo "FAIL: labels-spec.md missing structural marker: $marker" >&2
			return 1
		}
	done
}

# CR-CLI (#223): mechanical parity gate. scripts/cr/auto-parse-plans.sh hardcodes
# fallback literals (pp_color/pp_desc) for the plan-parsed label, used to seed the
# label when yq/labels.yml is unavailable at create time. Those literals MUST match
# this labels.yml SSOT entry or the defensive create seeds metadata that drifts from
# canonical. Enforce it here so a one-sided edit fails the suite — the mechanical
# replacement for the "keep in sync" source comment in auto-parse-plans.sh.
@test "auto-parse-plans.sh plan-parsed fallbacks match labels.yml SSOT" {
	script="${REPO_ROOT}/scripts/cr/auto-parse-plans.sh"
	[ -f "$script" ] || {
		echo "FAIL: auto-parse-plans.sh not at $script" >&2
		return 1
	}
	# Extract the two fallback literals from the `local pp_color=... pp_desc=...` line.
	fb_line=$(grep -E 'local pp_color="[^"]+" pp_desc="[^"]+"' "$script") || {
		echo "FAIL: could not find the pp_color/pp_desc fallback line in $script" >&2
		return 1
	}
	fb_color=$(sed -E 's/.*pp_color="([^"]+)".*/\1/' <<<"$fb_line")
	fb_desc=$(sed -E 's/.*pp_desc="([^"]+)".*/\1/' <<<"$fb_line")
	[ -n "$fb_color" ] && [ -n "$fb_desc" ] || {
		echo "FAIL: failed to extract fallback color/desc from: $fb_line" >&2
		return 1
	}
	# Read the SSOT values with the SAME yq query the script uses.
	yml_color=$(yq -r '.[] | select(.name == "plan-parsed") | .color' "$LABELS") || {
		echo "FAIL: yq failed reading plan-parsed color from $LABELS" >&2
		return 1
	}
	yml_desc=$(yq -r '.[] | select(.name == "plan-parsed") | .description' "$LABELS") || {
		echo "FAIL: yq failed reading plan-parsed description from $LABELS" >&2
		return 1
	}
	[ "$fb_color" = "$yml_color" ] || {
		echo "FAIL: pp_color fallback '$fb_color' != labels.yml plan-parsed color '$yml_color'" >&2
		return 1
	}
	[ "$fb_desc" = "$yml_desc" ] || {
		echo "FAIL: pp_desc fallback '$fb_desc' != labels.yml plan-parsed desc '$yml_desc'" >&2
		return 1
	}
}
