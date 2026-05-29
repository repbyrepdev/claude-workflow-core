#!/usr/bin/env bats
# covers: scripts/apply-branch-protection.sh
#
# Tests for the SSOT → GitHub branch-protection applicator (#172).
# Mocks gh/yq/jq via PATH shimming to avoid real GitHub API calls.

setup() {
	SCRIPT="${BATS_TEST_DIRNAME}/../../../scripts/apply-branch-protection.sh"
	TEST_TMP=$(mktemp -d -t apply-branch-protection.XXXXXX) || {
		echo "FATAL: mktemp failed" >&2
		return 1
	}
	mkdir -p "$TEST_TMP/.github" "$TEST_TMP/scripts" "$TEST_TMP/bin"
	# Real script needs to live at the inferred REPO_ROOT/scripts/ path,
	# so symlink it into the test repo.
	ln -s "$SCRIPT" "$TEST_TMP/scripts/apply-branch-protection.sh"
}

teardown() {
	# shellcheck disable=SC2164
	cd /tmp
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */apply-branch-protection.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# Helper: write a minimal SSOT with N required checks.
_write_ssot() {
	local root=$1
	shift
	{
		echo "required:"
		for name in "$@"; do
			echo "  - check_name: $name"
			echo "    workflow_file: null"
			echo "    event: null"
			echo "    notes: test"
		done
	} >"$root/.github/required-checks-list.yml"
}

# Helper: stub gh + jq + yq on PATH. gh stub reads $GH_FIXTURE for
# the protection-API response; on PATCH it writes to $GH_PATCH_LOG.
_install_stubs() {
	local root=$1
	cat >"$root/bin/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
"repo view")
	# repo view --json owner --jq '.owner.login' or --json name --jq '.name'
	while [ $# -gt 0 ]; do
		case "$1" in
		--jq)
			shift
			case "$1" in
			.owner.login) echo "testowner" ;;
			.name) echo "testrepo" ;;
			esac
			shift
			;;
		*) shift ;;
		esac
	done
	;;
"api ")
	# stripped; fall through to "api"
	;;
esac
if [ "$1" = "api" ]; then
	if [ "${GH_FAIL_FETCH:-0}" = "1" ]; then
		echo "gh: Branch not protected (HTTP 404)" >&2
		exit 1
	fi
	if [ "${2:-}" = "--method" ]; then
		# PATCH/PUT — capture body to GH_PATCH_LOG
		while [ $# -gt 0 ] && [ "$1" != "--input" ]; do shift; done
		[ "$1" = "--input" ] && cat >"${GH_PATCH_LOG:-/dev/null}"
		exit 0
	fi
	# GET
	cat "${GH_FIXTURE:-/dev/null}"
fi
EOF
	chmod +x "$root/bin/gh"
}

@test "exits 0 when --help" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Applies the required-checks list"* ]]
}

@test "exits 2 on unknown arg" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
}

@test "exits 2 when SSOT missing" {
	(
		cd "$TEST_TMP" || exit 1
		_install_stubs "$TEST_TMP"
		PATH="$TEST_TMP/bin:$PATH" run "$TEST_TMP/scripts/apply-branch-protection.sh" --dry-run
		[ "$status" -eq 2 ]
	)
}

@test "--check exits 1 with drift on branch-not-protected" {
	_write_ssot "$TEST_TMP" CodeRabbit gitleaks pr-lint
	_install_stubs "$TEST_TMP"
	GH_FAIL_FETCH=1 PATH="$TEST_TMP/bin:$PATH" run "$TEST_TMP/scripts/apply-branch-protection.sh" --check
	[ "$status" -eq 1 ]
	[[ $output == *"DRIFT"* ]]
	[[ $output == *"branch not protected"* ]]
}

@test "--check exits 0 on match" {
	_write_ssot "$TEST_TMP" CodeRabbit
	_install_stubs "$TEST_TMP"
	echo '{"required_status_checks":{"strict":true,"checks":[{"context":"CodeRabbit","app_id":-1}]},"enforce_admins":{"enabled":false}}' >"$TEST_TMP/fixture.json"
	GH_FIXTURE="$TEST_TMP/fixture.json" PATH="$TEST_TMP/bin:$PATH" run "$TEST_TMP/scripts/apply-branch-protection.sh" --check
	[ "$status" -eq 0 ]
	[[ $output == *"matches SSOT"* ]]
}

@test "--check exits 1 on different check set" {
	_write_ssot "$TEST_TMP" CodeRabbit gitleaks
	_install_stubs "$TEST_TMP"
	echo '{"required_status_checks":{"strict":true,"checks":[{"context":"CodeRabbit","app_id":-1}]},"enforce_admins":{"enabled":false}}' >"$TEST_TMP/fixture.json"
	GH_FIXTURE="$TEST_TMP/fixture.json" PATH="$TEST_TMP/bin:$PATH" run "$TEST_TMP/scripts/apply-branch-protection.sh" --check
	[ "$status" -eq 1 ]
	[[ $output == *"DRIFT"* ]]
}

@test "--dry-run prints checks-array body" {
	_write_ssot "$TEST_TMP" CodeRabbit gitleaks
	_install_stubs "$TEST_TMP"
	GH_FAIL_FETCH=1 PATH="$TEST_TMP/bin:$PATH" run "$TEST_TMP/scripts/apply-branch-protection.sh" --dry-run
	[ "$status" -eq 0 ]
	[[ $output == *"DRY RUN"* ]]
	[[ $output == *"CodeRabbit"* ]]
	[[ $output == *"gitleaks"* ]]
}
