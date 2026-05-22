#!/bin/bash
set -u
# v4.24-O (#601) — shared bash-safety check used by BOTH:
#   - .claude/pre-commit-hooks/bash-safety.sh  (commit-time gate)
#   - .claude/hooks/bash-safety-write-guard.sh (PreToolUse Write gate)
#
# Keeping the rule in ONE place so the two enforcement points never drift.
# User feedback 2026-04-24: was getting bitten at commit time because the
# write-time check didn't exist; fixing that gap meant either duplicating
# the rule (drift risk) or factoring it out — this file is the shared copy.
#
# Usage:
#   bash_safety_check_content <display-name> <content>
#     → exit 0 pass / 1 fail (emits BLOCK message on stderr)
#   bash_safety_check_file <path>
#     → same but reads the file itself
#
# The rule, authoritative:
#   - `set -u` / `set -eu` / `set -eux` / etc. must appear within first 20
#     lines (regex: ^set -[a-z]*u[a-z]*\b|^set[[:space:]]+-[a-z]*u).
#   - Opt-out via `# set-u: opt-out — <reason>` in first 5 lines.
#   - Library files (basename matching _*.sh) are exempt — they're sourced.

# Returns 0 (pass) / 1 (fail). Stderr carries the BLOCK message on fail.
# Args: $1 = display path (for the error message), $2 = file content.
bash_safety_check_content() {
	local display=$1 content=$2 base head5 head20
	base=$(basename "$display")
	# Skip library files (sourced, not run).
	case "$base" in
	_*.sh) return 0 ;;
	esac
	head5=$(printf '%s' "$content" | head -5)
	head20=$(printf '%s' "$content" | head -20)
	# Opt-out comment in first 5 lines.
	if printf '%s' "$head5" | grep -q "^# set-u: opt-out"; then
		return 0
	fi
	# Require `set -u` or `set -eu` / `set -eux` etc. within first 20 lines.
	if printf '%s' "$head20" | grep -Eq "^set -[a-z]*u[a-z]*\b|^set[[:space:]]+-[a-z]*u"; then
		return 0
	fi
	{
		echo "BLOCK: $display — missing \`set -u\` (typo-in-varname silently expands to empty — hazard)"
		echo "  → Add \`set -u\` near top (or \`set -eu\` / \`set -euo pipefail\` for stricter)."
		echo "  → OR opt-out: add comment \`# set-u: opt-out — <reason>\` in first 5 lines."
		echo "  → Rule: regex must match within the first 20 lines of the file."
	} >&2
	return 1
}

bash_safety_check_file() {
	local path=$1
	[ -f "$path" ] || return 0
	bash_safety_check_content "$path" "$(cat "$path")"
}
