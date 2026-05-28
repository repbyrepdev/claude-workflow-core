#!/usr/bin/env bats
# covers: .github/labels.yml .github/labels-spec.md

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)
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
		auto:renovate auto:trivy-scan auto:trivy-post-merge
		# Renovate semver
		patch minor major
		# CR Issue Planner
		plan-me no-plan
	)
	missing=()
	for lbl in "${REQUIRED[@]}"; do
		yq -r '.[].name' "$LABELS" | grep -Fxq "$lbl" || missing+=("$lbl")
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
	EXPECTED_COUNT=25
	actual=$(yq -r '. | length' "$LABELS")
	[ "$actual" -eq "$EXPECTED_COUNT" ] || {
		echo "FAIL: labels.yml has $actual labels, expected $EXPECTED_COUNT" >&2
		echo "  If intentional, update EXPECTED_COUNT here AND labels-spec.md audit table." >&2
		return 1
	}
}

# Phase 1 r1 code-reviewer + comment-analyzer: cross-check palette
# comment block against the data. Every color used in labels.yml must
# appear in the 8-color palette comment near the top of the file.
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
	[ -f "$SPEC" ]
	[ "$(wc -l <"$SPEC")" -gt 50 ]
	grep -qE '^## Two-tier model' "$SPEC"
	grep -qE '^## Promotion criteria' "$SPEC"
	grep -qE '^## Cross-repo audit' "$SPEC"
	grep -qE '^## What stays in consumer local-overrides' "$SPEC"
	grep -qE 'Generic tier' "$SPEC"
	grep -qE 'Domain-extension tier' "$SPEC"
}
