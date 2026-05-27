#!/usr/bin/env bats
# covers: .github/required-checks-list.yml

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
	CHECKS_YML="${REPO_ROOT}/.github/required-checks-list.yml"
}

@test "required-checks-list.yml is valid YAML" {
	run yq . "$CHECKS_YML"
	[ "$status" -eq 0 ]
}

@test "required[] section exists and is non-empty" {
	run yq -r '.required | length' "$CHECKS_YML"
	[ "$status" -eq 0 ]
	[ "$output" -gt 0 ]
}

@test "advisory[] section is declared (may be empty)" {
	run yq -r 'has("advisory")' "$CHECKS_YML"
	[ "$status" -eq 0 ]
	[ "$output" = "true" ]
}

@test "every required entry has check_name (string)" {
	while IFS= read -r name; do
		[ -n "$name" ]
		[ "$name" != "null" ]
	done < <(yq -r '.required[].check_name' "$CHECKS_YML")
}

@test "every required entry has workflow_file (string or null)" {
	while IFS= read -r wf; do
		# yq -r returns the literal value; null is rendered as 'null'
		[ "$wf" != "" ] || [ "$wf" = "null" ]
	done < <(yq -r '.required[].workflow_file' "$CHECKS_YML")
}

@test "every required entry has event (string or null)" {
	while IFS= read -r ev; do
		[ "$ev" != "" ] || [ "$ev" = "null" ]
	done < <(yq -r '.required[].event' "$CHECKS_YML")
}

@test "every required entry has notes (non-empty string)" {
	count=$(yq -r '.required | length' "$CHECKS_YML")
	for i in $(seq 0 $((count - 1))); do
		notes=$(yq -r ".required[$i].notes" "$CHECKS_YML")
		[ -n "$notes" ]
		[ "$notes" != "null" ]
	done
}

@test "workflow_file=null entries have event=null (paired contract)" {
	# For every entry where workflow_file is null, event must also be null.
	count=$(yq -r '.required[] | select(.workflow_file == null and .event != null) | .check_name' "$CHECKS_YML" | grep -c . || true)
	[ "$count" = "0" ]
}

@test "workflow_file != null entries reference an existing workflow under .github/workflows/" {
	while IFS= read -r entry; do
		[ -z "$entry" ] && continue
		name=$(echo "$entry" | awk -F'|' '{print $1}')
		wf=$(echo "$entry" | awk -F'|' '{print $2}')
		[ -z "$wf" ] && continue
		[ "$wf" = "null" ] && continue
		[ -f "${REPO_ROOT}/.github/workflows/${wf}" ]
	done < <(yq -r '.required[] | "\(.check_name)|\(.workflow_file)"' "$CHECKS_YML")
}

@test "pr-merge skill query (.required[].check_name) returns expected names" {
	names=$(yq -r '.required[].check_name' "$CHECKS_YML" | sort)
	expected="CodeRabbit
gitleaks
pr-lint"
	[ "$names" = "$expected" ]
}
