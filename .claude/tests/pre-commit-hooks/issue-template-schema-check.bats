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
		# Phase 1 r1 code-reviewer F4: extend fixture to all 5 templates
		# (mirror production _spec.yml exactly) so the empty-required_labels
		# branch + 4-id case (feature) are exercised.
		cat >.github/ISSUE_TEMPLATE/_spec.yml <<'YAML'
schema_version: 1
templates:
  bug:
    file: bug.yml
    required_ids: [parent, area, description]
    required_labels: [bug]
  feature:
    file: feature.yml
    required_ids: [parent, area, description, context]
    required_labels: [enhancement]
  task:
    file: task.yml
    required_ids: [parent, area, description]
    required_labels: []
  epic:
    file: epic.yml
    required_ids: [area, goal, scope, sub_issues, acceptance, rollout, rollback]
    required_labels: [epic, enhancement]
  brainstorm:
    file: brainstorm.yml
    required_ids: [area, topic, context]
    required_labels: [brainstorm]
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

_write_valid_feature() {
	cat >"$TEST_TMP/.github/ISSUE_TEMPLATE/feature.yml" <<'YAML'
name: Feature
labels: ["enhancement"]
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
      label: What?
  - type: textarea
    id: context
    attributes:
      label: Why?
YAML
}

_write_valid_task() {
	# Task has empty required_labels — exercises the "skip labels check"
	# branch.
	cat >"$TEST_TMP/.github/ISSUE_TEMPLATE/task.yml" <<'YAML'
name: Task
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
      label: What?
YAML
}

_write_valid_brainstorm() {
	cat >"$TEST_TMP/.github/ISSUE_TEMPLATE/brainstorm.yml" <<'YAML'
name: Brainstorm
labels: ["brainstorm"]
body:
  - type: dropdown
    id: area
    attributes:
      label: Area
      options: [Infra]
  - type: textarea
    id: topic
    attributes:
      label: Topic
  - type: textarea
    id: context
    attributes:
      label: Context
YAML
}

# Helper to write all 5 valid templates at once.
_write_all_valid() {
	_write_valid_bug
	_write_valid_feature
	_write_valid_task
	_write_valid_epic
	_write_valid_brainstorm
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

@test "passes on all 5 valid templates" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	git add .github/ISSUE_TEMPLATE/
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

@test "passes on valid epic.yml alone when all 5 templates also present" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	git add .github/ISSUE_TEMPLATE/
	git commit -q -m "seed"
	echo "" >>.github/ISSUE_TEMPLATE/epic.yml
	git add .github/ISSUE_TEMPLATE/epic.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

# Phase 1 r1 code-reviewer F4: exercise task.yml's empty required_labels
# branch — the "skip labels check" path was previously untested.
@test "passes on valid task.yml with empty required_labels" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	git add .github/ISSUE_TEMPLATE/
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

# Phase 1 r1 code-reviewer F1: prior grep-based label check substring-
# matched 'bug' inside 'debug'. New yq-parse-then-Fxq-match should reject
# 'debug' as a sibling label of required 'bug'.
@test "fails when labels list contains 'debug' instead of required 'bug'" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	cat >.github/ISSUE_TEMPLATE/bug.yml <<'YAML'
name: Bug
labels: ["debug"]
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
      label: What?
YAML
	git add .github/ISSUE_TEMPLATE/
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"labels list missing 'bug'"* ]]
}

# Phase 1 r1 code-reviewer F2: block-list labels form (not inline-array)
# should also pass since yq parses both.
@test "passes on block-list labels form" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	cat >.github/ISSUE_TEMPLATE/bug.yml <<'YAML'
name: Bug
labels:
  - bug
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
      label: What?
YAML
	git add .github/ISSUE_TEMPLATE/
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 0 ]
}

# Phase 1 r1 silent-failure-hunter F5: spec staged for deletion gets a
# specific message + unstage hint, not the generic "spec file missing".
@test "fails with unstage hint when _spec.yml staged for deletion" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	git add .github/ISSUE_TEMPLATE/
	git commit -q -m "seed"
	git rm -q .github/ISSUE_TEMPLATE/_spec.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"staged for deletion"* ]]
	[[ $output == *"git reset HEAD"* ]]
}

# Phase 1 r1 silent-failure-hunter F2: empty `templates:` map must
# refuse to vacuous-pass.
@test "exits 2 on empty templates: in spec" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	cat >.github/ISSUE_TEMPLATE/_spec.yml <<'YAML'
schema_version: 1
templates: {}
YAML
	git add .github/ISSUE_TEMPLATE/
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"zero templates"* ]]
}

@test "fails on bug.yml missing required id 'parent'" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
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
	_write_all_valid
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
	git add .github/ISSUE_TEMPLATE/
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	# Hook now reports "missing top-level 'labels:' list" when actual list
	# parses but is empty, OR "labels list missing 'bug'" when non-empty
	# but missing the required label. Empty list → first message.
	[[ $output == *"labels"* ]] && [[ $output == *"bug"* || $output == *"list"* ]]
}

@test "fails on epic.yml missing rollback id" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
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

# Phase 1 r1 silent-failure-hunter F4: renamed for clarity — hook
# iterates the SPEC, not the staged set. Any spec-declared template
# missing on disk triggers this regardless of which file was staged.
@test "fails when spec-declared template absent from disk" {
	cd "$TEST_TMP" || return 1
	# Write only bug.yml; spec declares 5. Hook will find feature/task/
	# epic/brainstorm absent.
	_write_valid_bug
	git add .github/ISSUE_TEMPLATE/bug.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 1 ]
	[[ $output == *"declared in spec but missing"* ]]
}

@test "exits 2 on missing spec file" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	rm .github/ISSUE_TEMPLATE/_spec.yml
	# Stage just bug.yml (any template stage triggers the hook).
	git add .github/ISSUE_TEMPLATE/bug.yml
	run pre-commit-hooks/issue-template-schema-check.sh
	[ "$status" -eq 2 ]
	[[ $output == *"spec file missing"* ]]
}

@test "exits 2 on corrupt spec YAML (yq parse failure)" {
	cd "$TEST_TMP" || return 1
	_write_all_valid
	cat >.github/ISSUE_TEMPLATE/_spec.yml <<'YAML'
schema_version: 1
templates: [
  - bug:
YAML
	git add .github/ISSUE_TEMPLATE/
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
