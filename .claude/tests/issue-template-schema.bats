#!/usr/bin/env bats
# covers: .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/feature.yml .github/ISSUE_TEMPLATE/task.yml scripts/bootstrap-repo.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	TEST_TMP=$(mktemp -d -t issue-template-schema.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */issue-template-schema.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Assert a template has required parent + area-dropdown fields with required:true.
_assert_template() {
	local path=$1
	[ -f "$path" ]
	run yq . "$path"
	[ "$status" -eq 0 ]
	# parent field exists with required validation
	pid=$(yq -r '.body[] | select(.id == "parent") | .id' "$path")
	[ "$pid" = "parent" ]
	required=$(yq -r '.body[] | select(.id == "parent") | .validations.required' "$path")
	[ "$required" = "true" ]
	# area field is type dropdown with at least one option
	area_type=$(yq -r '.body[] | select(.id == "area") | .type' "$path")
	[ "$area_type" = "dropdown" ]
	option_count=$(yq -r '.body[] | select(.id == "area") | .attributes.options | length' "$path")
	[ "$option_count" -gt 0 ]
	area_required=$(yq -r '.body[] | select(.id == "area") | .validations.required' "$path")
	[ "$area_required" = "true" ]
}

@test "bug.yml has required parent + area dropdown" {
	_assert_template "${REPO_ROOT}/.github/ISSUE_TEMPLATE/bug.yml"
}

@test "feature.yml has required parent + area dropdown" {
	_assert_template "${REPO_ROOT}/.github/ISSUE_TEMPLATE/feature.yml"
}

@test "task.yml has required parent + area dropdown" {
	_assert_template "${REPO_ROOT}/.github/ISSUE_TEMPLATE/task.yml"
}

@test "every area dropdown option matches a labels.yml area:* label" {
	# Collect canonical area:* names from labels.yml (strip prefix, lowercase via tr)
	area_labels=$(yq -r '.[] | select(.name | test("^area:")) | .name' "${REPO_ROOT}/.github/labels.yml" | sed 's/^area://' | tr '[:upper:]' '[:lower:]')
	[ -n "$area_labels" ]
	for tpl in bug feature task; do
		while IFS= read -r opt; do
			[ -z "$opt" ] && continue
			normalized=$(echo "$opt" | tr '[:upper:]' '[:lower:]')
			echo "$area_labels" | grep -qFx "$normalized"
		done < <(yq -r '.body[] | select(.id == "area") | .attributes.options[]' "${REPO_ROOT}/.github/ISSUE_TEMPLATE/${tpl}.yml")
	done
}

@test "bootstrap-repo.sh heredocs match the live templates for parent + area shape" {
	for tpl in bug feature task; do
		live="${REPO_ROOT}/.github/ISSUE_TEMPLATE/${tpl}.yml"
		# Extract heredoc body from script
		awk "/^_write \\.github\\/ISSUE_TEMPLATE\\/${tpl}\\.yml 644 <<'EOF'$/,/^EOF$/" "$SCRIPT" |
			sed '1d;$d' >"$TEST_TMP/${tpl}.yml"
		# Same parent.id present
		live_pid=$(yq -r '.body[] | select(.id == "parent") | .id' "$live")
		heredoc_pid=$(yq -r '.body[] | select(.id == "parent") | .id' "$TEST_TMP/${tpl}.yml")
		[ "$live_pid" = "$heredoc_pid" ]
		[ "$heredoc_pid" = "parent" ]
		# Same area.type=dropdown present
		live_atype=$(yq -r '.body[] | select(.id == "area") | .type' "$live")
		heredoc_atype=$(yq -r '.body[] | select(.id == "area") | .type' "$TEST_TMP/${tpl}.yml")
		[ "$live_atype" = "$heredoc_atype" ]
		[ "$heredoc_atype" = "dropdown" ]
	done
}
