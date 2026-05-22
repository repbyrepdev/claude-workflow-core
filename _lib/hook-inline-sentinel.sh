#!/bin/bash
set -u
# v4.24-Q (#604) — shared inline-sentinel bypass helper for PreToolUse
# Bash hooks. PreToolUse hooks inherit Claude's session env, NOT the
# command's env — so `FOO_SKIP=1 git commit …` sets FOO_SKIP for git's
# subshell but is invisible to the hook. This helper detects the literal
# `<PREFIX>_SKIP=1` substring in the command string, extracts an optional
# `<PREFIX>_SKIP_REASON="..."`, writes an audit-log entry, and returns
# 0 if the bypass applies (caller should then `exit 0`).
#
# Usage:
#   source .claude/_lib/hook-inline-sentinel.sh
#   if hook_inline_sentinel_check "LINT_GATE_SKIP" "$CMD" "lint-gate (bash)"; then
#     exit 0  # bypass fired
#   fi
#
# Args:
#   $1 = prefix (e.g. LINT_GATE_SKIP, ISSUE_BEFORE_CODE_SKIP)
#   $2 = full command string ($CMD)
#   $3 = label for the audit log and stderr message
# Log path: .claude/logs/<lowercase-prefix>.jsonl
# Returns 0 if sentinel detected (caller should exit 0), 1 otherwise.

hook_inline_sentinel_check() {
	# Split local declarations — `local a=$1 b=${2:-$a}` evaluates right-
	# side while `a` is still "declaring" under `set -u`, tripping an
	# unbound-variable error on some bash versions.
	local prefix="${1:-}"
	local cmd="${2:-}"
	local label="${3:-$prefix}"
	[ -n "$prefix" ] && [ -n "$cmd" ] || return 1
	# v4.24-Q2 CR finding: restrict sentinel match to the LEADING env-
	# assignment preamble (zero or more `VAR=val` pairs before the actual
	# command word). Prior glob `*"${prefix}=1"*` matched anywhere —
	# `git commit -m "LINT_GATE_SKIP=1"` would have bypassed the gate
	# via commit-message text.
	#
	# Extract the preamble. Each token is `IDENT=VALUE`, where VALUE is
	# either a double-quoted string (may contain spaces) or whitespace-
	# delimited. Loop terminates on the first non-assignment token.
	local preamble="" rest="$cmd" token ident value
	while :; do
		# Strip leading whitespace.
		rest="${rest#"${rest%%[![:space:]]*}"}"
		# Token must start with IDENT= where IDENT = [A-Za-z_][A-Za-z0-9_]*.
		case "$rest" in
		[A-Za-z_]*=*) ;;
		*) break ;;
		esac
		# Split at first `=`.
		ident="${rest%%=*}"
		value="${rest#*=}"
		# Case a: quoted value `"..."` — take up through the closing quote.
		# Case b: unquoted — take up to the first whitespace.
		case "$value" in
		\"*)
			# Quoted: find closing quote. Use a temp expansion to stop at `"`.
			value="\"${value#\"}"     # restore leading `"`
			local tail="${value#\"}"  # string after opening `"`
			local body="${tail%%\"*}" # up to next `"`
			token="${ident}=\"${body}\""
			# Advance past the closing quote.
			rest="${rest#"$token"}"
			;;
		*)
			token="${rest%%[[:space:]]*}"
			rest="${rest#"$token"}"
			;;
		esac
		preamble="$preamble $token"
	done
	case "$preamble" in
	*" ${prefix}=1"*) ;;
	*) return 1 ;;
	esac
	local reason="" repo_root log
	# Explicit `|| true` on the pipeline: grep returns non-zero when no
	# match (i.e. no `_REASON=...` in the preamble), which would abort
	# the function under set -o pipefail (some callers set it). Keep
	# reason="" in that case.
	reason=$(printf '%s\n' "$preamble" | grep -oE "${prefix}_REASON=(\"[^\"]*\"|[^[:space:]]+)" | head -1 | sed -E "s/^${prefix}_REASON=//;s/^\"//;s/\"$//" || true)
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	if [ -n "$repo_root" ] && command -v jq >/dev/null 2>&1; then
		# Derive log filename from prefix — lowercase + _skip → -skip.jsonl
		log_name=$(printf '%s' "$prefix" | tr '[:upper:]_' '[:lower:]-')
		log="$repo_root/.claude/logs/${log_name}.jsonl"
		mkdir -p "$(dirname "$log")" 2>/dev/null || true
		jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg cmd "${cmd:0:200}" \
			--arg reason "${reason:-<no reason>}" \
			--arg label "$label" \
			'{ts:$ts, label:$label, reason:$reason, cmd_preview:$cmd}' \
			>>"$log" 2>/dev/null || true
	fi
	echo "$label: inline $prefix=1 — bypassing (reason: ${reason:-<none>})" >&2
	return 0
}
