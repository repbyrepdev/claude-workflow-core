#!/usr/bin/env bats
# covers: pre-commit-hooks/lib-consumer-symmetry.sh
#
# #2644/#2653 — sandbox replay of the a788b2f regression shape: a change
# touching a symbol owned by a shared _lib lands on one of two consumers.
# Layer 1 (staging symmetry) must fire NAMING the unstaged sibling; layer 2
# (guard-token map) must flag a consumer missing a required token. Warn-only
# cycle: findings exit 0; ENFORCE=1 exits 1; tool failure exits 2.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/lib-consumer-symmetry.sh"
	[ -f "$HOOK" ]
	FIX=$(mktemp -d -t lcs-fix.XXXXXX) || return 1
	cd "$FIX" || return 1
	git init -q . || return 1
}

teardown() {
	cd /tmp || return 0
	if [ -n "${FIX:-}" ] && [ -d "$FIX" ] && [[ $FIX == */lcs-fix.* ]]; then
		rm -rf "$FIX"
	fi
}

_commit_all() {
	git add -A || return 1
	git -c user.email=t@t -c user.name=t commit -qm "${1:-seed}" || return 1
}

# Seed a lib with one owned var + one owned function, and two consumers
# that both name the lib's basename and use the owned var.
_seed_mylib() {
	mkdir -p _lib || return 1
	printf '%s\n' '#!/bin/bash' 'MY_MAX=50' 'my_func() {' ' echo hi' '}' >_lib/mylib.sh
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >alpha.sh
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >beta.sh
	_commit_all seed || return 1
}

@test "one-sided edit touching an owned symbol fires naming the unstaged sibling" {
	_seed_mylib
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'beta.sh'* ]] || return 1
	[[ $output == *'MY_MAX'* ]] || return 1
	[[ $output == *'WARN-ONLY'* ]] || return 1
	grep -q '"layer":"staging"' .claude/logs/lib-consumer-symmetry.jsonl
}

@test "same edit with BOTH consumers staged stays quiet" {
	_seed_mylib
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	printf '%s\n' 'echo "cap: $MY_MAX"' >>beta.sh
	git add alpha.sh beta.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'sibling consumer'* ]] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "one-sided edit NOT touching an owned symbol stays quiet" {
	_seed_mylib
	printf '%s\n' 'echo unrelated' >>alpha.sh
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "ENFORCE=1 turns the staging finding into exit 1" {
	_seed_mylib
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
	run env LIB_CONSUMER_SYMMETRY_ENFORCE=1 bash "$HOOK"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *'beta.sh'* ]]
}

# Token-map fixtures: consumers of the MAPPED lib path _lib/issue-trailers.sh.
# user-a carries all three required tokens; user-b's token set is a parameter.
_seed_trailers() {
	mkdir -p _lib || return 1
	printf '%s\n' '#!/bin/bash' 'ISSUE_TRAILER_MAX=50' 'issue_trailers_for_pr() {' ' :' '}' >_lib/issue-trailers.sh
	printf '%s\n' '#!/bin/bash' '# consumes _lib/issue-trailers.sh' \
		'. "$_it_lib"' \
		'[[ ${ISSUE_TRAILER_MAX:-} =~ ^[0-9]+$ ]]' \
		'command -v issue_trailers_for_pr' >user-a.sh
}

@test "consumer missing a required guard token is flagged with the token text" {
	_seed_trailers
	printf '%s\n' '#!/bin/bash' '# consumes _lib/issue-trailers.sh' \
		'. "$_it_lib"' \
		'[[ ${ISSUE_TRAILER_MAX:-} =~ ^[0-9]+$ ]]' >user-b.sh
	git add -A || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'user-b.sh is missing required guard token'* ]] || return 1
	[[ $output == *'command -v issue_trailers_for_pr'* ]] || return 1
	grep -q '"layer":"token"' .claude/logs/lib-consumer-symmetry.jsonl
}

@test "consumers carrying every required token stay quiet" {
	_seed_trailers
	printf '%s\n' '#!/bin/bash' '# consumes _lib/issue-trailers.sh' \
		'. "$_it_lib"' \
		'[[ ${ISSUE_TRAILER_MAX:-} =~ ^[0-9]+$ ]]' \
		'command -v issue_trailers_for_pr' >user-b.sh
	git add -A || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'missing required guard token'* ]] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "token layer stays scoped: mapped surface untouched means no token scan" {
	_seed_trailers
	printf '%s\n' '#!/bin/bash' '# consumes _lib/issue-trailers.sh' >user-b.sh
	_commit_all seed || return 1
	printf '%s\n' '#!/bin/bash' 'echo standalone' >other.sh
	git add other.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'missing required guard token'* ]]
}

@test "skip env records an audit row and exits 0" {
	_seed_mylib
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
	run env LIB_CONSUMER_SYMMETRY_SKIP=1 LIB_CONSUMER_SYMMETRY_SKIP_REASON="bats fixture" bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'SKIPPED'* ]] || return 1
	grep -q 'lib-consumer-symmetry-skip' .claude/logs/pipeline-skip.jsonl
}

@test "not a git repo exits 2" {
	mkdir -p "$FIX/norepo" || return 1
	cd "$FIX/norepo" || return 1
	run env GIT_CEILING_DIRECTORIES="$FIX" bash "$HOOK"
	[ "$status" -eq 2 ]
}

@test "nothing staged exits 0 quietly" {
	_seed_mylib
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "fan-out above 3 fires with the high-fan-out band note and every unstaged sibling" {
	_seed_mylib
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >gamma.sh
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >delta.sh
	_commit_all more-consumers || return 1
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'high fan-out'* ]] || return 1
	[[ $output == *'beta.sh'* ]] || return 1
	[[ $output == *'gamma.sh'* ]] || return 1
	[[ $output == *'delta.sh'* ]] || return 1
	grep -q '"fanout":"4"' .claude/logs/lib-consumer-symmetry.jsonl
}

@test "ENFORCE=1 turns a token finding into exit 1" {
	_seed_trailers
	printf '%s\n' '#!/bin/bash' '# consumes _lib/issue-trailers.sh' \
		'. "$_it_lib"' >user-b.sh
	git add -A || return 1
	run env LIB_CONSUMER_SYMMETRY_ENFORCE=1 bash "$HOOK"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *'missing required guard token'* ]]
}

@test "skip is REFUSED (exit 2) when pipeline-skip lib is unreachable" {
	# Copy the hook somewhere with no ../_lib sibling: the skip cannot be
	# recorded, so it must not happen.
	_seed_mylib
	mkdir -p "$FIX/lonely" || return 1
	cp "$HOOK" "$FIX/lonely/hook.sh" || return 1
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
	run env LIB_CONSUMER_SYMMETRY_SKIP=1 bash "$FIX/lonely/hook.sh"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'cannot record the skip'* ]]
}

@test "unwritable ledger path fails closed (exit 2) instead of warning unrecorded" {
	_seed_mylib
	mkdir -p .claude || return 1
	: >.claude/logs || return 1
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'ledger'* ]]
}

@test "the gate's own path is excluded from consumer discovery (no self-fire)" {
	_seed_mylib
	mkdir -p pre-commit-hooks || return 1
	printf '%s\n' '#!/bin/bash' '# names _lib/mylib.sh and MY_MAX by necessity' \
		'echo "MY_MAX my_func mylib.sh"' >pre-commit-hooks/lib-consumer-symmetry.sh
	git add pre-commit-hooks/lib-consumer-symmetry.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'sibling consumer'* ]] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}
