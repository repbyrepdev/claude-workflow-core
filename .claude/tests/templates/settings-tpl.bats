#!/usr/bin/env bats
# covers: templates/settings.json.tpl

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/../../.." 2>&1 && pwd) || {
		echo "FATAL: cd failed: $REPO_ROOT" >&2
		return 1
	}
	TPL="${REPO_ROOT}/templates/settings.json.tpl"
}

@test "templates/settings.json.tpl exists" {
	[ -f "$TPL" ]
}

@test "templates/settings.json.tpl is valid JSON" {
	run jq empty "$TPL"
	[ "$status" -eq 0 ]
}

@test "template declares <VERSION> placeholder under _template.version_placeholder" {
	run jq -r '._template.version_placeholder' "$TPL"
	[ "$status" -eq 0 ]
	[ "$output" = "<VERSION>" ]
}

@test "template names register-hook.sh --all-auto-register as the renderer (SSOT)" {
	run jq -r '._template.renderer' "$TPL"
	[ "$status" -eq 0 ]
	[[ $output == *"register-hook.sh"* ]] || return 1
	[[ $output == *"all-auto-register"* ]]
}

@test "template includes <VERSION> placeholder in every plugin-managed hook path" {
	# Every .command in the template should reference the placeholder so
	# render-time substitution is total (no half-rendered settings).
	run jq -r '.hooks | .. | objects | select(.command) | .command' "$TPL"
	[ "$status" -eq 0 ]
	# r2 silent-failure-hunter LOW: assert non-empty BEFORE per-line check
	# so an empty template fails LOUDLY (was passing vacuously via
	# single-empty-line while-read iteration).
	cmd_count=$(printf '%s\n' "$output" | grep -c '^/\|<VERSION>' || true)
	[ "$cmd_count" -ge 6 ]
	while IFS= read -r cmd; do
		[ -n "$cmd" ] || continue
		[[ $cmd == *"<VERSION>"* ]] || return 1
	done <<<"$output"
}

@test "template has top-level .hooks for all 6 supported events" {
	for event in PreToolUse PostToolUse SessionStart UserPromptSubmit PreCompact Stop; do
		run jq -e --arg e "$event" '.hooks | has($e)' "$TPL"
		[ "$status" -eq 0 ]
		[ "$output" = "true" ]
	done
}
