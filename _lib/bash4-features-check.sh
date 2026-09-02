#!/bin/bash
set -u
# v4.24-P (#603) — shared detector for bash 4.0+ features in shell scripts.
# Used by:
#   - .claude/pre-commit-hooks/bash4-features-check.sh (commit gate)
#   - .claude/hooks/bash4-features-write-guard.sh (PreToolUse Write gate)
#
# Rule: if any bash 4.0+ feature is used AND the shebang is plain
# `#!/bin/bash`, REFUSE. macOS ships /bin/bash 3.2 (Apple licensing); the
# feature will silently fail at runtime. Require `#!/usr/bin/env bash` or
# `#!/opt/homebrew/bin/bash` (which resolve to Homebrew's 5.x).
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
#   `readarray` builtin              — bash 4.0
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
# Args: $1 = display-name, $2 = content.
# Returns 0 if safe, 1 if refused (emits BLOCK message on stderr).

# _b4_waived <key> — rc 0 when the scanned file carries a VALID waiver
# comment for <key>: `# bash4-waiver: <key> <reason containing a letter>`.
# Reads the caller's $content via bash dynamic scoping (only ever called
# from bash4_features_check_content). A reasonless or unknown-key waiver
# does NOT suppress — the caller's post-scan reports it as a finding.
_b4_waived() {
	printf '%s' "${content:-}" | grep -Eq "^[[:space:]]*#[[:space:]]*bash4-waiver:[[:space:]]*${1}[[:space:]]+[^[:space:]].*[A-Za-z]"
}

bash4_features_check_content() {
	local display="${1:-}" content="${2:-}" body shebang
	[ -n "$display" ] && [ -n "$content" ] || return 0
	# Extract shebang (first line).
	shebang=$(printf '%s' "$content" | head -1)
	# Check if shebang is the bash-3-unsafe form.
	local unsafe_shebang=0
	case "$shebang" in
	"#!/bin/bash" | "#!/bin/bash "*) unsafe_shebang=1 ;;
	esac
	[ "$unsafe_shebang" = "1" ] || return 0
	# Detect features. Using grep -E so the regex set is explicit + auditable.
	# Comment-line stripping is hoisted here for ALL detectors (#2645): the
	# sed removes lines whose first non-whitespace char is `#`. The shebang
	# (line 1, `#!`) goes too — irrelevant, no detector targets it. Prior to
	# this hoist only the &>> rule stripped comments, and three shipped files
	# false-positived on comment PROSE mentioning the very feature their code
	# avoids (scripts/test.sh, skills/_lib/skill-common.sh, phase1-launcher).
	local findings=""
	body=$(printf '%s' "$content" | sed '/^[[:space:]]*#/d')
	# Builtin-keyword rules share the boundary prefix (^|[;{()&|])[[:space:]]*
	# instead of line-start only (#2645): real code writes `f() { declare -n
	# ref=$1; }` or `x) mapfile -d ...` — the old ^-anchor missed every
	# inline-body use. The control-char class keeps prose in strings from
	# matching (the feature word must directly follow ; { ( ) & | or start
	# the line).
	#
	# Deliberate, guarded use gets a WAIVER, not a path exemption (#2645):
	# a comment line `# bash4-waiver: <key> — <reason>` suppresses exactly
	# that detector for the file. The reason is MANDATORY — a bare key does
	# not suppress and is itself reported as malformed, as is an unknown
	# key (typo insurance). Keys: mapfile-d globstar assoc case-transform
	# readarray append-redirect fallthrough coproc declare-g nameref
	# neg-subscript param-transform. Anchor case: phase1-launcher's
	# `shopt -s globstar` — saved/restored, `|| true`-guarded, documented
	# 3.2 degradation.
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*(mapfile|readarray)[[:space:]]+-[a-z]*d[a-z]*\b' && ! _b4_waived mapfile-d; then
		findings="${findings:+$findings
}  - mapfile -d / readarray -d (bash 4.4) — CR autofix favorite, silently fails on /bin/bash 3.2"
	fi
	# shopt -s globstar (bash 4.0)
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*shopt[[:space:]]+-s[[:space:]]+globstar' && ! _b4_waived globstar; then
		findings="${findings:+$findings
}  - shopt -s globstar (bash 4.0)"
	fi
	# declare -A / typeset -A (bash 4.0)
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*(declare|typeset)[[:space:]]+-[a-zA-Z]*A' && ! _b4_waived assoc; then
		findings="${findings:+$findings
}  - declare -A / typeset -A (bash 4.0 associative arrays)"
	fi
	# Case transforms ${var^^} ${var,,} etc. (bash 4.0). The optional
	# `(\[[^]]+\])?` catches array-element forms like ${arr[0]^^} or
	# ${arr[$i],,} (v4.24-Q2 #608 CR finding).
	if printf '%s' "$body" | grep -Eq '\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]+\])?(\^\^|,,|\^|,)[^}]*\}' && ! _b4_waived case-transform; then
		findings="${findings:+$findings
}  - \${var^^}/\${var,,} case transforms (bash 4.0)"
	fi
	# readarray builtin (any form — bash 4.0). The -d sub-case is ALSO
	# covered by the earlier mapfile|readarray -d rule (bash 4.4); the
	# intentional double-match is fine because both point at the same fix.
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*readarray\b' && ! _b4_waived readarray; then
		findings="${findings:+$findings
}  - readarray (bash 4.0)"
	fi
	# &>> append-both-streams redirect (bash 4.0). v4.24-Q2 #609 gap fix.
	# (Comment stripping now happens once, above, for every detector.)
	if printf '%s' "$body" | grep -Eq '&>>[[:space:]]*[^[:space:]]' && ! _b4_waived append-redirect; then
		findings="${findings:+$findings
}  - &>> append-both-streams redirect (bash 4.0)"
	fi
	# ;& and ;;& case-branch terminators (bash 4.0). On 3.2 these are PARSE
	# errors — the whole script dies before running a single line, which is
	# the worst failure mode this gate exists for (#2645; hit by hand in
	# #2641). Delimiter-anchored so `cmd; & sleep` (legal 3.2: `;` then a
	# background `&`) and `2>&1;` never match — the token must be contiguous.
	if printf '%s' "$body" | grep -Eq '(^|[[:space:]]);;?&([[:space:]]|$)' && ! _b4_waived fallthrough; then
		findings="${findings:+$findings
}  - ;& / ;;& case fall-through terminators (bash 4.0 — PARSE error on 3.2)"
	fi
	# coproc keyword (bash 4.0).
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*coproc\b' && ! _b4_waived coproc; then
		findings="${findings:+$findings
}  - coproc (bash 4.0)"
	fi
	# declare/typeset -g global-scope flag (bash 4.2).
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*(declare|typeset)[[:space:]]+-[a-zA-Z]*g' && ! _b4_waived declare-g; then
		findings="${findings:+$findings
}  - declare -g / typeset -g (bash 4.2)"
	fi
	# declare/typeset/local -n namerefs (bash 4.3). The `n` must sit inside
	# the flag cluster itself (`-n`, `-in`, `-rn`); a separate variable that
	# happens to be named n (`local -i n=5`) does not match.
	if printf '%s' "$body" | grep -Eq '(^|[;{()&|])[[:space:]]*(declare|typeset|local)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*\b' && ! _b4_waived nameref; then
		findings="${findings:+$findings
}  - declare -n / local -n namerefs (bash 4.3)"
	fi
	# Negative array subscripts ${arr[-1]} / ${#arr[-1]} (bash 4.3). `:-`
	# default-expansion never matches — the `[` is required before the `-`.
	if printf '%s' "$body" | grep -Eq '\$\{[#!]?[a-zA-Z_][a-zA-Z0-9_]*\[[[:space:]]*-[0-9]' && ! _b4_waived neg-subscript; then
		findings="${findings:+$findings
}  - \${arr[-1]} negative array subscripts (bash 4.3)"
	fi
	# ${var@Q}-style parameter transformations (bash 4.4; U/u/L are 5.1).
	if printf '%s' "$body" | grep -Eq '\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]+\])?@[QEPAKakULu]\}' && ! _b4_waived param-transform; then
		findings="${findings:+$findings
}  - \${var@Q} parameter transforms (bash 4.4+)"
	fi
	# Malformed / unknown waivers are FINDINGS themselves — a typo'd key must
	# not silently fail to suppress (the operator believes they are covered),
	# and a reasonless waiver is an unaudited bypass. Scans the ORIGINAL
	# content (waivers live on comment lines, which $body no longer has).
	local _wline _wkey
	while IFS= read -r _wline; do
		[ -n "$_wline" ] || continue
		_wkey=$(printf '%s' "$_wline" | sed -E 's/^[[:space:]]*#[[:space:]]*bash4-waiver:[[:space:]]*//; s/[[:space:]].*$//')
		case "$_wkey" in
		mapfile-d | globstar | assoc | case-transform | readarray | append-redirect | fallthrough | coproc | declare-g | nameref | neg-subscript | param-transform)
			printf '%s' "$_wline" | grep -Eq "bash4-waiver:[[:space:]]*${_wkey}[[:space:]]+[^[:space:]].*[A-Za-z]" || findings="${findings:+$findings
}  - bash4-waiver '${_wkey}' has NO reason — a reason is mandatory, waiver ignored"
			;;
		*)
			findings="${findings:+$findings
}  - unknown bash4-waiver key '${_wkey}' — valid keys: mapfile-d globstar assoc case-transform readarray append-redirect fallthrough coproc declare-g nameref neg-subscript param-transform"
			;;
		esac
	done < <(printf '%s' "$content" | grep -E '^[[:space:]]*#[[:space:]]*bash4-waiver:' 2>/dev/null)
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
