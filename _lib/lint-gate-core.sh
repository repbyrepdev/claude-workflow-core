#!/bin/bash
set -u
# v4.24-O (#601) — shared lint-gate core.
# Used by BOTH:
#   - .claude/pre-commit-hooks/lint-gate.sh (commit-time gate, staged files)
#   - .claude/hooks/lint-gate-bash.sh       (PreToolUse Bash gate, tracked files)
# One rule, two gate contexts.
#
# Responsibility: given a list of file paths, check each one's current
# content-hash against .claude/logs/lint-run.jsonl for every linter that
# applies to the file type. Report FAIL on (a) latest entry per (file, hash,
# linter) shows status=fail, OR (b) no entry exists at current hash (unknown).
# Bypass via LINT_GATE_SKIP=1 + LINT_GATE_SKIP_REASON="…" (logged to
# .claude/logs/lint-gate-skip.jsonl).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=lint-log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lint-log.sh"

# Which linters apply to a given file path? Echoes space-separated list.
# Empty output = no applicable linters → file is not gated.
_lint_linters_for() {
	local path=$1
	case "$path" in
	*.sh | *.bats)
		# .bats files are bash scripts (bash-based harness). The upstream
		# pre-commit shellcheck-py hook does NOT pick them up by default
		# (the identify library tags `#!/usr/bin/env bats` as 'bats', not
		# 'shell'), so explicit dispatch here is required to cover them.
		# Same gate semantics as .sh to prevent the edit/commit/fix/retry
		# loop where a .bats file slips past the PreToolUse Bash gate.
		echo "shellcheck shfmt"
		;;
	.github/workflows/*.yml | .github/workflows/*.yaml)
		echo "yamllint actionlint"
		;;
	*.yml | *.yaml)
		echo "yamllint"
		;;
	*) echo "" ;;
	esac
}

# Invoke the linters NOW on a single file and append results to the log.
# This is the "run-on-miss" path — the gate calls it when no entry exists
# at the current hash so the gate doesn't block indefinitely on files that
# haven't been touched by the post-edit hooks.
#
# FAIL-CLOSED on missing binary: when the linter isn't installed, log a
# fail entry with an actionable install hint + emit stderr. Prior behavior
# (silently skip) masqueraded as "unknown" in the gate with no diagnostic.
_lint_run_on_miss() {
	local file=$1 linter=$2 out count
	case "$linter" in
	shellcheck)
		if ! command -v shellcheck >/dev/null 2>&1; then
			echo "lint-gate: shellcheck not installed — run: brew install shellcheck" >&2
			lint_log_append "$file" shellcheck fail 1 "shellcheck binary missing — install: brew install shellcheck"
			return
		fi
		if out=$(shellcheck -S warning "$file" 2>&1); then
			lint_log_append "$file" shellcheck pass 0 ""
		else
			count=$(printf '%s\n' "$out" | grep -cE '^In .*line [0-9]+:' || echo "1")
			lint_log_append "$file" shellcheck fail "${count:-1}" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
		fi
		;;
	shfmt)
		if ! command -v shfmt >/dev/null 2>&1; then
			echo "lint-gate: shfmt not installed — run: brew install shfmt" >&2
			lint_log_append "$file" shfmt fail 1 "shfmt binary missing — install: brew install shfmt"
			return
		fi
		local diff_out
		diff_out=$(shfmt -d "$file" 2>&1)
		if [ -z "$diff_out" ]; then
			lint_log_append "$file" shfmt pass 0 ""
		else
			lint_log_append "$file" shfmt fail 1 "formatting diff — run shfmt -w $file"
		fi
		;;
	yamllint)
		if ! command -v yamllint >/dev/null 2>&1; then
			echo "lint-gate: yamllint not installed — run: brew install yamllint" >&2
			lint_log_append "$file" yamllint fail 1 "yamllint binary missing — install: brew install yamllint"
			return
		fi
		# Single invocation captures output + exit status — matches the
		# ShellCheck branch. Prior form invoked yamllint twice (once for
		# status, once for output) on every miss.
		# Config: yamllint auto-discovers .yamllint.yaml at repo root
		# (v4.24-O #601 SSOT) — no inline -d flag needed.
		if out=$(yamllint "$file" 2>&1); then
			lint_log_append "$file" yamllint pass 0 ""
		else
			count=$(printf '%s\n' "$out" | grep -cE '^[[:space:]]+[0-9]+:[0-9]+' || echo "1")
			lint_log_append "$file" yamllint fail "${count:-1}" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
		fi
		;;
	actionlint)
		if ! command -v actionlint >/dev/null 2>&1; then
			echo "lint-gate: actionlint not installed — run: brew install actionlint" >&2
			lint_log_append "$file" actionlint fail 1 "actionlint binary missing — install: brew install actionlint"
			return
		fi
		if out=$(actionlint "$file" 2>&1); then
			lint_log_append "$file" actionlint pass 0 ""
		else
			count=$(printf '%s\n' "$out" | grep -cE ':[0-9]+:[0-9]+:' || echo "1")
			lint_log_append "$file" actionlint fail "${count:-1}" "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
		fi
		;;
	esac
}

# Check each (file, linter) tuple. FAIL = non-pass (fail or unknown post-run).
# Args: newline-separated list of files on stdin.
# Stdout: blank on pass, violation summary on fail.
# Exit: 0 = all pass, 1 = at least one fail.
lint_gate_check_files() {
	local fails=0
	local line file linters lin verdict
	while IFS= read -r line; do
		file=$line
		[ -z "$file" ] && continue
		[ -f "$file" ] || continue
		linters=$(_lint_linters_for "$file")
		[ -z "$linters" ] && continue
		for lin in $linters; do
			verdict=$(lint_log_verdict "$file" "$lin")
			if [ "$verdict" = "unknown" ]; then
				# Run the linter now + re-check.
				_lint_run_on_miss "$file" "$lin"
				verdict=$(lint_log_verdict "$file" "$lin")
			fi
			if [ "$verdict" != "pass" ]; then
				echo "  ✗ $file ($lin): $verdict"
				fails=$((fails + 1))
			fi
		done
	done
	if [ "$fails" -gt 0 ]; then
		return 1
	fi
	return 0
}

# Full entry point used by both gate wrappers. Writes bypass log when used.
# Args: label (for the gate message), newline-separated files on stdin.
lint_gate_run() {
	local label="${1:-lint-gate}"
	# Bypass.
	if [ "${LINT_GATE_SKIP:-0}" = "1" ]; then
		local reason="${LINT_GATE_SKIP_REASON:-}"
		if [ -z "$reason" ]; then
			echo "$label: LINT_GATE_SKIP=1 requires LINT_GATE_SKIP_REASON=\"<text>\"" >&2
			return 2
		fi
		local skip_log="$REPO_ROOT/.claude/logs/lint-gate-skip.jsonl"
		mkdir -p "$(dirname "$skip_log")" 2>/dev/null || true
		jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			--arg reason "$reason" --arg label "$label" \
			'{ts:$ts, label:$label, reason:$reason}' \
			>>"$skip_log" 2>/dev/null || true
		echo "$label: LINT_GATE_SKIP=1 — bypassing (reason: $reason)" >&2
		return 0
	fi
	local report
	report=$(lint_gate_check_files) || {
		echo "" >&2
		echo "$label: BLOCK — tracked files have lint issues at current content hash:" >&2
		printf '%s\n' "$report" >&2
		echo "" >&2
		echo "→ Fix the flagged files and re-save (lint-shell/yaml/actions PostToolUse hooks re-log)." >&2
		echo "→ Emergency bypass: LINT_GATE_SKIP=1 LINT_GATE_SKIP_REASON=\"<text>\" <cmd>" >&2
		return 1
	}
	return 0
}
