#!/usr/bin/env bats
# covers: pre-commit-hooks/lib-consumer-symmetry.sh
#
# #2644/#2653 — sandbox replay of the a788b2f regression shape: a change
# touching a symbol owned by a shared _lib lands on one of two consumers.
# Layer 1 (staging symmetry) must fire NAMING the unstaged sibling; layer 2
# (guard-token map) must flag a consumer missing a required token. Warn-only
# rollout: findings exit 0; ENFORCE=1 exits 1 for ENFORCEABLE findings only
# (staging fan-out <=3 + token); tool failure exits 2.

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
		chmod -R u+w "$FIX" 2>/dev/null || true
		rm -rf "$FIX"
	fi
}

_commit_all() {
	git add -A || return 1
	git -c user.email=t@t -c user.name=t commit -qm "${1:-seed}" || return 1
}

# Seed a lib with one owned var + one owned function, and two consumers
# that both name the lib's basename and use the owned var. COMMITS.
_seed_mylib() {
	mkdir -p _lib || return 1
	printf '%s\n' '#!/bin/bash' 'MY_MAX=50' 'my_func() {' ' echo hi' '}' >_lib/mylib.sh
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >alpha.sh
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >beta.sh
	_commit_all seed || return 1
}

# The canonical one-sided owned-symbol edit: touch alpha, stage only alpha.
_stage_alpha_edit() {
	printf '%s\n' 'echo "cap: $MY_MAX"' >>alpha.sh
	git add alpha.sh || return 1
}

# _write_trailers_consumer <path> <n-tokens 2|3> — a consumer of the mapped
# _lib/issue-trailers.sh carrying the first n required guard tokens (n=2
# drops the `command -v` probe but keeps the MAX check, so owned-symbol
# evidence still holds while a token is missing). Single source for the
# token literals on the test side.
_write_trailers_consumer() {
	printf '%s\n' '#!/bin/bash' '# consumes _lib/issue-trailers.sh' \
		'. "$_it_lib"' \
		'[[ ${ISSUE_TRAILER_MAX:-} =~ ^[0-9]+$ ]]' >"$1"
	if [ "$2" = "3" ]; then
		printf '%s\n' 'command -v issue_trailers_for_pr' >>"$1"
	fi
}

# Seed the mapped-lib world: the lib + a complete consumer (user-a) + a
# user-b whose token count is the parameter. COMMITS (parity with
# _seed_mylib — every test stages its own delta explicitly).
_seed_trailers() {
	mkdir -p _lib || return 1
	printf '%s\n' '#!/bin/bash' 'ISSUE_TRAILER_MAX=50' 'issue_trailers_for_pr() {' ' :' '}' >_lib/issue-trailers.sh
	_write_trailers_consumer user-a.sh 3
	_write_trailers_consumer user-b.sh "${1:-3}"
	_commit_all seed || return 1
}

# Stage a comment-only tweak to a file (triggers layer-2 scoping without
# touching owned symbols in the hunk).
_stage_tweak() {
	printf '%s\n' '# tweak' >>"$1"
	git add "$1" || return 1
}

@test "one-sided edit touching an owned symbol fires naming the unstaged sibling" {
	_seed_mylib
	_stage_alpha_edit
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
	_stage_tweak alpha.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "ENFORCE=1 turns a low-fan-out staging finding into exit 1" {
	_seed_mylib
	_stage_alpha_edit
	run env LIB_CONSUMER_SYMMETRY_ENFORCE=1 bash "$HOOK"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *'beta.sh'* ]]
}

@test "consumer missing a guard token is flagged when only that consumer is staged" {
	_seed_trailers 2
	_stage_tweak user-b.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'user-b.sh is missing required guard token'* ]] || return 1
	[[ $output == *'command -v issue_trailers_for_pr'* ]] || return 1
	grep -q '"layer":"token"' .claude/logs/lib-consumer-symmetry.jsonl
}

@test "token scan also runs when only the LIBRARY is staged" {
	_seed_trailers 2
	_stage_tweak _lib/issue-trailers.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'user-b.sh is missing required guard token'* ]]
}

@test "consumers carrying every required token stay quiet" {
	_seed_trailers 3
	_stage_tweak user-b.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'missing required guard token'* ]] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "token layer stays scoped: mapped surface untouched means no token scan" {
	_seed_trailers 2
	printf '%s\n' '#!/bin/bash' 'echo standalone' >other.sh
	git add other.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'missing required guard token'* ]]
}

@test "ENFORCE=1 turns a token finding into exit 1" {
	_seed_trailers 2
	_stage_tweak user-b.sh
	run env LIB_CONSUMER_SYMMETRY_ENFORCE=1 bash "$HOOK"
	[ "$status" -eq 1 ] || return 1
	[[ $output == *'missing required guard token'* ]]
}

@test "prose-only mention without owned-symbol evidence is NOT token-checked" {
	_seed_trailers 3
	printf '%s\n' '#!/bin/bash' '# see _lib/issue-trailers.sh for details' 'echo prose' >prose.sh
	git add prose.sh || return 1
	_stage_tweak user-b.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'prose.sh'* ]]
}

@test "skip env records an audit row WITH the reason and exits 0" {
	_seed_mylib
	_stage_alpha_edit
	run env LIB_CONSUMER_SYMMETRY_SKIP=1 LIB_CONSUMER_SYMMETRY_SKIP_REASON="bats fixture" bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'SKIPPED'* ]] || return 1
	grep -q 'lib-consumer-symmetry-skip' .claude/logs/pipeline-skip.jsonl || return 1
	grep -q '"reason":"bats fixture"' .claude/logs/pipeline-skip.jsonl
}

@test "not a git repo exits 2" {
	mkdir -p "$FIX/norepo" || return 1
	cd "$FIX/norepo" || return 1
	run env GIT_CEILING_DIRECTORIES="$FIX" bash "$HOOK"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'not in a git repo'* ]]
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
	_stage_alpha_edit
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'high fan-out'* ]] || return 1
	[[ $output == *'beta.sh'* ]] || return 1
	[[ $output == *'gamma.sh'* ]] || return 1
	[[ $output == *'delta.sh'* ]] || return 1
	grep -q '"fanout":"4"' .claude/logs/lib-consumer-symmetry.jsonl
}

@test "high-fan-out finding stays advisory even under ENFORCE=1" {
	_seed_mylib
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >gamma.sh
	printf '%s\n' '#!/bin/bash' '# sources _lib/mylib.sh' 'echo "$MY_MAX"' >delta.sh
	_commit_all more-consumers || return 1
	_stage_alpha_edit
	run env LIB_CONSUMER_SYMMETRY_ENFORCE=1 bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'advisory even under ENFORCE'* ]]
}

@test "function-name half of the owned-symbol grammar fires (my_func)" {
	_seed_mylib
	printf '%s\n' 'my_func extra' >>alpha.sh
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"touches 'my_func'"* ]]
}

@test "word-boundary match: a superstring of an owned symbol stays quiet" {
	_seed_mylib
	printf '%s\n' 'echo "$MY_MAXIMUS"' >>alpha.sh
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "basename prefilter: a non-consumer using the identifier stays quiet" {
	_seed_mylib
	printf '%s\n' '#!/bin/bash' 'MY_MAX=99' 'echo "$MY_MAX"' >standalone.sh
	git add standalone.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[ ! -f .claude/logs/lib-consumer-symmetry.jsonl ]
}

@test "committed self-copy and tests-dir consumer are excluded: sibling list is exactly beta" {
	_seed_mylib
	mkdir -p pre-commit-hooks .claude/tests || return 1
	printf '%s\n' '#!/bin/bash' '# names _lib/mylib.sh and MY_MAX and my_func by necessity' \
		'echo "MY_MAX my_func mylib.sh"' >pre-commit-hooks/lib-consumer-symmetry.sh
	printf '%s\n' '#!/bin/bash' '# fixture naming _lib/mylib.sh' 'echo "$MY_MAX"' >.claude/tests/fake.sh
	git -c core.excludesfile=/dev/null add -f pre-commit-hooks/lib-consumer-symmetry.sh .claude/tests/fake.sh || return 1
	_commit_all excluded-copies || return 1
	_stage_alpha_edit
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *'NOT staged: beta.sh ('* ]] || return 1
	[[ $output != *'pre-commit-hooks/lib-consumer-symmetry.sh'* ]] || return 1
	[[ $output != *'.claude/tests/fake.sh'* ]]
}

@test "unwritable ledger dir fails closed on append (exit 2), not a silent warn" {
	_seed_mylib
	mkdir -p .claude/logs || return 1
	chmod 555 .claude/logs || return 1
	_stage_alpha_edit
	run bash "$HOOK"
	chmod 755 .claude/logs || true
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'append FAILED'* ]]
}

@test "ledger path blocked by a file fails closed at mkdir (exit 2)" {
	_seed_mylib
	mkdir -p .claude || return 1
	: >.claude/logs || return 1
	_stage_alpha_edit
	run bash "$HOOK"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'cannot create ledger dir'* ]]
}

@test "deleted content line starting with dashes is still scanned (header ambiguity)" {
	# With default +/- indicators, deleting a line whose text begins `--`
	# renders as `---…` and the header filter ate it — the removal of an
	# owned-symbol use went unscanned (phase2 CR r2).
	_seed_mylib
	printf '%s\n' 'pre' '-- "$MY_MAX" --' 'end' >>alpha.sh
	_commit_all dashes || return 1
	grep -vF -- '-- "$MY_MAX" --' alpha.sh >alpha.tmp || return 1
	mv alpha.tmp alpha.sh || return 1
	git add alpha.sh || return 1
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output == *"touches 'MY_MAX'"* ]] || return 1
	[[ $output == *'beta.sh'* ]]
}

@test "map drift fails closed: mapped lib gone but referenced in CODE exits 2" {
	_seed_mylib
	printf '%s\n' '#!/bin/bash' 'echo "loading _lib/issue-trailers.sh"' >lingering.sh
	_commit_all lingering || return 1
	_stage_alpha_edit
	run bash "$HOOK"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'removed/renamed library'* ]] || return 1
	[[ $output == *'lingering.sh'* ]]
}

@test "map drift still fires when the removed mapped lib was the LAST _lib file" {
	# No tracked _lib at all: the probe is driven by the mapped entry's
	# own evidence, not by whether unrelated libraries exist.
	printf '%s\n' '#!/bin/bash' 'echo "loading _lib/issue-trailers.sh"' >lingering.sh
	_commit_all seed || return 1
	_stage_tweak lingering.sh
	run bash "$HOOK"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'removed/renamed library'* ]]
}

@test "map drift ignores COMMENT-only mentions of the removed lib" {
	_seed_mylib
	printf '%s\n' '#!/bin/bash' '# migrated off _lib/issue-trailers.sh, ref lingers' 'echo ok' >lingering.sh
	_commit_all lingering || return 1
	_stage_alpha_edit
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'removed/renamed'* ]]
}

@test "unmapped _lib layout with NO reference to the mapped lib stays a no-op" {
	_seed_mylib
	_stage_tweak alpha.sh
	run bash "$HOOK"
	[ "$status" -eq 0 ] || return 1
	[[ $output != *'removed/renamed'* ]]
}

@test "skip is REFUSED (exit 2) when pipeline-skip lib is unreachable" {
	_seed_mylib
	mkdir -p "$FIX/lonely" || return 1
	cp "$HOOK" "$FIX/lonely/hook.sh" || return 1
	_stage_alpha_edit
	run env LIB_CONSUMER_SYMMETRY_SKIP=1 bash "$FIX/lonely/hook.sh"
	[ "$status" -eq 2 ] || return 1
	[[ $output == *'cannot record the skip'* ]]
}
