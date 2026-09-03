#!/usr/bin/env bats
# covers: pre-commit-hooks/review-config-check.sh
#
# First behavioral coverage for the #601 schema guard (added with #2651's
# optional `approach:` key): the required-agents floor, and the new
# optional-key contract — absent passes, non-empty string passes,
# wrong-typed value fails.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/review-config-check.sh"
	[ -f "$HOOK" ]
	FIX=$(mktemp -d -t rcc.XXXXXX) || return 1
	cd "$FIX" || return 1
	git init -q . || return 1
	mkdir -p .claude || return 1
}

teardown() {
	cd /tmp || return 0
	if [ -n "${FIX:-}" ] && [ -d "$FIX" ] && [[ $FIX == */rcc.* ]]; then
		rm -rf "$FIX"
	fi
}

# A minimal config satisfying every required key — the hook demands the
# full canonical 7-agent roster, each with scope/canonical_brief/
# dedup_key/output_shape.fields.
_write_valid_config() {
	: >.claude/review-config.yml
	printf '%s\n' 'agents:' >>.claude/review-config.yml
	local a
	for a in code-reviewer silent-failure-hunter comment-analyzer \
		pr-test-analyzer code-simplifier security-review semgrep; do
		printf '%s\n' \
			"  $a:" \
			'    scope: diff' \
			"    canonical_brief: $a brief" \
			'    dedup_key: file_line' \
			'    output_shape:' \
			'      fields:' \
			'        - severity' >>.claude/review-config.yml
	done
}

_stage_config() {
	git add .claude/review-config.yml || return 1
}

@test "valid config with required agent shape passes silently" {
	_write_valid_config
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	# Success is silent — output would mean an unreported validation arm.
	[ -z "$output" ]
}

@test "missing top-level agents fails" {
	printf '%s\n' 'approach: keep it small' >.claude/review-config.yml
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -ne 0 ] || return 1
	[[ $output == *'missing required top-level: agents'* ]]
}

@test "optional approach as a non-empty string is accepted (#2651)" {
	_write_valid_config
	printf '%s\n' 'approach: prefer consuming upstream over rebuilding' >>.claude/review-config.yml
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'approach:'* ]]
}

@test "approach absent still passes silently (non-required, #2651)" {
	_write_valid_config
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "approach present as NULL is rejected, not skipped (#2651)" {
	# `yq -e '.approach'` is falsy for a present null — has() must gate.
	_write_valid_config
	printf '%s\n' 'approach: null' >>.claude/review-config.yml
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -ne 0 ] || return 1
	[[ $output == *'approach: must be a non-empty string'* ]]
}

@test "approach present as FALSE is rejected, not skipped (#2651)" {
	_write_valid_config
	printf '%s\n' 'approach: false' >>.claude/review-config.yml
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -ne 0 ] || return 1
	[[ $output == *'approach: must be a non-empty string'* ]]
}

@test "approach with a wrong-typed value fails (#2651)" {
	_write_valid_config
	printf '%s\n' 'approach:' '  - not' '  - a-string' >>.claude/review-config.yml
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -ne 0 ] || return 1
	[[ $output == *'approach: must be a non-empty string'* ]]
}

@test "approach as an EMPTY string fails (#2651)" {
	_write_valid_config
	printf '%s\n' 'approach: ""' >>.claude/review-config.yml
	_stage_config || return 1
	run bash "$HOOK"
	[ "$status" -ne 0 ] || return 1
	[[ $output == *'approach: must be a non-empty string'* ]]
}
