#!/usr/bin/env bats
# covers: hooks/bash4-features-write-guard.sh
#
# #2645 — the Edit path reconstructs the POST-EDIT file (disk content with
# old_string -> new_string applied, Edit-tool semantics) and scans that
# whole, so shebang downgrades, waiver deletions, and disk-context feature
# joins are judged against the file that will actually exist. Failure mode
# of a graft/reconstruction regression is silent ALLOW — these tests hold
# the door. hook_deny emits {"permissionDecision":"deny"} JSON on stdout
# and exits 0 — assert on stdout, never on exit code.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/bash4-features-write-guard.sh"
	[ -f "$HOOK" ]
	TEST_TMP=$(mktemp -d -t b4wg.XXXXXX) || return 1
}

teardown() {
	cd /tmp || return 0
	if [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */b4wg.* ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# _run_edit <target> <old_string> <new_string> — pipe an Edit payload.
_run_edit() {
	local payload
	payload=$(jq -cn --arg fp "$1" --arg os "$2" --arg ns "$3" \
		'{tool_name: "Edit", tool_input: {file_path: $fp, old_string: $os, new_string: $ns}}')
	run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
}

@test "Edit that swaps a clean line for a bash-4 feature in a bin-bash file DENIES (#2645)" {
	local target="$TEST_TMP/target.sh"
	printf '#!/bin/bash\nset -u\necho existing\n' >"$target"
	_run_edit "$target" 'echo existing' 'mapfile -d "" arr <input'
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "same edit against an env-bash file is allowed (post-edit shebang is safe)" {
	local target="$TEST_TMP/safe.sh"
	printf '#!/usr/bin/env bash\nset -u\necho existing\n' >"$target"
	_run_edit "$target" 'echo existing' 'mapfile -d "" arr <input'
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "shebang-DOWNGRADE edit is denied: post-edit file is scanned, not pre-edit (#2645 r2)" {
	# Pre-edit the file is safe (env bash) and carries a bash-4 feature;
	# the edit only swaps the shebang. The r1 graft judged the PRE-edit
	# shebang and allowed this; reconstruction must deny.
	local target="$TEST_TMP/downgrade.sh"
	printf '#!/usr/bin/env bash\nset -u\ndeclare -A m\n' >"$target"
	_run_edit "$target" '#!/usr/bin/env bash' '#!/bin/bash'
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "waiver-DELETING edit is denied at the guard, not just at commit (#2645 r2)" {
	local target="$TEST_TMP/waived.sh"
	printf '%s\n%s\n%s\n' '#!/bin/bash' \
		'# bash4-waiver: globstar — guarded use, degradation documented for this fixture' \
		'shopt -s globstar 2>/dev/null || true' >"$target"
	_run_edit "$target" '# bash4-waiver: globstar — guarded use, degradation documented for this fixture' '# waiver removed'
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "edit keeping a valid waiver stays allowed (post-edit waiver honored)" {
	local target="$TEST_TMP/keep.sh"
	printf '%s\n%s\n%s\n' '#!/bin/bash' \
		'# bash4-waiver: globstar — guarded use, degradation documented for this fixture' \
		'set -u' >"$target"
	_run_edit "$target" 'set -u' $'set -u\nshopt -s globstar 2>/dev/null || true'
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'"permissionDecision":"deny"'* ]]
}
