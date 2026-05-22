#!/bin/bash
set -u
# v4.28 (#638) — SSOT for hook frontmatter parsing.
#
# Sourced by BOTH:
#   - .claude/hooks/install-hooks.sh         (registers hooks per frontmatter)
#   - .claude/pre-commit-hooks/event-frontmatter-check.sh (validates new hooks)
#
# Mirrors the bash-safety-write-guard.sh / bash-safety.sh precedent: one rule,
# multiple gates, single source. Adding a 7th event, changing the helper-prefix
# convention, or widening the scan window is a one-file edit.
#
# This is a sourced library — uses `set -u` only (NOT -e/-o pipefail, which
# would propagate to the sourcing script's flow control unexpectedly).
#
# Public API:
#   $EVENT_FRONTMATTER_VALID_EVENTS  — pipe-separated regex alternation
#   event_frontmatter_skip_basename <basename>  — exit 0 if hook is a helper
#   event_frontmatter_parse <hook_path>  — emit 3 lines: event\nmatcher\nauto_register
#   event_frontmatter_event_valid <event>  — exit 0 if event in valid set
#   event_frontmatter_scan_window  — number of header lines to scan (30)

# Pipe-alternation, single source of truth for both internal `[[ =~ ]]` matching
# AND consumer interpolation (event-frontmatter-check.sh's error-message hint).
EVENT_FRONTMATTER_VALID_EVENTS="PreToolUse|PostToolUse|SessionStart|PreCompact|Stop|UserPromptSubmit"

# Frontmatter scan window — lines from the top of each hook file.
event_frontmatter_scan_window() { printf '30'; }

# Returns 0 (skip) for helper / installer filenames, 1 (process) otherwise.
# Same convention as install-hooks.sh: `_*` for helpers, `install-*` for installers.
event_frontmatter_skip_basename() {
	local base="$1"
	case "$base" in
	_* | install-*) return 0 ;;
	*) return 1 ;;
	esac
}

# Parse frontmatter from a hook file's first $window lines. Emits THREE lines
# (one per field) to stdout: event\nmatcher\nauto_register. Empty event = no
# frontmatter / treat as helper. Consumers read via:
#
#   _parsed=()
#   while IFS= read -r _line; do _parsed+=("$_line"); done < <(event_frontmatter_parse "$hook")
#   event="${_parsed[0]:-}"
#
# Why one-per-line not TSV: bash `read -r e m a` with IFS=$'\t' COLLAPSES
# leading empty fields (e.g. tab-tab-true is read as e=true / m="" / a="").
# One line per field preserves empties at the cost of a 3-element array.
event_frontmatter_parse() {
	local hook="$1" event="" matcher="" auto_register="true"
	# Fail-closed: capture `head`'s output + rc explicitly before parsing.
	# Prior form `done < <(head ... "$hook")` had two problems: (a) the
	# preflight `[ -f ] && [ -r ]` check has a TOCTOU race with `head` —
	# file could disappear in between, and process-substitution swallows
	# `head`'s rc=1; (b) the caller would silently see empty fields and
	# treat them as "no frontmatter" instead of "couldn't read." Capturing
	# into a variable + checking rc collapses both checks into one and
	# eliminates the race.
	local window _header
	window=$(event_frontmatter_scan_window)
	if ! _header=$(head -n "$window" "$hook" 2>/dev/null); then
		return 1
	fi
	# Use bash parameter expansion instead of `echo|sed` subshells: each sed
	# invocation forks a new process, so the original ran 3-N forks per hook
	# scan. Param expansion is in-shell + faster + sufficient for these prefixes.
	# Inline-comment strip: `# event: PreToolUse # explanation` should yield
	# event="PreToolUse", not "PreToolUse # explanation". Strip from first
	# unquoted `#` onward (after the directive prefix already consumed).
	local val
	while IFS= read -r line; do
		case "$line" in
		"# event:"*)
			val="${line#"# event:"}"
			val="${val#"${val%%[![:space:]]*}"}" # ltrim
			val="${val%%#*}"                     # strip inline comment
			val="${val%"${val##*[![:space:]]}"}" # rtrim (post-strip)
			event="$val"
			;;
		"# matcher:"*)
			val="${line#"# matcher:"}"
			val="${val#"${val%%[![:space:]]*}"}"
			val="${val%%#*}" # strip inline comment
			val="${val%"${val##*[![:space:]]}"}"
			val="${val#\"}"
			val="${val%\"}"
			matcher="$val"
			;;
		"# auto-register:"*)
			val="${line#"# auto-register:"}"
			val="${val#"${val%%[![:space:]]*}"}"
			val="${val%%#*}" # strip inline comment
			val="${val%"${val##*[![:space:]]}"}"
			auto_register="$val"
			;;
		esac
	done <<<"$_header"
	printf '%s\n%s\n%s\n' "$event" "$matcher" "$auto_register"
}

# Validate event is one of the known values. Returns 0 if valid, 1 if not.
# Reads from $EVENT_FRONTMATTER_VALID_EVENTS so adding a 7th event only
# requires editing the variable above (single source of truth).
event_frontmatter_event_valid() {
	local event="$1"
	[[ "|$EVENT_FRONTMATTER_VALID_EVENTS|" == *"|$event|"* ]]
}

# Events that don't accept a matcher per Claude Code spec — passing a matcher
# anyway gets silently ignored, masking typos. Listed here so the validator
# can enforce "empty matcher" for these. Other events (PreToolUse, etc.)
# require a non-empty matcher; specific-value validation (Bash vs Bas) defers
# to Claude Code itself since the valid set is tool-namespace-extensible.
EVENT_FRONTMATTER_MATCHERLESS_EVENTS="UserPromptSubmit|Stop|PostToolBatch"

# Validate matcher is appropriate for the event. Returns 0 if OK, 1 if not.
#   - Matcherless events (UserPromptSubmit, Stop): matcher MUST be empty.
#     Setting one is a typo that Claude Code silently ignores.
#   - Matcher-supporting events: matcher MAY be empty (= match all per
#     Claude Code spec) or specific. Specific-value validation (Bash vs
#     Bas) defers to Claude Code itself since the valid set is
#     tool-namespace-extensible.
event_frontmatter_matcher_valid() {
	local event="$1" matcher="$2"
	if [[ "|$EVENT_FRONTMATTER_MATCHERLESS_EVENTS|" == *"|$event|"* ]]; then
		[ -z "$matcher" ]
	else
		return 0 # liberal — Claude Code's matcher syntax is the SSOT
	fi
}
