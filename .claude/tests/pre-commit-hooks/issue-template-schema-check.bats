#!/usr/bin/env bats
# covers: pre-commit-hooks/issue-template-schema-check.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	HOOK="${REPO_ROOT}/pre-commit-hooks/issue-template-schema-check.sh"
	TEST_TMP=$(mktemp -d -t tmpl-check.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .github/ISSUE_TEMPLATE pre-commit-hooks
		cp "$HOOK" pre-commit-hooks/issue-template-schema-check.sh
		chmod +x pre-commit-hooks/issue-template-schema-check.sh
		# Seed _spec.yml with the same shape as the production file
		cat >.github/ISSUE_TEMPLATE/_spec.yml <<'YAML'
schema_version: 1
templates:
  bug:
    file: bug.yml
    required_ids: [parent, area, description]
    required_labels: [bug]
  epic:
    file: epic.yml
    required_ids: [area, goal, scope, sub_issues, acceptance, rollout, rollback]
    required_labels: [epic, enhancement]
YAML
		git commit --allow-empty -q -m init
	) || {
		echo "FATAL: fixture init failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp 2>/dev/null || cd "${BATS_TEST_DIRNAME:-/}" 2>/dev/null || true
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */tmpl-check.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

_write_valid_bug() {
	cat >"$TEST_TMP/.github/ISSUE_TEMPLATE/bug.yml" <<'YAML'
name: Bug
labels: ["bug"]
body:
  - type: input
    id: parent
    attributes:
      label: Parent
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      options: [Infra]
    validations:
      required: true
  - type: textarea
    id: description
    attributes:
      label: What's happening?
    validations:
      required: true
YAML
}

_write_valid_epic() {
	cat >"$TEST_TMP/.github/ISSUE_TEMPLATE/epic.yml" <<'YAML'
name: Epic
labels: ["epic", "enhancement"]
body:
  - type: dropdown
    id: area
    attributes:
      label: Area
      options: [Infra]
    validations:
      required: true
  - type: textarea
    id: goal
    attributes:
      label: Goal
    validations:
      required: true
  - type: textarea
    id: scope
    attributes:
      label: Scope
    validations:
      required: true
  - type: textarea
    id: sub_issues
    attributes:
      label: Sub-issues
    validations:
      required: true
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance
    validations:
      required: true
  - type: textarea
    id: rollout
    attributes:
      label: Rollout
    validations:
      required: true
  - type: textarea
    id: rollback
    attributes:
      label: Rollback
    validations:
      required: true
YAML
}

@test "passes when no template staged" {
	cd "$TEST_TMP" || return 1
	echo "unrelated" >README.md
	git add README.md
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid bug.yml + epic.yml (both declared in spec)" {
	cd "$TEST_TMP" || return 1
	_write_valid_bug
	_write_valid_epic
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid epic.yml alone when bug.yml also present" {
	cd "$TEST_TMP" || return 1
	_write_valid_bug
	_write_valid_epic
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	git commit -q -m "seed"
	# Make a no-op edit on epic + stage only it
	echo "" >>.github/ISSUE_TEMPLATE/epic.yml
	git add .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "fails on bug.yml missing required id 'parent'" {
	cd "$TEST_TMP" || return 1
	_write_valid_epic
	cat >.github/ISSUE_TEMPLATE/bug.yml <<'YAML'
name: Bug
labels: ["bug"]
body:
  - type: dropdown
    id: area
    attributes:
      label: Area
      options: [Infra]
  - type: textarea
    id: description
    attributes:
      label: What's happening?
YAML
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"missing 'id: parent'"* ]]
}

@test "fails on bug.yml missing required label 'bug'" {
	cd "$TEST_TMP" || return 1
	_write_valid_epic
	cat >.github/ISSUE_TEMPLATE/bug.yml <<'YAML'
name: Bug
labels: []
body:
  - type: input
    id: parent
    attributes:
      label: Parent
  - type: dropdown
    id: area
    attributes:
      label: Area
      options: [Infra]
  - type: textarea
    id: description
    attributes:
      label: What's happening?
YAML
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"missing 'bug'"* ]]
}

@test "fails on epic.yml missing rollback id" {
	cd "$TEST_TMP" || return 1
	_write_valid_bug
	cat >.github/ISSUE_TEMPLATE/epic.yml <<'YAML'
name: Epic
labels: ["epic", "enhancement"]
body:
  - type: dropdown
    id: area
    attributes:
      label: Area
      options: [Infra]
  - type: textarea
    id: goal
    attributes:
      label: Goal
  - type: textarea
    id: scope
    attributes:
      label: Scope
  - type: textarea
    id: sub_issues
    attributes:
      label: Sub-issues
  - type: textarea
    id: acceptance
    attributes:
      label: Acceptance
  - type: textarea
    id: rollout
    attributes:
      label: Rollout
YAML
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"missing 'id: rollback'"* ]]
}

@test "fails on missing template file declared in spec" {
	cd "$TEST_TMP" || return 1
	# Only stage bug.yml; spec declares both bug + epic. Hook iterates the
	# spec, finds epic.yml absent on disk, surfaces a violation.
	_write_valid_bug
	git add .github/ISSUE_TEMPLATE/bug.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"declared in spec but missing"* ]]
}

@test "exits 2 on missing spec file" {
	cd "$TEST_TMP" || return 1
	_write_valid_bug
	_write_valid_epic
	rm .github/ISSUE_TEMPLATE/_spec.yml
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"spec file missing"* ]]
}

@test "exits 2 on corrupt spec YAML (yq parse failure)" {
	cd "$TEST_TMP" || return 1
	_write_valid_bug
	_write_valid_epic
	cat >.github/ISSUE_TEMPLATE/_spec.yml <<'YAML'
schema_version: 1
templates: [
  - bug:
YAML
	git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"yq failed parsing"* ]]
}

@test "bypass env ISSUE_TEMPLATE_SCHEMA_SKIP=1 lets bad template through" {
	cd "$TEST_TMP" || return 1
	cat >.github/ISSUE_TEMPLATE/bug.yml <<'YAML'
name: Bug
labels: []
body: []
YAML
	git add .github/ISSUE_TEMPLATE/bug.yml
	ISSUE_TEMPLATE_SCHEMA_SKIP=1 run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
	[[ $output == *"ISSUE_TEMPLATE_SCHEMA_SKIP"* ]]
}
