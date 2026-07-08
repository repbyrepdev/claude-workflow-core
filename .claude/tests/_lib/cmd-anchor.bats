#!/usr/bin/env bats
# covers: _lib/cmd-anchor.sh
#
# #2396: first dedicated suite for the command-anchor SSOT. The lib had NO
# direct coverage — its behavior was only asserted transitively through
# skill-bypass-guard.bats / pre-merge-cr-comments-gate.bats. This suite
# pins the exported regex fragments + helpers, most importantly the new
# CMD_HARDENED_PREFIX wrapper/grouping/env grammar: gate hooks previously
# failed OPEN on `{ verb; }` / `( verb )` / `command|builtin|sudo|env`
# prefixed invocations because the anchor accepted only the bare form (plus
# env assignments via the hooks' inline ENV_PREFIX).

setup() {
	LIB="${BATS_TEST_DIRNAME}/../../../_lib/cmd-anchor.sh"
	[ -f "$LIB" ]
	# shellcheck source=../../../_lib/cmd-anchor.sh
	source "$LIB"
	GPM='gh[[:space:]]+pr[[:space:]]+merge'
	GC='git[[:space:]]+commit'
}

@test "exports are non-empty (anchor, end, hardened prefix)" {
	[ -n "$CMD_SEGMENT_ANCHOR" ]
	[ -n "$CMD_SEGMENT_END" ]
	[ -n "$CMD_HARDENED_PREFIX" ]
}

@test "match_cmd_at_anchor: bare verb at command start hits" {
	match_cmd_at_anchor "$GC" "git commit -m x"
}

@test "match_cmd_at_anchor: verb after separator hits; quoted mid-string misses" {
	match_cmd_at_anchor "$GPM" "true && gh pr merge 5"
	run match_cmd_at_anchor "$GPM" 'git commit -m "mention gh pr merge here"'
	[ "$status" -ne 0 ]
}

@test "match_cmd_at_anchor: empty pattern returns 1 (guarded)" {
	run match_cmd_at_anchor "" "git commit"
	[ "$status" -eq 1 ]
}

@test "hardened: brace group and subshell prefixes hit (#2396)" {
	match_cmd_at_anchor_hardened "$GPM" "{ gh pr merge 5; }"
	match_cmd_at_anchor_hardened "$GPM" "( gh pr merge 5 )"
	match_cmd_at_anchor_hardened "$GPM" "(gh pr merge 5)"
}

@test "hardened: command/builtin/sudo/env wrappers hit (#2396)" {
	match_cmd_at_anchor_hardened "$GPM" "command gh pr merge 5"
	match_cmd_at_anchor_hardened "$GPM" "builtin gh pr merge 5"
	match_cmd_at_anchor_hardened "$GPM" "sudo -E gh pr merge 5"
	match_cmd_at_anchor_hardened "$GPM" "env X=1 gh pr merge 5"
}

@test "hardened: env assignments with quoted values hit (#2396)" {
	match_cmd_at_anchor_hardened "$GC" 'FOO="a b" git commit -m x'
	match_cmd_at_anchor_hardened "$GC" "X='a; b' git commit"
}

@test "hardened: EMPTY-value env assignment is consumed (FOO= verb; r2 silent-failure)" {
	# `FOO= git commit` is valid bash; a required-value alternation let it slip
	# both gates. The #858 leading-quote protection must survive the optional
	# value: a quoted string containing a verb name still misses.
	match_cmd_at_anchor_hardened "$GC" "FOO= git commit -m x"
	run match_cmd_at_anchor_hardened "bats" 'CMD="Updated bats test 6"'
	[ "$status" -ne 0 ]
}

@test "hardened: stacked prefixes after a separator hit (#2396)" {
	match_cmd_at_anchor_hardened "$GPM" "true && { sudo env A=1 gh pr merge 7; }"
}

@test "hardened: mid-args / quoted / lookalike verbs still miss (#2396)" {
	run match_cmd_at_anchor_hardened "$GPM" "echo gh pr merge"
	[ "$status" -ne 0 ]
	run match_cmd_at_anchor_hardened "$GPM" 'git commit -m "mention gh pr merge here"'
	[ "$status" -ne 0 ]
	run match_cmd_at_anchor_hardened "$GC" "foosudo git-commit-ish"
	[ "$status" -ne 0 ]
	run match_cmd_at_anchor_hardened "$GPM" 'grep "(gh pr merge)" file'
	[ "$status" -ne 0 ]
}

@test "hardened: documented bound — sudo flag ARGUMENTS are not consumed" {
	# `sudo -u admin <verb>` deliberately does NOT match: skipping arbitrary
	# non-dash words would let the prefix swallow anything and match the verb
	# mid-command. Pin the bound so a future "fix" widening it must rewrite
	# this test consciously.
	run match_cmd_at_anchor_hardened "$GC" "sudo -u admin git commit"
	[ "$status" -ne 0 ]
}

@test "match_git_commit_or_wrapper: bare, env-prefixed, and wrapper-path forms" {
	match_git_commit_or_wrapper "git commit -m x"
	match_git_commit_or_wrapper "FOO=bar git commit"
	match_git_commit_or_wrapper ".claude/skills/git-commit/run.sh --message-file /tmp/m"
	match_git_commit_or_wrapper "bash .claude/skills/git-commit/run.sh"
	run match_git_commit_or_wrapper "git committee"
	[ "$status" -ne 0 ]
}
