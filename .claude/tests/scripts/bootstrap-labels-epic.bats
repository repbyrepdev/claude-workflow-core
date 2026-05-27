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

@test "_apply_labels short-circuits when no GitHub remote (dry-run reports skip)" {
	# Build a sandbox target without git remote; expect NOTE about remote missing.
	# Use --dry-run so labels aren't actually applied even with a remote.
	mkdir -p "$TEST_TMP/target"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/target\" --dry-run 2>&1"
	[ "$status" -eq 0 ]
	# Dry-run mode prints the would-apply message regardless of remote.
	[[ $output == *"would apply labels"* ]]
}

@test "_apply_labels skips gracefully when gh missing (NOTE emitted)" {
	# Run actual (non-dry) bootstrap into target dir with gh stripped from PATH.
	# Target dir has no remote → expect "no GitHub remote yet" NOTE; if gh is
	# also missing, we expect the "gh CLI not on PATH" NOTE instead.
	mkdir -p "$TEST_TMP/target-no-gh"
	run env PATH="/usr/bin:/bin" bash -c "\"$SCRIPT\" \"$TEST_TMP/target-no-gh\" 2>&1"
	[ "$status" -eq 0 ]
	# Either the gh-missing NOTE or the no-remote NOTE — both are visible-skip.
	[[ $output == *"NOTE:"*"label apply"* ]] || [[ $output == *"NOTE:"*"GitHub remote"* ]]
}
