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

_assert_template() {
	local path=$1
	[ -f "$path" ]
	run yq . "$path"
	[ "$status" -eq 0 ]
	pid=$(yq -r '.body[] | select(.id == "parent") | .id' "$path")
	[ "$pid" = "parent" ]
	required=$(yq -r '.body[] | select(.id == "parent") | .validations.required' "$path")
	[ "$required" = "true" ]
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

@test "every area dropdown option matches a labels.yml area:* label (options ⊆ labels)" {
	area_labels=$(yq -r '.[] | select(.name | test("^area:")) | .name' "${REPO_ROOT}/.github/labels.yml" | sed 's/^area://' | tr '[:upper:]' '[:lower:]')
	[ -n "$area_labels" ]
	for tpl in bug feature task; do
		opt_count=0
		while IFS= read -r opt; do
			[ -z "$opt" ] && continue
			normalized=$(echo "$opt" | tr '[:upper:]' '[:lower:]')
			[ -n "$normalized" ]
			echo "$area_labels" | grep -qFx "$normalized"
			opt_count=$((opt_count + 1))
		done < <(yq -r '.body[] | select(.id == "area") | .attributes.options[]' "${REPO_ROOT}/.github/ISSUE_TEMPLATE/${tpl}.yml")
		[ "$opt_count" -gt 0 ]
	done
}

@test "every labels.yml area:* label appears as a dropdown option (labels ⊆ options)" {
	# Reverse direction — guards against labels.yml growing past templates.
	for tpl in bug feature task; do
		options=$(yq -r '.body[] | select(.id == "area") | .attributes.options[]' "${REPO_ROOT}/.github/ISSUE_TEMPLATE/${tpl}.yml" | tr '[:upper:]' '[:lower:]')
		[ -n "$options" ]
		while IFS= read -r label; do
			[ -z "$label" ] && continue
			# Strip area: prefix, lowercase to compare
			name=$(echo "$label" | sed 's/^area://' | tr '[:upper:]' '[:lower:]')
			[ -n "$name" ]
			echo "$options" | grep -qFx "$name"
		done < <(yq -r '.[] | select(.name | test("^area:")) | .name' "${REPO_ROOT}/.github/labels.yml")
	done
}

@test "bootstrap-repo.sh heredocs deep-match the live templates (id, type, options, required)" {
	for tpl in bug feature task; do
		live="${REPO_ROOT}/.github/ISSUE_TEMPLATE/${tpl}.yml"
		awk "/^_write \\.github\\/ISSUE_TEMPLATE\\/${tpl}\\.yml 644 <<'EOF'$/,/^EOF$/" "$SCRIPT" |
			sed '1d;$d' >"$TEST_TMP/${tpl}.yml"
		[ -s "$TEST_TMP/${tpl}.yml" ]
		# parent id + required
		live_pid=$(yq -r '.body[] | select(.id == "parent") | .id' "$live")
		heredoc_pid=$(yq -r '.body[] | select(.id == "parent") | .id' "$TEST_TMP/${tpl}.yml")
		[ "$live_pid" = "parent" ]
		[ "$live_pid" = "$heredoc_pid" ]
		live_preq=$(yq -r '.body[] | select(.id == "parent") | .validations.required' "$live")
		heredoc_preq=$(yq -r '.body[] | select(.id == "parent") | .validations.required' "$TEST_TMP/${tpl}.yml")
		[ "$live_preq" = "$heredoc_preq" ]
		[ "$heredoc_preq" = "true" ]
		# area type + required
		live_atype=$(yq -r '.body[] | select(.id == "area") | .type' "$live")
		heredoc_atype=$(yq -r '.body[] | select(.id == "area") | .type' "$TEST_TMP/${tpl}.yml")
		[ "$live_atype" = "dropdown" ]
		[ "$live_atype" = "$heredoc_atype" ]
		live_areq=$(yq -r '.body[] | select(.id == "area") | .validations.required' "$live")
		heredoc_areq=$(yq -r '.body[] | select(.id == "area") | .validations.required' "$TEST_TMP/${tpl}.yml")
		[ "$live_areq" = "$heredoc_areq" ]
		[ "$heredoc_areq" = "true" ]
		# area options[] deep-equal (sorted, lowercased)
		live_opts=$(yq -r '.body[] | select(.id == "area") | .attributes.options[]' "$live" | sort -u | tr '[:upper:]' '[:lower:]')
		heredoc_opts=$(yq -r '.body[] | select(.id == "area") | .attributes.options[]' "$TEST_TMP/${tpl}.yml" | sort -u | tr '[:upper:]' '[:lower:]')
		[ -n "$live_opts" ]
		[ "$live_opts" = "$heredoc_opts" ]
	done
}
