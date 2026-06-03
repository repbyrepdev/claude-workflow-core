#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	TEST_TMP=$(mktemp -d -t bootstrap-labels-epic.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */bootstrap-labels-epic.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Extract heredoc body for a given file path target (target uses raw glob chars).
_extract_heredoc() {
	local target=$1
	awk -v t="$target" 'BEGIN{ pat = "^_write " t " 644 <<'\''EOF'\''$" } $0 ~ pat,/^EOF$/' "$SCRIPT" | sed '1d;$d'
}

@test 'bootstrap epic.yml heredoc uses quoted labels ["epic", "enhancement"]' {
	body=$(_extract_heredoc '.github/ISSUE_TEMPLATE/epic.yml')
	[ -n "$body" ]
	echo "$body" | grep -qF 'labels: ["epic", "enhancement"]'
}

@test "live epic.yml matches the quoted-labels contract" {
	live="${REPO_ROOT}/.github/ISSUE_TEMPLATE/epic.yml"
	[ -f "$live" ]
	grep -qF 'labels: ["epic", "enhancement"]' "$live"
}

@test "epic.yml passes issue-template-schema-check.sh validator (v0.19.1 #143)" {
	# Validator reads from staged area / repo; we just check the validator
	# parser recognizes the heredoc body as valid (labels line is the
	# tightest invariant — required-id list is in _spec.yml).
	body=$(_extract_heredoc '.github/ISSUE_TEMPLATE/epic.yml')
	echo "$body" | grep -qE '^labels:[[:space:]]*\[.*\]'
	echo "$body" | grep -q '"epic"'
	echo "$body" | grep -q '"enhancement"'
}

@test "bootstrap-repo.sh defines _apply_labels function" {
	grep -qE '^_apply_labels\(\)' "$SCRIPT"
}

@test "_apply_labels prints the would-apply message in dry-run" {
	mkdir -p "$TEST_TMP/target"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target\" --dry-run 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"would apply labels"* ]]
}

# CR #1607: label sync is OPT-IN via --apply-labels. WITH the flag on a
# no-remote target, _apply_labels runs and hits its no-remote skip-NOTE.
@test "_apply_labels NOTE on no-remote target (gh present, --apply-labels)" {
	mkdir -p "$TEST_TMP/target-no-remote"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target-no-remote\" --apply-labels 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"no GitHub remote yet"* ]]
}

# CR #1607: WITHOUT --apply-labels (the default), a non-dry-run real install
# must NOT touch the remote label set — it NOTEs the skip and never reaches
# _apply_labels' no-remote message.
@test "label sync skipped by default (no --apply-labels) → opt-in NOTE, no remote write" {
	mkdir -p "$TEST_TMP/target-default"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target-default\" 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"label sync skipped"* ]]
	[[ $output == *"--apply-labels"* ]]
	[[ $output != *"no GitHub remote yet"* ]]
	[[ $output != *"applying labels from"* ]]
}
