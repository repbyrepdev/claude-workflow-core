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
#
# Args: $1 = display-name, $2 = content.
# Returns 0 if safe, 1 if refused (emits BLOCK message on stderr).

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
	local findings=""
	body=$(printf '%s' "$content")
	# mapfile -d / readarray -d (bash 4.4)
	if printf '%s' "$body" | grep -Eq '^[[:space:]]*(mapfile|readarray)[[:space:]]+-[a-z]*d[a-z]*\b'; then
		findings="${findings:+$findings
}  - mapfile -d / readarray -d (bash 4.4) — CR autofix favorite, silently fails on /bin/bash 3.2"
	fi
	# shopt -s globstar (bash 4.0)
	if printf '%s' "$body" | grep -Eq '^[[:space:]]*shopt[[:space:]]+-s[[:space:]]+globstar'; then
		findings="${findings:+$findings
}  - shopt -s globstar (bash 4.0)"
	fi
	# declare -A / typeset -A (bash 4.0)
	if printf '%s' "$body" | grep -Eq '^[[:space:]]*(declare|typeset)[[:space:]]+-[a-zA-Z]*A'; then
		findings="${findings:+$findings
}  - declare -A / typeset -A (bash 4.0 associative arrays)"
	fi
	# Case transforms ${var^^} ${var,,} etc. (bash 4.0). The optional
	# `(\[[^]]+\])?` catches array-element forms like ${arr[0]^^} or
	# ${arr[$i],,} (v4.24-Q2 #608 CR finding).
	if printf '%s' "$body" | grep -Eq '\$\{[a-zA-Z_][a-zA-Z0-9_]*(\[[^]]+\])?(\^\^|,,|\^|,)[^}]*\}'; then
		findings="${findings:+$findings
}  - \${var^^}/\${var,,} case transforms (bash 4.0)"
	fi
	# readarray builtin (any form — bash 4.0). The -d sub-case is ALSO
	# covered by the earlier mapfile|readarray -d rule (bash 4.4); the
	# intentional double-match is fine because both point at the same
	# fix. Prior regex `readarray\b([^-]|$)` was clever-but-fragile;
	# matching bare `^[[:space:]]*readarray\b` catches all forms
	# (`readarray arr`, `readarray -t arr`, `readarray -d '' arr`, etc.).
	if printf '%s' "$body" | grep -Eq '^[[:space:]]*readarray\b'; then
		findings="${findings:+$findings
}  - readarray (bash 4.0)"
	fi
	# &>> append-both-streams redirect (bash 4.0). v4.24-Q2 #609 gap fix.
	# Strip comment-only lines before scanning so `# see &>> usage` doesn't
	# false-match (CR round 10 finding). The sed removes lines whose first
	# non-whitespace char is `#`. Keeps shebang (# on line 1) — it starts
	# with `#!` which the regex still matches harmlessly since we only
	# care about `&>>` elsewhere.
	if printf '%s' "$body" | sed '/^[[:space:]]*#/d' | grep -Eq '&>>[[:space:]]*[^[:space:]]'; then
		findings="${findings:+$findings
}  - &>> append-both-streams redirect (bash 4.0)"
	fi
	[ -z "$findings" ] && return 0
	{
		echo "BLOCK: $display — bash 4.0+ features used with \`#!/bin/bash\` shebang (macOS ships bash 3.2)"
		echo "$findings"
		echo ""
		echo "  Fix: change shebang to \`#!/usr/bin/env bash\` (or \`#!/opt/homebrew/bin/bash\`)"
		echo "  so Homebrew's bash 5.x is used. Alternatively, rewrite to avoid the 4.0+"
		echo "  features (e.g. \`mapfile -d ''\` → \`tr '\\0' '\\n' | while IFS= read -r\`)."
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
