#!/bin/bash
set -u
# v4.27 (#634 round 3) — SSOT for command-prefix regexes used by hooks
# that anchor on shell-separator + optional env-assignment prefix +
# optional interpreter wrapper before matching a target script/binary.
#
# Why SSOT: same pattern lived in skill-bypass-guard.sh,
# phase0.5-before-phase1.sh, phase1-launch-completeness-gate.sh,
# pr-merge-board-cascade.sh, pr-trigger.sh, and others. CR review #634
# round 2 found 3 of them still had uppercase-only env names; round 3
# found the lowercase fix still missed empty-value assignments
# (`FOO= cmd`) and assignments-after-env (`env FOO= cmd`). Fix-it-once.
#
# Usage:
#   source "$REPO_ROOT/.claude/_lib/cmd-prefix-regex.sh"
#   if printf '%s' "$CMD" | grep -qE "${CMD_PREFIX_REGEX}gh[[:space:]]+pr[[:space:]]+create([[:space:]]|\$)"; then
#     ...
#   fi

# Single env-assignment fragment: NAME=value where:
#   NAME starts with letter/underscore, contains [A-Za-z0-9_]
#   value is empty (FOO= ), unquoted no-space, double-quoted, or single-quoted
ENV_ASSIGN_FRAGMENT='[A-Za-z_][A-Za-z0-9_]*=([^[:space:]]*|"[^"]*"|'"'"'[^'"'"']*'"'"')[[:space:]]+'

# Optional env-keyword + assignments + interpreter combo. Each layer optional.
# Order: anchor → bare assignments → optional `env` + more assignments →
# optional `bash`/`/bin/bash`/`/usr/bin/env bash` interpreter (with optional
# short flags like `-l`, `-c`, `-lc`).
# Handles all of:
#   FOO=1 cmd
#   FOO= cmd                   (empty value)
#   env FOO=1 cmd
#   FOO=1 env BAR=2 cmd
#   bash cmd
#   bash -lc cmd               (bash flags between interp and cmd)
#   sh -c cmd
#   FOO=1 /usr/bin/env bash cmd
# Note: `bash -lc 'git commit ...'` (quoted form) is handled separately via
# WRAPPED_CMD inner-extract in skill-bypass-guard.sh — this regex matches the
# shell-tokenized form where flags+target appear as whitespace-separated tokens.
CMD_PREFIX_REGEX="(^|[;&|][[:space:]]*)(${ENV_ASSIGN_FRAGMENT})*((/usr/bin/)?env[[:space:]]+(${ENV_ASSIGN_FRAGMENT})*)?(([^[:space:]]*env[[:space:]]+)?[^[:space:]]*(bash|sh|zsh)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*)?"

cmd_prefix_gh() {
	# $1 = subcommand pattern (e.g. "pr[[:space:]]+create")
	printf '%s' "${CMD_PREFIX_REGEX}gh[[:space:]]+${1}([[:space:]]|\$)"
}

cmd_prefix_target() {
	# $1 = target binary pattern (e.g. "phase1-launcher\\.sh")
	printf '%s' "${CMD_PREFIX_REGEX}[^[:space:]]*${1}([[:space:]]|\$)"
}
