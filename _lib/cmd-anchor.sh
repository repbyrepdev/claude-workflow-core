#!/bin/bash
# auto-register: false
# v4.28-W4 (#677): canonical command-anchor regex shared across hooks.
# v4.28-W4 #748: removed `set -euo pipefail` from this lib — sourcing
# scripts (post-commit hooks, skill wrappers) define their own option
# discipline; inheriting set -e + pipefail caused silent aborts in
# callers that intentionally use `cmd | grep -c pattern || echo 0`
# fail-soft idioms.
#
# Three hooks were each re-implementing "is this command-start or after a
# shell separator" with slightly different regexes:
#   - skill-bypass-guard.sh: `(^|[;&|][[:space:]]*)`     ← canonical
#   - test-sh-scope-nudge.sh: `(^|[;&|])[[:space:]]*`    ← variant
#   - phase0.5-post-commit-rerun.sh: `(^|[;&|])[[:space:]]*`  ← variant
#
# Per CLAUDE.md SSOT-first rule, this lib defines the canonical form. The
# variants in test-sh-scope-nudge.sh and phase0.5-post-commit-rerun.sh
# functionally match the same set of inputs (whitespace consumption is
# greedy and `[;&|]` followed by `[[:space:]]*` accepts the same boundary
# as `[;&|][[:space:]]*` inside a group). Standardizing on the canonical
# closes a recurring CR class: regex drift between hooks that all need
# the same "verb at command-start" semantics.
#
# This file is sourced, not executed. Exposed:
#   CMD_SEGMENT_ANCHOR — extended-regex prefix matching command-start OR
#                        a shell separator followed by optional whitespace
#   CMD_SEGMENT_END    — extended-regex suffix matching whitespace or EOL
#                        (NOT a shell separator: a verb glued to `;`/`&`/`|`
#                        with no space does not match — documented bound)
#   CMD_HARDENED_PREFIX — #2396: grouping/wrapper/env-assignment grammar
#                        allowed between the anchor and the verb (see below)
#   match_cmd_at_anchor <verb_pattern> <cmd>
#                      — convenience: emit "$CMD_SEGMENT_ANCHOR<pattern>$CMD_SEGMENT_END"
#                        and grep -qE against the cmd string. Returns 0 on
#                        match, non-zero otherwise.
#   match_cmd_at_anchor_hardened <verb_pattern> <cmd>
#                      — same, with CMD_HARDENED_PREFIX between anchor + verb
#   match_git_commit_or_wrapper <cmd>
#                      — #748: bare `git commit` (env-prefix allowed) OR the
#                        git-commit skill-wrapper path
#
# Usage from a hook:
#   source "$(dirname "${BASH_SOURCE[0]}")/../_lib/cmd-anchor.sh"
#   if match_cmd_at_anchor 'git[[:space:]]+commit' "$CMD"; then ...
#   # OR build inline:
#   if printf '%s' "$CMD" | grep -qE "${CMD_SEGMENT_ANCHOR}git[[:space:]]+commit${CMD_SEGMENT_END}"; then ...

# History: r4 (#748) deliberately kept the env-var prefix OUT of this lib
# (callers carried an inline ENV_PREFIX). #2396 reverses that: two gate
# hooks byte-copied the same ENV_PREFIX to stay in lockstep — exactly the
# regex drift this lib exists to kill — and NEITHER detected command-
# wrapper (`command`/`builtin`/`sudo -E`/`env X=1`) or grouping (`{ v; }`,
# `( v )`) prefixes, so both failed OPEN on those forms. The hardened
# prefix below owns all of it in ONE place; callers interpolate it between
# CMD_SEGMENT_ANCHOR and their verb (or call the hardened helper).

CMD_SEGMENT_ANCHOR='(^|[;&|][[:space:]]*)'
CMD_SEGMENT_END='([[:space:]]|$)'

# #2396: everything that may legally sit between the anchor and the verb,
# any number of times, in any order:
#   - grouping openers: `{ ` brace group, `( ` subshell
#   - wrapper commands: `command`/`builtin` (bare), `sudo`/`env` with
#     optional dash-flags (flag ARGUMENTS — e.g. `sudo -u admin` — are NOT
#     consumed: skipping arbitrary non-dash words would let the prefix
#     swallow anything and match the verb mid-command)
#   - env assignments: `VAR=val` with the CR-hardened value alternation
#     (single-quoted | double-quoted | unquoted-not-starting-with-a-quote;
#     the leading-quote exclusion is the #858 fix) — the value is OPTIONAL
#     (`?`) so a bare `FOO= verb` (valid bash) is consumed too; phase1 r2
#     silent-failure: a required value let `FOO= gh pr merge` slip both
#     gates.
CMD_HARDENED_PREFIX='([{(][[:space:]]*|(command|builtin)[[:space:]]+|(sudo|env)([[:space:]]+-[^[:space:]]+)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=('"'"'[^'"'"']*'"'"'|"[^"]*"|[^"'"'"'[:space:]][^[:space:]]*)?[[:space:]]+)*'

match_cmd_at_anchor() {
	local pattern=$1
	local cmd=$2
	[ -n "$pattern" ] || return 1
	printf '%s' "$cmd" | grep -qE "${CMD_SEGMENT_ANCHOR}${pattern}${CMD_SEGMENT_END}"
}

# #2396: anchor match that ALSO accepts wrapper/grouping/env prefixes
# between the anchor and the verb. Gate hooks use this (or interpolate
# CMD_HARDENED_PREFIX themselves) so `{ gh pr merge 5; }`, `sudo -E git
# commit`, `env X=1 gh pr create`, `command bats` cannot slip a gate that
# fires on the bare form.
match_cmd_at_anchor_hardened() {
	local pattern=$1
	local cmd=$2
	[ -n "$pattern" ] || return 1
	# Delegate so the grep invocation mechanics live in ONE place.
	match_cmd_at_anchor "${CMD_HARDENED_PREFIX}(${pattern})" "$cmd"
}

# v4.28-W4 #748: match either `git commit ...` directly OR
# `.claude/skills/git-commit/run.sh ...` (the wrapper invocation).
# Closes the gap where post-commit-* hooks fire on direct git commit
# but miss commits routed through the skill wrapper. Optional
# env-var prefix (FOO=bar git commit ...) supported on the bare-git form.
#
# Usage:
#   if match_git_commit_or_wrapper "$CMD"; then ...
#
# Returns 0 if cmd starts with (after optional shell separator + whitespace):
#   - optional env-var prefix(es) followed by `git commit`
#   - OR the path `.claude/skills/git-commit/run.sh`
match_git_commit_or_wrapper() {
	local cmd=$1
	[ -n "$cmd" ] || return 1
	# Bare git-commit (with optional env-var prefix) OR skill wrapper path.
	# `.claude/skills/git-commit/run.sh` is the canonical wrapper invocation;
	# variants like `bash .claude/skills/git-commit/run.sh` also count
	# (bash is just an interpreter prefix, equivalent to invoking directly).
	local pattern='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*git[[:space:]]+commit|(bash[[:space:]]+)?\.claude/skills/git-commit/run\.sh'
	printf '%s' "$cmd" | grep -qE "${CMD_SEGMENT_ANCHOR}(${pattern})${CMD_SEGMENT_END}"
}
