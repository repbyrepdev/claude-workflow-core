#!/usr/bin/env bats
# covers: hooks/phase0.5-dedupe-against-audit.sh
#
# #817 filter, first behavioral coverage (added with the #2652 change):
# findings whose description a prior fix/rejection record's finding_text
# contains are suppressed; kind=baseline corroboration rows must NEVER
# suppress (their text is "baseline_rc=N retest_cmd=..." and a prefilter
# finding mentioning the same command is a genuinely new finding).

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../hooks/phase0.5-dedupe-against-audit.sh"
	[ -f "$HOOK" ]
	FIX=$(mktemp -d -t p05dedupe.XXXXXX) || return 1
	cd "$FIX" || return 1
	git init -q . || return 1
	git -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed || return 1
	mkdir -p .claude/audit || return 1
}

teardown() {
	cd /tmp || return 0
	if [ -n "${FIX:-}" ] && [ -d "$FIX" ] && [[ $FIX == */p05dedupe.* ]]; then
		rm -rf "$FIX"
	fi
}

@test "no audit log passes findings through unchanged" {
	run bash -c 'printf %s "$1" | bash "$2"' _ \
		'[{"description":"a real finding"}]' "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'a real finding'* ]]
}

@test "a prior fix record's finding_text suppresses the matching finding" {
	printf '%s\n' '{"kind":"fix","finding_text":"r1 fix applied: the widget frobs twice"}' \
		>.claude/audit/prove-yourself.jsonl
	run bash -c 'printf %s "$1" | bash "$2"' _ \
		'[{"description":"the widget frobs twice"},{"description":"a fresh finding"}]' "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'widget frobs'* ]] || return 1
	[[ $output == *'a fresh finding'* ]]
}

@test "a kind=baseline corroboration row never suppresses (#2652)" {
	printf '%s\n' '{"kind":"baseline","finding_text":"baseline_rc=1 retest_cmd=bash scripts/test.sh suite"}' \
		>.claude/audit/prove-yourself.jsonl
	run bash -c 'printf %s "$1" | bash "$2"' _ \
		'[{"description":"bash scripts/test.sh suite"}]' "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'scripts/test.sh suite'* ]]
}
