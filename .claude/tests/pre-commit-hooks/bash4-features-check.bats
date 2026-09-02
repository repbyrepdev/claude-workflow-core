#!/usr/bin/env bats
# covers: pre-commit-hooks/bash4-features-check.sh
#
# #2645 r1 security-review keystone: the commit gate must scan the STAGED
# BLOB (:0:path), never the worktree file. The worktree can differ from
# what actually commits — stage a bad version then restore a clean worktree
# (malicious), or fix-after-block and forget `git add` (careless), or
# delete the worktree copy of a staged file. The pre-fix code cat'd the
# worktree and passed all three; these tests hold that door shut.

setup() {
	HOOK="${BATS_TEST_DIRNAME}/../../../pre-commit-hooks/bash4-features-check.sh"
	[ -f "$HOOK" ]
	SANDBOX=$(mktemp -d -t b4gate.XXXXXX) || return 1
	(cd "$SANDBOX" && git init -q)
}

teardown() {
	cd /tmp || return 0
	if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && [[ $SANDBOX == */b4gate.* ]]; then
		rm -rf "$SANDBOX"
	fi
}

@test "staged bash-4 blob BLOCKS even when the worktree copy was cleaned (#2645)" {
	cd "$SANDBOX"
	printf '#!/bin/bash\nset -u\ndeclare -A m\n' >bad.sh
	git add bad.sh
	printf '#!/bin/bash\nset -u\necho clean\n' >bad.sh # worktree now clean; NOT re-staged
	run bash "$HOOK"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"declare -A"* ]]
}

@test "staged bash-4 blob BLOCKS even when the worktree copy was deleted (#2645)" {
	cd "$SANDBOX"
	printf '#!/bin/bash\nset -u\nmapfile -d "" x\n' >gone.sh
	git add gone.sh
	rm -f gone.sh # staged blob remains; old [ -f ] skip silently passed this
	run bash "$HOOK"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *"mapfile -d"* ]]
}

@test "clean staged blob passes (control)" {
	cd "$SANDBOX"
	printf '#!/bin/bash\nset -u\necho ok\n' >ok.sh
	git add ok.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ]
}
