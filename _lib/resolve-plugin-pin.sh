#!/bin/bash
# v0.7.1 (#23): shared library to resolve the claude-workflow-core plugin pin
# from a consumer's .pre-commit-config.yaml. Replaces byte-identical awk
# parsers previously duplicated across:
#   - .claude/hooks/review-log.sh (FCP shim)
#   - .claude/skills/ship-pr-cycle/run.sh (FCP wrapper)
#
# Both shim/wrapper now source this lib instead of inlining the parser.
# Future parser fixes land in ONE place; consumer repos pick up the change
# automatically on next pin bump.
#
# Sourcing contract:
#   source "$(_shipcycle_resolve _lib/resolve-plugin-pin.sh)"
# OR direct (when invoked from plugin cache):
#   source "$(dirname "${BASH_SOURCE[0]}")/../_lib/resolve-plugin-pin.sh"
#
# Function exported:
#   resolve_plugin_pin <config-path>
#     Echoes the pin (numeric e.g. "0.7.1") on stdout.
#     Exits 0 on success.
#     Returns 1 if config missing / no claude-workflow-core block / no rev.
#     Returns 2 if pin format invalid (defense-in-depth path-traversal block).

# shellcheck disable=SC2034  # function consumed by callers

resolve_plugin_pin() {
	local config="$1"
	local pin

	if [ -z "$config" ]; then
		echo "resolve_plugin_pin: missing config-path argument" >&2
		return 2
	fi
	if [ ! -f "$config" ]; then
		echo "resolve_plugin_pin: config not found at $config" >&2
		return 1
	fi

	# Parser invariants:
	# - Full URL anchor on the - repo: line (not suffix-only — prevents
	#   fork/mirror name collisions).
	# - Optional-quote class MUST appear before v? in the first sub so
	#   quoted YAML scalars (`rev: "v0.7.0"`) parse correctly.
	# - v? makes the leading `v` optional (pre-commit accepts both
	#   `rev: v0.7.0` and `rev: 0.7.0`; SHA pins land here too).
	# - Trailing-junk strip removes inline comments, closing quote, ws.
	pin=$(awk '
		/^[[:space:]]*-[[:space:]]*repo:[[:space:]]+https:\/\/github\.com\/repbyrepdev\/claude-workflow-core[[:space:]]*$/ {found=1; next}
		found && /^[[:space:]]*rev:/ {
			sub(/^[[:space:]]*rev:[[:space:]]*["'\'']?v?/, "")
			sub(/["'\''[:space:]#].*$/, "")
			print
			exit
		}
	' "$config")

	if [ -z "$pin" ]; then
		echo "resolve_plugin_pin: no claude-workflow-core rev: found in $config" >&2
		return 1
	fi

	# Defense-in-depth: reject PIN values that could traverse the plugin
	# cache root. Must start with alphanumeric (rejects standalone `.`,
	# `..`, `...`, leading-dot values) AND match the conservative char
	# class (no `/` path separators).
	if ! printf '%s' "$pin" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
		echo "resolve_plugin_pin: invalid PIN value '$pin' — must start with alphanumeric + match [A-Za-z0-9._-]+" >&2
		return 2
	fi

	printf '%s\n' "$pin"
}
