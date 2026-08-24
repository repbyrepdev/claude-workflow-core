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
#   event_frontmatter_parse <hook_path>  — emit 4 lines: event\nmatcher\n
#       auto_register\nenforcement (raw; empty when absent — #2547)
#   event_frontmatter_event_valid <event>  — exit 0 if event in valid set
#   event_frontmatter_scan_window  — number of header lines to scan (30)
#   event_frontmatter_enforcement_required <event>  — exit 0 if the event's
#       hooks must classify ($EVENT_FRONTMATTER_ENFORCEMENT_REQUIRED_EVENTS)
#   event_frontmatter_enforcement_valid <value>  — exit 0 iff enforce|inform
#   event_frontmatter_enforcement <hook_path>  — validated value in one call
#   event_frontmatter_registered_hooks <dir>  — registered universe, one
#       path<TAB>event<TAB>enforcement record per hook; LOUD rc 1 on parse failure

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

# Parse frontmatter from a hook file's first $window lines. Emits FOUR lines
# (one per field) to stdout: event\nmatcher\nauto_register\nenforcement.
# Empty event = no frontmatter / treat as helper. The enforcement field is
# the RAW first word after `# enforcement:` (empty when absent) — judged by
# event_frontmatter_enforcement_valid, mirroring the event/matcher split
# (#2547 phase1 r3). Consumers read via:
#
#   _parsed=()
#   while IFS= read -r _line; do _parsed+=("$_line"); done < <(event_frontmatter_parse "$hook")
#   event="${_parsed[0]:-}"
#
# Why one-per-line not TSV: bash `read -r e m a` with IFS=$'\t' COLLAPSES
# leading empty fields (e.g. tab-tab-true is read as e=true / m="" / a="").
# One line per field preserves empties at the cost of a 4-element array.
event_frontmatter_parse() {
	local hook="$1" event="" matcher="" auto_register="true" enforcement=""
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
		"# enforcement:"*)
			val="${line#"# enforcement:"}"
			val="${val#"${val%%[![:space:]]*}"}" # ltrim
			val="${val%%[[:space:]]*}"           # first word; the — reason is prose
			enforcement="$val"
			;;
		esac
	done <<<"$_header"
	printf '%s\n%s\n%s\n%s\n' "$event" "$matcher" "$auto_register" "$enforcement"
}

# Validate event is one of the known values. Returns 0 if valid, 1 if not.
# Reads from $EVENT_FRONTMATTER_VALID_EVENTS so adding a 7th event only
# requires editing the variable above (single source of truth).
event_frontmatter_event_valid() {
	local event="$1"
	[[ "|$EVENT_FRONTMATTER_VALID_EVENTS|" == *"|$event|"* ]]
}

# #2547: events whose hooks must carry the enforce-vs-inform
# classification. Same pipe-alternation idiom as the sibling constants —
# extending the requirement to another event is a one-file edit here, not
# a string-literal hunt across gate + audit (phase1 r3 code-reviewer).
# Named as a REQUIREMENT, not a state (phase1 r4: "classified" read as
# "has been classified", pre-empting the per-hook predicate's name).
EVENT_FRONTMATTER_ENFORCEMENT_REQUIRED_EVENTS="PostToolUse"

event_frontmatter_enforcement_required() {
	local event="$1"
	[[ "|$EVENT_FRONTMATTER_ENFORCEMENT_REQUIRED_EVENTS|" == *"|$event|"* ]]
}

# #2547: validate a raw enforcement value against the CLOSED vocabulary —
# a typo like "advisory" must read as unclassified, never silently pass
# (phase1 r2 pr-test-analyzer). Mirrors event_frontmatter_event_valid:
# parse extracts raw, a predicate judges (phase1 r3 code-reviewer — the
# accessor previously fused extract+judge, so no caller could distinguish
# "invalid value" from "missing").
event_frontmatter_enforcement_valid() {
	case "$1" in
	enforce | inform) return 0 ;;
	*) return 1 ;;
	esac
}

# Convenience composition kept for callers that want the validated value
# in one call (the live-tree audit, tests): emits enforce|inform, rc 1 on
# absent OR out-of-vocabulary. Callers already holding parse output should
# read its 4th line + the predicate instead of re-reading the header. Field
# extraction uses the documented read-into-array idiom (phase1 r4: this
# accessor was the one consumer slicing with printf|sed).
event_frontmatter_enforcement() {
	local hook="$1" _parse_out val
	_parse_out=$(event_frontmatter_parse "$hook") || return 1
	{
		read -r _
		read -r _
		read -r _
		read -r val
	} <<<"$_parse_out"
	event_frontmatter_enforcement_valid "$val" || return 1
	printf '%s\n' "$val"
}

# #2547: ONE definition of "the registered hooks of a directory" — skip
# helper basenames, parse, honor the auto-register:false opt-out. Emits
# one TAB-separated record per hook: path<TAB>event<TAB>enforcement(raw)
# — carrying the parsed fields so consumers do not re-parse per hook
# (phase1 r4: the audit paid three parses per hook, and its re-parse
# guard was dead — a pipeline swallowed the rc, the exact silent shrink
# this emitter's contract forbids). install-hooks.sh and
# check-hook-ack-wiring.sh still carry sibling copies with
# installer-specific extras (executable preflight) — migrating them onto
# this emitter is tracked in epic #2566 rather than risked mid-PR. A
# parse failure is LOUD + rc 1: a shrunken universe must never read as a
# clean one (phase1 r2/r3).
event_frontmatter_registered_hooks() {
	local dir="$1" f base _parse_out event auto enforcement
	for f in "$dir"/*.sh; do
		[ -e "$f" ] || continue # nullglob-safe: literal pattern on empty dir
		base=$(basename "$f")
		event_frontmatter_skip_basename "$base" && continue
		if ! _parse_out=$(event_frontmatter_parse "$f"); then
			echo "event_frontmatter_registered_hooks: PARSE FAILURE: $f (unreadable?) — refusing a shrunken universe" >&2
			return 1
		fi
		{
			read -r event
			read -r _
			read -r auto
			read -r enforcement
		} <<<"$_parse_out"
		[ "$auto" = "false" ] && continue
		[ -n "$event" ] && printf '%s\t%s\t%s\n' "$f" "$event" "$enforcement"
	done
	return 0
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
