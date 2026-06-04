#!/usr/bin/env bats
# covers: _lib/phase1-agent-prompt.sh
# shellcheck disable=SC2030,SC2031  # bats @test bodies run in subshells; per-test cd is intentional + isolated
#
# #2240 canonical-review-exclusion, phase1 integration: phase1_agent_prompt
# narrows the emitted prompt to consumer-authored files in a CONSUMER, and is a
# no-op (full diff, no stray blank line) in the PLUGIN. Synthetic <plugin>/_lib
# holds phase1-agent-prompt.sh + canonical-review-exclude.sh + canonical-
# consumer-skip.sh so the lib's BASH_SOURCE-relative sourcing + plugin-root
# resolution land on the fixture, not the real repo.

setup() {
	P1_SRC="${BATS_TEST_DIRNAME}/../../../_lib/phase1-agent-prompt.sh"
	REVEX_SRC="${BATS_TEST_DIRNAME}/../../../_lib/canonical-review-exclude.sh"
	SKIP_SRC="${BATS_TEST_DIRNAME}/../../../_lib/canonical-consumer-skip.sh"
	[ -f "$P1_SRC" ] && [ -f "$REVEX_SRC" ] && [ -f "$SKIP_SRC" ]
	TEST_TMP=$(mktemp -d -t p1cs.XXXXXX) || return 1
	PLUGIN="$TEST_TMP/plugin"
	REPO="$TEST_TMP/repo"
	mkdir -p "$PLUGIN/_lib" "$PLUGIN/hooks" "$PLUGIN/.claude-plugin" "$REPO/.claude/hooks"
	cp "$P1_SRC" "$PLUGIN/_lib/phase1-agent-prompt.sh"
	cp "$REVEX_SRC" "$PLUGIN/_lib/canonical-review-exclude.sh"
	cp "$SKIP_SRC" "$PLUGIN/_lib/canonical-consumer-skip.sh"
	LIB="$PLUGIN/_lib/phase1-agent-prompt.sh"
	printf '{"name":"x"}\n' >"$PLUGIN/.claude-plugin/plugin.json"
	printf 'canonical body\n' >"$PLUGIN/hooks/foo.sh"
	(cd "$PLUGIN" && git init -q && git config user.email t@t && git config user.name t && git add -A && git commit -qm x && git branch -M main) || return 1
	(cd "$REPO" && git init -q && git config user.email t@t && git config user.name t) || return 1
}

teardown() {
	[ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && [[ $TEST_TMP == */p1cs.* ]] && rm -rf "$TEST_TMP"
	return 0
}

@test "plugin: no CANONICAL-EXCLUSION clause + no stray double-blank line" {
	cd "$PLUGIN"
	git checkout -q -b feat
	printf 'new body\n' >"hooks/bar.sh"
	git add -A && git commit -qm add-bar
	# shellcheck source=../../../_lib/phase1-agent-prompt.sh
	. "$LIB"
	run phase1_agent_prompt code-reviewer "$PLUGIN" abc1234 1
	[ "$status" -eq 0 ]
	[[ $output != *"CANONICAL-EXCLUSION"* ]]
	# #3 fix: scope_clause empty must NOT leave consecutive blank lines anywhere.
	consec=$(printf '%s\n' "$output" | awk 'prev==""&&$0==""{c++} {prev=$0} END{print c+0}')
	[ "$consec" -eq 0 ]
}

@test "consumer: emits CANONICAL-EXCLUSION listing consumer-authored, not the mirror" {
	cd "$REPO"
	printf 'readme\n' >README.md
	git add -A && git commit -qm base
	git branch -M main
	git checkout -q -b feat
	# Byte-identical canonical mirror → excluded from the review scope.
	cp "$PLUGIN/hooks/foo.sh" ".claude/hooks/foo.sh"
	# Consumer-authored change (the pin) → in scope.
	printf 'repos: []\n' >".pre-commit-config.yaml"
	git add -A && git commit -qm changes
	# shellcheck source=../../../_lib/phase1-agent-prompt.sh
	. "$LIB"
	run phase1_agent_prompt code-reviewer "$REPO" abc1234 1
	[ "$status" -eq 0 ]
	[[ $output == *"CANONICAL-EXCLUSION: review ONLY"* ]]
	[[ $output == *"  - .pre-commit-config.yaml"* ]]
	[[ $output != *".claude/hooks/foo.sh"* ]]
}
