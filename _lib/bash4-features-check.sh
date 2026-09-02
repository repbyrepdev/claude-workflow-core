#!/bin/bash
set -u
# v4.24-P (#603) — shared detector for bash 4.0+ features in shell scripts.
# Used by:
#   - .claude/pre-commit-hooks/bash4-features-check.sh (commit gate)
#   - .claude/hooks/bash4-features-write-guard.sh (PreToolUse Write/Edit/MultiEdit gate)
#
# Rule: if any bash 4.0+ feature is used AND the shebang is plain
# `#!/bin/bash`, REFUSE. macOS ships /bin/bash 3.2 (Apple licensing); the
# feature will silently fail at runtime. Require `#!/usr/bin/env bash` or
# `#!/opt/homebrew/bin/bash` (which resolve to Homebrew's 5.x). Also
# refused, independent of any feature match (#2645 r1): a malformed or
# unknown-key `# bash4-waiver:` on an unsafe-shebang file, and any internal
# tool failure (head/sed/grep) — the detectors fail CLOSED, never toward a
# clean bill they cannot vouch for.
#
# Anchor case: CR autofix introduced `mapfile -d ''` into phase1-launcher.sh
# v4.24-R cycle — silently failed, caused phantom test skips, ~15min debug.
#
# Detected features (bash-4+):
#   mapfile -d, readarray -d         — bash 4.4
#   shopt -s globstar                — bash 4.0
#   declare -A, typeset -A           — bash 4.0 (assoc arrays)
#   ${var^^}, ${var,,}, ${var^}, ${var,}  — bash 4.0 (case transforms)
#   &>>                               — bash 4.0 (append both streams)
#   mapfile / readarray builtins     — bash 4.0 (any form)
#   ;& and ;;& case terminators      — bash 4.0 (PARSE error on 3.2)
#   coproc                            — bash 4.0
#   declare/typeset -g               — bash 4.2
#   declare/typeset/local -n nameref — bash 4.3
#   ${arr[-1]} negative subscripts   — bash 4.3
#   ${var@Q} parameter transforms    — bash 4.4+ (@Q @E @P @A @K @a @k @U @u @L)
#
# All detectors scan COMMENT-STRIPPED content (whole comment lines removed):
# prose like `# ${var,,} is bash 4+` must not flag a file that deliberately
# AVOIDS the feature (#2645 — three shipped files false-positived exactly
# this way). Limitation, accepted: an inline TRAILING comment on a code line
# can still false-positive; keep feature mentions on their own comment line.
#
# SCOPE (#2645 r1 security-review): this is a LEXICAL gate targeting
# accidental/autofix regressions. Deliberate evasion — line-continuation
# splits (`declare \` + `-A`), eval/indirection, variable-built flags — is
# out of scope; no line-regex can hold that door, and a deliberate attacker
# has strictly easier paths any such gate misses. (Common LEGITIMATE
# prefixes are in scope: builtin/command/time joined the _B4_PRE chain in
# CR round 3 — `builtin declare -A` is an accidental shape, not evasion.)
#
# Args: $1 = display-name, $2 = content.
# Returns 0 if safe, 1 if refused (emits BLOCK message on stderr).

# Waiver keys — ONE definition (#2645 r1). The per-detector suppression
# calls, the membership validation, and the unknown-key error text all read
# this constant; adding a detector means adding its key HERE and nowhere
# else. Keys follow the bash-manual term for the feature (declare-A,
# declare-g, nameref, fallthrough, ...) and MUST stay [A-Za-z-] — they
# interpolate unescaped into a grep -E pattern in _b4_waived.
_B4_WAIVER_KEYS="mapfile-d globstar declare-A case-transform readarray append-redirect fallthrough coproc declare-g nameref neg-subscript param-transform"

# _b4_waived <content> <key> — rc 0 when <content> carries a VALID waiver
# comment for <key>: `# bash4-waiver: <key> <reason containing a letter>`.
# A reasonless or unknown-key waiver does NOT suppress — the caller's
# post-scan reports it as a finding. Waivers are FILE-scoped by design:
# comment-stripping precedes any line tracking, so a next-line disable
# convention is not available here — waive only narrowly-reasoned,
# guarded uses, and expect review to hold the line.
_b4_waived() {
	printf '%s' "${1:-}" | grep -Eq "^[[:space:]]*#[[:space:]]*bash4-waiver:[[:space:]]*${2}[[:space:]]+[^[:space:]].*[A-Za-z]"
}

# bash4_features_exempt_path <path> — rc 0 ONLY for the detector lib itself
# (this file): its source necessarily contains the feature regexes, so it
# self-matches. The exemption is exactly one file wide (#2645 r1 — narrowed
# from a blanket _lib/ carve-out: sourced libs execute under the CALLER's
# bash, so a bash-4 feature in any other lib breaks every 3.2 caller; those
# use per-key waivers instead). Shared by both front-end gates so the scope
# predicate has one home (they drifted once before — v4.24-Q2 #609).
bash4_features_exempt_path() {
	case "${1:-}" in
	_lib/bash4-features-check.sh | */_lib/bash4-features-check.sh) return 0 ;;
	esac
	return 1
}

# bash4_features_skip_basename <path> — rc 0 for `_*.sh` basenames. This is
# the PRE-EXISTING scope carve-out both front-end gates apply, held here so
# it cannot drift between them (#2645 r1 simplifier; same in-lib pattern as
# bash-safety-check's carve-out). Retained for continuity, NOT because
# sourced code is safe on 3.2 (it is not — sourced libs execute under the
# caller's bash). Narrowing it is deliberately out of #2645's scope; until
# then, underscore-named libs are the one unscanned class.
bash4_features_skip_basename() {
	case "$(basename "${1:-}")" in
	_*.sh) return 0 ;;
	esac
	return 1
}

# bash4_features_unsafe_shebang <first-line> — rc 0 when the line is the
# bash-3-unsafe form (`#!/bin/bash`, optionally with arguments). ONE
# definition shared by the lib's own scan and the write-guard's on-disk
# check (#2645 r1 simplifier — the duplicated case pattern was the same
# drift class that produced bash4_features_exempt_path).
bash4_features_unsafe_shebang() {
	# Whitespace-robust (CR #2649): `#! /bin/bash`, tab-separated args, and
	# trailing blanks are the same interpreter; the old exact-prefix match
	# failed OPEN on them. Parse: strip `#!`, word-split, compare the first
	# token exactly — `/opt/homebrew/bin/bash` and `/usr/bin/env bash`
	# never equal `/bin/bash`, so safe interpreters cannot false-match.
	# CRLF checkout (backup review #2649): `#!/bin/bash\r` left a trailing
	# CR on the token, failing the compare and silently disabling the whole
	# gate for that file — strip it before parsing.
	local _b4_line="${1:-}"
	_b4_line="${_b4_line%$'\r'}"
	case "$_b4_line" in
	"#!"*) ;;
	*) return 1 ;;
	esac
	# shellcheck disable=SC2086  # deliberate word-split: first token = interpreter path
	set -- ${_b4_line#"#!"}
	[ "${1:-}" = "/bin/bash" ]
}

# _b4_hit <body> <regex> — grep -Eq wrapper that separates "no match" from
# "grep itself failed" (rc >= 2: bad regex, missing binary, signal). A tool
# failure must not read as a clean bill (#2645 r1 silent-failure): it sets
# _B4_TOOL_ERR — dynamically scoped from bash4_features_check_content, the
# only caller; if that coupling ever breaks the degraded behavior is the
# old fail-open, not a crash — and returns non-zero so the detector body
# is skipped; the caller turns a non-empty _B4_TOOL_ERR into a BLOCK.
_b4_hit() {
	printf '%s' "${1:-}" | grep -Eq "${2:-}"
	local _rc=$?
	if [ "$_rc" -ge 2 ]; then
		_B4_TOOL_ERR="grep rc=$_rc on regex: ${2:-}"
	fi
	return "$_rc"
}

# Shared boundary prefix for builtin-keyword rules (#2645 r1, extended r1
# test-analysis): a builtin counts when it follows line start, a control
# char (; { ( ) & |), or a CHAIN of reserved words after one of those —
# `for f in a b; do readarray ...`, `if declare -A m; then` are the anchor
# regression class in its most common single-line shape, and the bare
# control-char class missed them (probed live: rc=1). The chain form
# `((word)[[:space:]]+)*` also covers `do while :; do ...` nesting, and
# `!` (a reserved word in command position) covers negated commands like
# `if ! mapfile -d '' x <f; then` (CR #2649 r2 fail-open). Chain words may
# carry option tokens (`command -p readarray`, `time -p mapfile` — r4);
# reserved words never take options, so the extra `(-opt)*` there is inert.
# r5 closes the remaining simple-command prefix grammar: ASSIGNMENT words
# (`B4_TEST=1 mapfile x`, `a[0]=v declare -A m` — unquoted values; a
# space inside a QUOTED value still breaks the chain, accepted as rare +
# same-direction miss) and leading REDIRECTIONS (`< input mapfile x`,
# `2>log readarray y`).
_B4_PRE='(^|[;{()&|`])[[:space:]]*(((if|then|elif|else|do|while|until|!|builtin|command|time)([[:space:]]+-[A-Za-z][A-Za-z-]*)*|[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?=[^[:space:]]*|[0-9]*[<>]{1,2}[[:space:]]*[^[:space:]]+)[[:space:]]+)*'

bash4_features_check_content() {
	local display="${1:-}" content="${2:-}" body shebang
	[ -n "$display" ] && [ -n "$content" ] || return 0
	local _B4_TOOL_ERR=""
	# Extract shebang (first line). head failure would empty $shebang and
	# silently skip the whole check — fail closed instead (#2645 r1,
	# matches the cat check in bash4_features_check_file).
	if ! shebang=$(printf '%s' "$content" | head -1); then
		echo "BLOCK: $display — cannot extract shebang (head failed); failing closed" >&2
		return 1
	fi
	# Safe shebang → out of scope (shared predicate, one definition).
	bash4_features_unsafe_shebang "$shebang" || return 0
	# Detect features. Using grep -E so the regex set is explicit + auditable.
	# Comment-line stripping is hoisted here for ALL detectors (#2645): the
	# sed removes lines whose first non-whitespace char is `#`. The shebang
	# (line 1, `#!`) goes too — irrelevant, no detector targets it. Prior to
	# this hoist only the &>> rule stripped comments, and three shipped files
	# false-positived on comment PROSE mentioning the very feature their code
	# avoids (scripts/test.sh, skills/_lib/skill-common.sh, phase1-launcher).
	local findings=""
	# sed failure would empty $body and disable ALL detectors at once —
	# fail closed instead (#2645 r1 silent-failure).
	if ! body=$(printf '%s' "$content" | sed '/^[[:space:]]*#/d'); then
		echo "BLOCK: $display — comment-strip failed (sed); failing closed" >&2
		return 1
	fi
	# Builtin-keyword rules share the $_B4_PRE boundary prefix (defined
	# above) instead of line-start only (#2645): real code writes
	# `f() { declare -n ref=$1; }`, `x) mapfile -d ...`, and single-line
	# `for ...; do readarray ...` — the old ^-anchor missed every
	# inline-body use, and the bare control-char class missed the
	# reserved-word forms. Prose in plain strings stays unmatched (the
	# builtin must follow a control char / reserved-word chain, not a
	# quote), which keeps comment-free false positives rare.
	#
	# Deliberate, guarded use gets a WAIVER, not a path exemption (#2645):
	# a comment line `# bash4-waiver: <key> — <reason>` suppresses exactly
	# that detector for the file. The reason is MANDATORY — a bare key does
	# not suppress and is itself reported as malformed, as is an unknown
	# key (typo insurance). The key vocabulary lives in $_B4_WAIVER_KEYS —
	# one definition. A waiver is for a use that is guarded, degradation-
	# documented, and genuinely needed — not a convenience escape.
	if _b4_hit "$body" "${_B4_PRE}(mapfile|readarray)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[a-z]*d[a-z]*\b" && ! _b4_waived "$content" mapfile-d; then
		findings="${findings:+$findings
}  - mapfile -d / readarray -d (bash 4.4) — CR autofix favorite, silently fails on /bin/bash 3.2"
	fi
	# shopt -s globstar (bash 4.0)
	if _b4_hit "$body" "${_B4_PRE}shopt[[:space:]]+-s[[:space:]]+globstar" && ! _b4_waived "$content" globstar; then
		findings="${findings:+$findings
}  - shopt -s globstar (bash 4.0)"
	fi
	# declare -A / typeset -A (bash 4.0)
	if _b4_hit "$body" "${_B4_PRE}(declare|typeset)[[:space:]]+-[a-zA-Z]*A" && ! _b4_waived "$content" declare-A; then
		findings="${findings:+$findings
}  - declare -A / typeset -A (bash 4.0 associative arrays)"
	fi
	# Case transforms ${var^^} ${var,,} etc. (bash 4.0). The optional
	# `(\[[^]]+\])?` catches array-element forms like ${arr[0]^^} or
	# ${arr[$i],,} (v4.24-Q2 #608 CR finding).
	if _b4_hit "$body" '\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]+\])?(\^\^|,,|\^|,)[^}]*\}' && ! _b4_waived "$content" case-transform; then
		findings="${findings:+$findings
}  - \${var^^}/\${var,,} case transforms (bash 4.0)"
	fi
	# mapfile / readarray builtins (any form — bash 4.0; they are synonyms,
	# and bare `mapfile` had NO rule until CR #2649 r3 — only the 4.4 -d
	# sub-case was covered). The -d sub-case ALSO matches the earlier rule;
	# the intentional double-match is fine, both point at the same fix.
	if _b4_hit "$body" "${_B4_PRE}(mapfile|readarray)\b" && ! _b4_waived "$content" readarray; then
		findings="${findings:+$findings
}  - mapfile / readarray (bash 4.0)"
	fi
	# &>> append-both-streams redirect (bash 4.0). v4.24-Q2 #609 gap fix.
	# (Comment stripping now happens once, above, for every detector.)
	if _b4_hit "$body" '&>>[[:space:]]*[^[:space:]]' && ! _b4_waived "$content" append-redirect; then
		findings="${findings:+$findings
}  - &>> append-both-streams redirect (bash 4.0)"
	fi
	# ;& and ;;& case-branch terminators (bash 4.0). On 3.2 these are PARSE
	# errors — the whole script dies before running a single line, which is
	# the worst failure mode this gate exists for (#2645; hit by hand in
	# #2641). The token must be contiguous and end at space/EOL, but may be
	# PRECEDED by any non-;& char (phase2 r2: compact `echo x;&` / `:;&`
	# were missed by the old leading-space requirement). `[^;&]` before the
	# alternation keeps the `;&` tail inside `;;&` from double-matching and
	# keeps `cmd; & sleep` (legal 3.2) and `2>&1` unmatched.
	if _b4_hit "$body" '(^|[^;&])(;;&|;&)([[:space:]]|$)' && ! _b4_waived "$content" fallthrough; then
		findings="${findings:+$findings
}  - ;& / ;;& case fall-through terminators (bash 4.0 — PARSE error on 3.2)"
	fi
	# coproc keyword (bash 4.0).
	if _b4_hit "$body" "${_B4_PRE}coproc\b" && ! _b4_waived "$content" coproc; then
		findings="${findings:+$findings
}  - coproc (bash 4.0)"
	fi
	# declare/typeset -g global-scope flag (bash 4.2).
	if _b4_hit "$body" "${_B4_PRE}(declare|typeset)[[:space:]]+-[a-zA-Z]*g" && ! _b4_waived "$content" declare-g; then
		findings="${findings:+$findings
}  - declare -g / typeset -g (bash 4.2)"
	fi
	# declare/typeset/local -n namerefs (bash 4.3). The `n` must sit inside
	# the flag cluster itself (`-n`, `-in`, `-rn`); a separate variable that
	# happens to be named n (`local -i n=5`) does not match.
	if _b4_hit "$body" "${_B4_PRE}(declare|typeset|local)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*\b" && ! _b4_waived "$content" nameref; then
		findings="${findings:+$findings
}  - declare -n / local -n namerefs (bash 4.3)"
	fi
	# Negative array subscripts ${arr[-1]} / ${#arr[-1]} (bash 4.3). `:-`
	# default-expansion never matches — the `[` is required before the `-`.
	if _b4_hit "$body" '\$\{[#!]?[a-zA-Z_][a-zA-Z0-9_]*\[[[:space:]]*-[0-9]' && ! _b4_waived "$content" neg-subscript; then
		findings="${findings:+$findings
}  - \${arr[-1]} negative array subscripts (bash 4.3)"
	fi
	# ${var@Q}-style parameter transformations (bash 4.4; U/u/L are 5.1).
	if _b4_hit "$body" '\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]+\])?@[QEPAKakULu]\}' && ! _b4_waived "$content" param-transform; then
		findings="${findings:+$findings
}  - \${var@Q} parameter transforms (bash 4.4+)"
	fi
	# Malformed / unknown waivers are FINDINGS themselves — a typo'd key must
	# not silently fail to suppress (the operator believes they are covered),
	# and a reasonless waiver is an unaudited bypass. Scans the ORIGINAL
	# content (waivers live on comment lines, which $body no longer has).
	# Materialized first (CR #2649): in the old `done < <(... grep ...)`
	# form this was the one detector-path grep whose rc >= 2 escaped
	# set -e AND the _B4_TOOL_ERR accumulator — a grep failure silently
	# skipped malformed-waiver reporting. rc 1 (no waiver lines) is normal.
	local _wline _wkey _wlines="" _wrc=0
	_wlines=$(printf '%s' "$content" | grep -E '^[[:space:]]*#[[:space:]]*bash4-waiver:') || _wrc=$?
	if [ "$_wrc" -ge 2 ]; then
		_B4_TOOL_ERR="grep rc=$_wrc scanning bash4-waiver lines"
	fi
	while IFS= read -r _wline; do
		[ -n "$_wline" ] || continue
		_wkey=$(printf '%s' "$_wline" | sed -E 's/^[[:space:]]*#[[:space:]]*bash4-waiver:[[:space:]]*//; s/[[:space:]].*$//')
		case " $_B4_WAIVER_KEYS " in
		*" $_wkey "*)
			# Validity is judged by the SAME predicate that grants
			# suppression (_b4_waived) — one definition, so "suppresses"
			# and "reported malformed" can never disagree (#2645 r1).
			_b4_waived "$_wline" "$_wkey" || findings="${findings:+$findings
}  - bash4-waiver '${_wkey}' has NO reason — a reason is mandatory, waiver ignored"
			;;
		*)
			findings="${findings:+$findings
}  - unknown bash4-waiver key '${_wkey}' — valid keys: ${_B4_WAIVER_KEYS}"
			;;
		esac
	done <<<"$_wlines"
	# A detector-tool failure is a BLOCK, not a clean bill (#2645 r1): with
	# grep erroring, "no features found" is exactly what we cannot claim.
	if [ -n "$_B4_TOOL_ERR" ]; then
		echo "BLOCK: $display — detector errored; failing closed ($_B4_TOOL_ERR)" >&2
		return 1
	fi
	[ -z "$findings" ] && return 0
	{
		echo "BLOCK: $display — bash 4.0+ features used with \`#!/bin/bash\` shebang (macOS ships bash 3.2)"
		echo "$findings"
		echo ""
		echo '  Fix: change shebang to `#!/usr/bin/env bash` (or `#!/opt/homebrew/bin/bash`)'
		echo "  so Homebrew's bash 5.x is used. Alternatively, rewrite to avoid the 4.0+"
		printf '%s\n' "  features (e.g. \`mapfile -d ''\` → \`tr '\\0' '\\n' | while IFS= read -r\`)."
	} >&2
	return 1
}

bash4_features_check_file() {
	local path="${1:-}" content
	[ -f "$path" ] || return 0
	# Capture cat's exit status explicitly — `$(cat "$path")` failure
	# previously fell through with empty content, silently passing the
	# check even though the file was unreadable (permissions, race, etc).
	# Fail-closed per the v4.24 enforcement model.
	if ! content=$(cat "$path" 2>/dev/null); then
		echo "BLOCK: $path — unable to read file (permissions? race?)" >&2
		return 1
	fi
	bash4_features_check_content "$path" "$content"
}
