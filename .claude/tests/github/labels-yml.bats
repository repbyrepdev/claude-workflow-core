#!/usr/bin/env bats
# covers: .github/labels.yml .github/labels-spec.md

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	LABELS="${REPO_ROOT}/.github/labels.yml"
	SPEC="${REPO_ROOT}/.github/labels-spec.md"
}

@test "labels.yml exists and is valid YAML" {
	[ -f "$LABELS" ]
	run yq -o=json '.' "$LABELS"
	[ "$status" -eq 0 ]
}

@test "labels.yml is a non-empty list" {
	count=$(yq -r '. | length' "$LABELS")
	[ "$count" -gt 0 ]
}

@test "every label has name + color + description" {
	while IFS=$'\t' read -r name color desc; do
		[ -n "$name" ] || {
			echo "FAIL: label missing name" >&2
			return 1
		}
		[ "$name" != "null" ] || {
			echo "FAIL: label has null name" >&2
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
	done < <(yq -r '.[] | "\(.name)\t\(.color)\t\(.description)"' "$LABELS")
}

@test "every color is a 6-char hex string" {
	while IFS=$'\t' read -r name color; do
		[[ $color =~ ^[0-9a-fA-F]{6}$ ]] || {
			echo "FAIL: label '$name' color '$color' is not 6-char hex" >&2
			return 1
		}
	done < <(yq -r '.[] | "\(.name)\t\(.color)"' "$LABELS")
}

@test "no duplicate label names" {
	dups=$(yq -r '.[].name' "$LABELS" | sort | uniq -d)
	[ -z "$dups" ] || {
		echo "FAIL: duplicate label names: $dups" >&2
		return 1
	}
}

# v0.19.0 #142: required generic labels — every consumer needs these
# because the plugin's skills/workflows reference them by name.
@test "labels.yml contains plan-me (cr-plan skill dep)" {
	yq -r '.[].name' "$LABELS" | grep -Fxq "plan-me"
}

@test "labels.yml contains no-plan (operator opt-out)" {
	yq -r '.[].name' "$LABELS" | grep -Fxq "no-plan"
}

@test "labels.yml contains Renovate semver triplet" {
	yq -r '.[].name' "$LABELS" | grep -Fxq "patch"
	yq -r '.[].name' "$LABELS" | grep -Fxq "minor"
	yq -r '.[].name' "$LABELS" | grep -Fxq "major"
}

@test "labels.yml contains generic auto: labels" {
	yq -r '.[].name' "$LABELS" | grep -Fxq "auto:renovate"
	yq -r '.[].name' "$LABELS" | grep -Fxq "auto:trivy-scan"
	yq -r '.[].name' "$LABELS" | grep -Fxq "auto:trivy-post-merge"
}

@test "labels.yml contains all 6 priority labels" {
	for p in p0 p0-proposed p1 p2 p3 needs-triage; do
		yq -r '.[].name' "$LABELS" | grep -Fxq "priority:$p" || {
			echo "FAIL: missing priority:$p" >&2
			return 1
		}
	done
}

@test "labels.yml contains required type labels" {
	for t in bug enhancement epic brainstorm documentation question; do
		yq -r '.[].name' "$LABELS" | grep -Fxq "$t" || {
			echo "FAIL: missing type label '$t'" >&2
			return 1
		}
	done
}

@test "labels-spec.md exists and references the promotion rule" {
	[ -f "$SPEC" ]
	grep -q "promotion rule" "$SPEC"
	grep -q "Generic tier" "$SPEC"
	grep -q "Domain-extension tier" "$SPEC"
}
