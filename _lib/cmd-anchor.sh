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
#   CMD_SEGMENT_END    — extended-regex suffix matching whitespace, EOL,
#                        or another shell separator (for verb boundary)
#   match_cmd_at_anchor <verb_pattern> <cmd>
#                      — convenience: emit "$CMD_SEGMENT_ANCHOR<pattern>$CMD_SEGMENT_END"
#                        and grep -qE against the cmd string. Returns 0 on
#                        match, non-zero otherwise.
#
# Usage from a hook:
#   source "$(dirname "${BASH_SOURCE[0]}")/../_lib/cmd-anchor.sh"
#   if match_cmd_at_anchor 'git[[:space:]]+commit' "$CMD"; then ...
#   # OR build inline:
#   if printf '%s' "$CMD" | grep -qE "${CMD_SEGMENT_ANCHOR}git[[:space:]]+commit${CMD_SEGMENT_END}"; then ...

# r4 silent-failure-hunter rejected (intentional): no env-var prefix
# anchor exposed here — env-var matching is a different pattern (whole-
# token bracket-class boundary) and conflating them masked a class of
# bugs. Callers that need env-var-prefix matching keep their inline regex.

CMD_SEGMENT_ANCHOR='(^|[;&|][[:space:]]*)'
CMD_SEGMENT_END='([[:space:]]|$)'

match_cmd_at_anchor() {
	local pattern=$1
	local cmd=$2
	[ -n "$pattern" ] || return 1
	printf '%s' "$cmd" | grep -qE "${CMD_SEGMENT_ANCHOR}${pattern}${CMD_SEGMENT_END}"
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
