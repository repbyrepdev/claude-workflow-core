#!/usr/bin/env bats
# covers: hooks/bash4-features-write-guard.sh
#
# #2645 r1 — the Edit-fragment grafting is behavior unique to this hook
# (never exercised through the SSOT lib's own tests) and its failure mode
# is a silent ALLOW: if the graft regresses, the bare fragment carries no
# shebang, the detector sees a safe file, and the anchor class (a bash-4
# feature EDITED into a #!/bin/bash file) passes with no error anywhere.
# hook_deny emits {"permissionDecision":"deny"} JSON on stdout and exits 0
# — assert on stdout, never on exit code.

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

# _run_edit <disk-shebang> <new_string> — create an on-disk .sh with the
# given shebang, then pipe an Edit payload for it into the hook.
_run_edit() {
	local target="$TEST_TMP/target.sh"
	printf '%s\nset -u\necho existing\n' "$1" >"$target"
	local payload
	payload=$(jq -cn --arg fp "$target" --arg ns "$2" \
		'{tool_name: "Edit", tool_input: {file_path: $fp, new_string: $ns}}')
	run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
}

@test "Edit grafting denies a bash-4 fragment headed into a #!/bin/bash file (#2645 r1)" {
	_run_edit '#!/bin/bash' 'mapfile -d "" arr <input'
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'"permissionDecision":"deny"'* ]]
}

@test "Edit fragment against an env-bash file is allowed (graft carries the safe shebang)" {
	_run_edit '#!/usr/bin/env bash' 'mapfile -d "" arr <input'
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'"permissionDecision":"deny"'* ]]
}

@test "Edit fragment honors the on-disk file's waiver (graft carries waiver lines)" {
	local target="$TEST_TMP/waived.sh"
	printf '%s\n%s\nset -u\n' '#!/bin/bash' \
		'# bash4-waiver: globstar — guarded use, degradation documented for this fixture' >"$target"
	local payload
	payload=$(jq -cn --arg fp "$target" \
		'{tool_name: "Edit", tool_input: {file_path: $fp, new_string: "shopt -s globstar 2>/dev/null || true"}}')
	run bash -c 'printf %s "$1" | bash "$2"' _ "$payload" "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'"permissionDecision":"deny"'* ]]
}
