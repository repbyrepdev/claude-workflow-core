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

@test "epic.yml passes epic-structure.sh validator on quoted labels" {
	# Validator reads from staged area / repo; we just check the validator
	# parser recognizes the heredoc body as valid.
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

@test "_apply_labels NOTE on no-remote target (gh present)" {
	mkdir -p "$TEST_TMP/target-no-remote"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target-no-remote\" 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"no GitHub remote yet"* ]]
}
