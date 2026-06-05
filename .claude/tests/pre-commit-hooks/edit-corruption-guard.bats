#!/usr/bin/env bats
# covers: pre-commit-hooks/edit-corruption-guard.sh
#
# #2254: the two guard SOURCES (this scanner + hooks/edit-corruption-pretooluse-
# guard.sh) legitimately contain the corruption-signature literal as their own
# detection pattern. They must be EXEMPT by basename so a consumer staging the
# canonical .claude/hooks/ mirror — or the plugin re-committing either guard —
# is not false-positive-blocked, while EVERY other file containing the literal
# is still blocked.
#
# NB: the fixtures construct the literal at RUNTIME via printf hex (\x22 = ")
# so this .bats source never contains the raw 4-char sequence — which the
# PreToolUse guard + the API content-filter both refuse to write.

setup() {
	GUARD="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/edit-corruption-guard.sh"
	[ -x "$GUARD" ]
	command -v git >/dev/null
	REPO=$(mktemp -d -t ecguard.XXXXXX) || return 1
	cd "$REPO" || return 1
	git init -q
	git config user.email t@example.com
	git config user.name tester
	# The corruption-signature literal, built at runtime (see header note).
	LIT=$(printf '>>\x22\x22')
}

teardown() {
	cd / || return 0
	[ -n "${REPO:-}" ] && [[ $REPO == */ecguard.* ]] && rm -rf "$REPO"
	return 0
}

@test "#2254: consumer-mirror .claude/hooks/edit-corruption-pretooluse-guard.sh is EXEMPT" {
	mkdir -p .claude/hooks
	printf 'grep -q %s\n' "$LIT" >.claude/hooks/edit-corruption-pretooluse-guard.sh
	git add .claude/hooks/edit-corruption-pretooluse-guard.sh
	run bash "$GUARD"
	[ "$status" -eq 0 ]
}

@test "#2254: plugin pre-commit-hooks/edit-corruption-guard.sh source is EXEMPT" {
	mkdir -p pre-commit-hooks
	printf 'grep -q %s\n' "$LIT" >pre-commit-hooks/edit-corruption-guard.sh
	git add pre-commit-hooks/edit-corruption-guard.sh
	run bash "$GUARD"
	[ "$status" -eq 0 ]
}

@test "#2254: plugin hooks/edit-corruption-pretooluse-guard.sh source is EXEMPT" {
	mkdir -p hooks
	printf 'grep -q %s\n' "$LIT" >hooks/edit-corruption-pretooluse-guard.sh
	git add hooks/edit-corruption-pretooluse-guard.sh
	run bash "$GUARD"
	[ "$status" -eq 0 ]
}

@test "#2254: a NON-guard .sh containing the literal is STILL BLOCKED" {
	printf 'echo %s\n' "$LIT" >somehook.sh
	git add somehook.sh
	run bash "$GUARD"
	[ "$status" -eq 1 ]
	[[ $output == *"corrupted"* ]]
}

@test "#2254: a non-guard file NOT containing the literal passes" {
	printf 'echo clean\n' >clean.sh
	git add clean.sh
	run bash "$GUARD"
	[ "$status" -eq 0 ]
}

@test "#2254: exemption is by basename — a look-alike name is still scanned/blocked" {
	# Not one of the two exempt basenames → must still be scanned + blocked.
	printf 'echo %s\n' "$LIT" >edit-corruption-pretooluse-guard-helper.sh
	git add edit-corruption-pretooluse-guard-helper.sh
	run bash "$GUARD"
	[ "$status" -eq 1 ]
}
