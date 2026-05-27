#!/usr/bin/env bats
# covers: scripts/bootstrap-repo.sh pre-commit-hooks/bootstrap-heredoc-parity.sh

setup() {
	REPO_ROOT="${BATS_TEST_DIRNAME}/../../.."
	SCRIPT="${REPO_ROOT}/scripts/bootstrap-repo.sh"
	PARITY="${REPO_ROOT}/pre-commit-hooks/bootstrap-heredoc-parity.sh"
	TEST_TMP=$(mktemp -d -t bootstrap-verify.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */bootstrap-verify.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

@test "--verify --scope plugin returns 0 on plugin's own repo" {
	run bash -c "\"$SCRIPT\" \"$REPO_ROOT\" --verify --scope plugin 2>&1"
	[ "$status" -eq 0 ]
	[[ $output == *"verify clean"* ]]
}

@test "--verify --scope both finds consumer-only files missing in plugin repo" {
	run bash -c "\"$SCRIPT\" \"$REPO_ROOT\" --verify --scope both 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"missing: .claude/skills/ship-pr-cycle/run.sh"* ]]
}

@test "--verify on empty dir returns non-zero with FAILED summary" {
	mkdir -p "$TEST_TMP/empty"
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/empty\" --verify --scope plugin 2>&1"
	[ "$status" -eq 1 ]
	[[ $output == *"verify FAILED"* ]]
}

@test "--verify --scope=bogus rejects with error" {
	run bash -c "\"$SCRIPT\" \"$REPO_ROOT\" --verify --scope bogus 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"must be one of"* ]]
}

@test "--verify on non-existent dir returns 2 with ERROR" {
	run bash -c "\"$SCRIPT\" \"$TEST_TMP/does-not-exist\" --verify 2>&1"
	[ "$status" -eq 2 ]
	[[ $output == *"ERROR"* ]]
}

@test "parity gate exits 0 on plugin's own clean tree" {
	run "$PARITY"
	[ "$status" -eq 0 ]
}

@test "manifest schema accepts scope field defaulting to both" {
	count=$(yq -r '.files | length' "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
	[ "$count" -gt 0 ]
	for i in $(seq 0 $((count - 1))); do
		s=$(yq -r ".files[$i].scope // \"both\"" "${REPO_ROOT}/scripts/bootstrap-manifest.yml")
		case "$s" in
		plugin | consumer | both) ;;
		*) return 1 ;;
		esac
	done
}

@test "plugin-self-bootstrap-verify workflow exists + is valid YAML" {
	wf="${REPO_ROOT}/.github/workflows/plugin-self-bootstrap-verify.yml"
	[ -f "$wf" ]
	run yq . "$wf"
	[ "$status" -eq 0 ]
	grep -qF "scripts/bootstrap-repo.sh . --verify --scope plugin" "$wf"
}
