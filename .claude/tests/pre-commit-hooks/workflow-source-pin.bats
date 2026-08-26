#!/usr/bin/env bats
# covers: pre-commit-hooks/workflow-source-pin.sh

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	HOOK="${REPO_ROOT}/pre-commit-hooks/workflow-source-pin.sh"
	TEST_TMP=$(mktemp -d -t wf-pin.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	(
		set -e
		cd "$TEST_TMP"
		git init -q -b main
		git config user.email t@t
		git config user.name t
		mkdir -p .github/workflows .github/workflows-source pre-commit-hooks
		cp "$HOOK" pre-commit-hooks/workflow-source-pin.sh
		chmod +x pre-commit-hooks/workflow-source-pin.sh
		# Minimal cascade.yml
		cat >.github/workflows-cascade.yml <<'YAML'
schema_version: 1
cascade:
  - pr-lint.yml
  - gitleaks.yml
no_cascade:
  - plugin-self-only.yml
planned: []
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
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */wf-pin.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Write byte-identical pr-lint + gitleaks in source + live dirs.
_write_workflow_pair() {
	local name=$1
	local content=$2
	echo "$content" >"$TEST_TMP/.github/workflows-source/${name}"
	echo "$content" >"$TEST_TMP/.github/workflows/${name}"
}

_write_all_valid_pairs() {
	_write_workflow_pair pr-lint.yml "name: pr-lint
on: pull_request
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint"
	_write_workflow_pair gitleaks.yml "name: gitleaks
on: push
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - run: echo scan"
}

@test "passes when no workflow change staged" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	git add .github/
	git commit -q -m "seed"
	# Stage an unrelated file
	echo "unrelated" >README.md
	git add README.md
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 0 ]
}

@test "passes when all cascade workflows are hash-equivalent" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 0 ]
}

@test "fails on hash drift (source edited, live stale)" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	# Edit source only
	echo "# drift" >>.github/workflows-source/pr-lint.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"drift"* ]] || return 1
	[[ $output == *"pr-lint.yml"* ]]
}

@test "fails on hash drift (live edited, source stale)" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	echo "# drift" >>.github/workflows/pr-lint.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"drift"* ]]
}

@test "fails when cascade workflow missing in source" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	rm .github/workflows-source/pr-lint.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"missing on disk"* ]] || return 1
	[[ $output == *"pr-lint.yml"* ]]
}

@test "fails when cascade workflow missing in live" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	rm .github/workflows/pr-lint.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"missing on disk"* ]]
}

# Phase 1 r1 silent-failure-hunter HIGH: empty cascade[] is refused so
# operators can't accidentally silent-disable the gate. Use the
# `planned:` list to track future-to-cascade workflows, not an empty
# `cascade:`.
@test "fails on empty cascade list (no silent-disable)" {
	cd "$TEST_TMP" || return 1
	cat >.github/workflows-cascade.yml <<'YAML'
schema_version: 1
cascade: []
no_cascade: []
planned: []
YAML
	echo "name: foo" >.github/workflows/foo.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"empty cascade"* ]]
}

# Phase 1 r1 dup-HIGH (code-reviewer + silent-failure-hunter): path-
# traversal cascade entries must be rejected before path-join.
@test "fails on cascade entry with path-traversal '..'" {
	cd "$TEST_TMP" || return 1
	cat >.github/workflows-cascade.yml <<'YAML'
schema_version: 1
cascade:
  - "../../etc/passwd"
no_cascade: []
planned: []
YAML
	echo "name: foo" >.github/workflows/foo.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"path traversal"* || $output == *"unsafe shape"* || $output == *"bare filename"* ]]
}

@test "fails on cascade entry with slash" {
	cd "$TEST_TMP" || return 1
	cat >.github/workflows-cascade.yml <<'YAML'
schema_version: 1
cascade:
  - "subdir/pr-lint.yml"
no_cascade: []
planned: []
YAML
	echo "name: foo" >.github/workflows/foo.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"unsafe shape"* ]]
}

# Phase 1 r1 code-reviewer F2: orphan workflows in workflows-source/
# (not listed in any of cascade/no_cascade/planned) must surface.
@test "fails on orphan workflow in workflows-source/" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	# Add an orphan source-only file not declared in cascade.yml
	echo "name: orphan" >.github/workflows-source/orphan.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"orphan"* ]] || return 1
	[[ $output == *"orphan.yml"* ]]
}

# Phase 1 r1 silent-failure-hunter CRITICAL: shasum missing would
# return empty hash + rc=0 → vacuous pass. The hook now probes
# `command -v shasum` and exits 2 if absent. Static-grep test to
# lock in the probe — a runtime shasum-strip test is too env-
# dependent (shasum + yq + git often share PATH dirs on macOS).
@test "hook source declares shasum-required probe (CRITICAL silent-failure guard)" {
	grep -qE 'command -v shasum.*\|\| \{' "$HOOK"
	grep -qE 'shasum required' "$HOOK"
}

# Lock in the 64-char hex hash-shape validation (defense against
# shasum producing unexpected output on degraded systems).
@test "hook source declares 64-hex-char hash shape validator" {
	grep -qE '\[0-9a-f\]\{64\}' "$HOOK"
}

@test "exits 2 on missing cascade.yml" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	rm .github/workflows-cascade.yml
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 2 ]
	[[ $output == *"cascade file missing"* ]]
}

@test "exits 2 on corrupt cascade.yml (yq parse failure)" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	cat >.github/workflows-cascade.yml <<'YAML'
schema_version: 1
cascade: [
  - unclosed
YAML
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 2 ]
	[[ $output == *"yq failed parsing"* ]]
}

@test "exits 1 on wrong schema_version" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	cat >.github/workflows-cascade.yml <<'YAML'
schema_version: 99
cascade: []
YAML
	git add .github/
	run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 1 ]
	[[ $output == *"schema_version must equal 1"* ]]
}

@test "bypass env WORKFLOW_SOURCE_PIN_SKIP=1 lets drift through" {
	cd "$TEST_TMP" || return 1
	_write_all_valid_pairs
	echo "# drift" >>.github/workflows-source/pr-lint.yml
	git add .github/
	WORKFLOW_SOURCE_PIN_SKIP=1 run pre-commit-hooks/workflow-source-pin.sh
	[ "$status" -eq 0 ]
	[[ $output == *"WORKFLOW_SOURCE_PIN_SKIP"* ]]
}
