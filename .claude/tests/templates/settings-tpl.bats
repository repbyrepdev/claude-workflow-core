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
	[[ $output == *"register-hook.sh"* ]]
	[[ $output == *"all-auto-register"* ]]
}

@test "template includes <VERSION> placeholder in every plugin-managed hook path" {
	# Every .command in the template should reference the placeholder so
	# render-time substitution is total (no half-rendered settings).
	run jq -r '.hooks | .. | objects | select(.command) | .command' "$TPL"
	[ "$status" -eq 0 ]
	# Every line must contain <VERSION>
	while IFS= read -r cmd; do
		[[ $cmd == *"<VERSION>"* ]]
	done <<<"$output"
}

@test "template has top-level .hooks for all 6 supported events" {
	for event in PreToolUse PostToolUse SessionStart UserPromptSubmit PreCompact Stop; do
		run jq -e --arg e "$event" '.hooks | has($e)' "$TPL"
		[ "$status" -eq 0 ]
		[ "$output" = "true" ]
	done
}
