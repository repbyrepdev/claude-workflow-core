#!/usr/bin/env bats
# covers: .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/feature.yml .github/ISSUE_TEMPLATE/task.yml .github/ISSUE_TEMPLATE/epic.yml .github/ISSUE_TEMPLATE/brainstorm.yml .github/ISSUE_TEMPLATE/_spec.yml scripts/bootstrap-repo.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../.." 2>&1 && pwd) || {
		echo "FATAL: cd to repo root failed: $REPO_ROOT" >&2
		return 1
	}
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

# v0.19.1 (#143): non-epic templates require parent + area dropdown.
# Epic + brainstorm have area dropdown but no parent input.
_assert_template_with_parent() {
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

_assert_template_no_parent() {
	local path=$1
	[ -f "$path" ]
	run yq . "$path"
	[ "$status" -eq 0 ]
	area_type=$(yq -r '.body[] | select(.id == "area") | .type' "$path")
	[ "$area_type" = "dropdown" ]
	option_count=$(yq -r '.body[] | select(.id == "area") | .attributes.options | length' "$path")
	[ "$option_count" -gt 0 ]
	area_required=$(yq -r '.body[] | select(.id == "area") | .validations.required' "$path")
	[ "$area_required" = "true" ]
}

@test "bug.yml has required parent + area dropdown" {
	_assert_template_with_parent "${REPO_ROOT}/.github/ISSUE_TEMPLATE/bug.yml"
}

@test "feature.yml has required parent + area dropdown" {
	_assert_template_with_parent "${REPO_ROOT}/.github/ISSUE_TEMPLATE/feature.yml"
}

@test "task.yml has required parent + area dropdown" {
	_assert_template_with_parent "${REPO_ROOT}/.github/ISSUE_TEMPLATE/task.yml"
}

@test "epic.yml has area dropdown (no parent — epic IS the top)" {
	_assert_template_no_parent "${REPO_ROOT}/.github/ISSUE_TEMPLATE/epic.yml"
}

@test "brainstorm.yml has area dropdown (no parent — brainstorm is top-level)" {
	_assert_template_no_parent "${REPO_ROOT}/.github/ISSUE_TEMPLATE/brainstorm.yml"
}

# v0.19.1 (#143): _spec.yml is the SSOT for required ids + labels.
@test "_spec.yml exists + parses + declares all 5 templates" {
	SPEC="${REPO_ROOT}/.github/ISSUE_TEMPLATE/_spec.yml"
	[ -f "$SPEC" ]
	run yq . "$SPEC"
	[ "$status" -eq 0 ]
	for t in bug feature task epic brainstorm; do
		actual=$(yq -r ".templates.${t}.file" "$SPEC")
		[ "$actual" = "${t}.yml" ]
	done
}

# v0.19.1 (#143): every option in every template's area dropdown is
# documented in the file (cross-check). Options are richer than area:*
# labels — ai-triage maps the choice to a coarser label, options
# describe scope at finer granularity.
@test "area dropdown options are non-empty across all 5 templates" {
	for t in bug feature task epic brainstorm; do
		opts=$(yq -r '.body[] | select(.id == "area") | .attributes.options[]' "${REPO_ROOT}/.github/ISSUE_TEMPLATE/${t}.yml")
		[ -n "$opts" ]
	done
}

@test "bootstrap-repo.sh heredocs deep-match the live templates (id, type, required)" {
	for tpl in bug feature task epic brainstorm; do
		live="${REPO_ROOT}/.github/ISSUE_TEMPLATE/${tpl}.yml"
		awk "/^_write \\.github\\/ISSUE_TEMPLATE\\/${tpl}\\.yml 644 <<'EOF'\$/,/^EOF\$/" "$SCRIPT" |
			sed '1d;$d' >"$TEST_TMP/${tpl}.yml"
		[ -s "$TEST_TMP/${tpl}.yml" ]
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
