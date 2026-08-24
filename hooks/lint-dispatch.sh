#!/bin/bash
set -u
# event: PostToolUse
# matcher: Edit|Write|MultiEdit
# enforcement: enforce — every lint failure/auto-fix routes through hook_ack_append (via _lint_pending_append)
# v4.26 (#627) — unified PostToolUse linter dispatcher.
# Replaces the prior 3-hook fan-out (lint-yaml.sh + lint-shell.sh +
# lint-actions.sh), which spawned 3 bash subprocesses per Edit/Write
# call where 2 of 3 always early-exit on extension mismatch.
# This dispatcher spawns once, picks the linter by extension + path,
# then delegates the same lint-log-append + advisory-stderr behavior.
#
# Drift guard: the reason-string list below (v4.28-W3-C block) is the
# SINGLE enumeration of ack-routing call sites — bats `lint-dispatch
# .bats` pins every arm except shellcheck-CRASH, which needs an input
# that crashes the linter itself (#2574; exercised only in production).
# (#2547 — the prior comment claimed full coverage for 20+ versions
# while no bats existed; r8 caught THIS header keeping a second,
# already-diverged copy of the same list.) New file type: add a `case`
# arm + a bats test + a reason-string entry, and keep `# enforcement:`
# honest (event-frontmatter-check.sh gates its presence at commit;
# .claude/tests/_lib/event-frontmatter-audit.bats audits the routing).
#
# Registered via ~/.claude/settings.json hooks.PostToolUse matcher=
# Edit|Write|MultiEdit (ONE entry replacing the prior 3).

# shellcheck source=/dev/null
source "$(dirname "$0")/_otel-silence.sh"
# shellcheck disable=SC2034  # REPO_ROOT may be referenced by sourced libs

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=../_lib/lint-log.sh
source "$(dirname "$0")/../_lib/lint-log.sh"
# v4.28-W3-C: hook-ack helper for the universal acknowledgment sentinel.
# shellcheck source=../_lib/hook-ack.sh
[ -f "$(dirname "$0")/../_lib/hook-ack.sh" ] && source "$(dirname "$0")/../_lib/hook-ack.sh"

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

if [ -z "${FILE:-}" ]; then
	exit 0
fi

# v4.28-W3-C: delegate to the universal hook-ack helper. Each lint
# outcome that requires operator eyes appends to the sentinel — concrete
# reason strings used by current call sites:
#   - shellcheck: "fail-N-issues"      (linter found issues)
#   - shellcheck: "crashed-upstream-bug" (linter itself crashed; the one
#     arm without a bats pin — #2574)
#   - shfmt:      "auto-fixed"         (shfmt -w rewrote the file)
#   - shfmt:      "auto-fix-failed"    (shfmt -d showed drift but -w failed)
#   - actionlint: "fail-N-issues"
#   - yamllint:   "fail-N-issues"
# All variants block the next Bash/Edit/etc. until the operator Reads
# the file. Cleared by .claude/hooks/hook-ack-clear.sh on Read.
_lint_pending_append() {
	# $1 = file, $2 = linter, $3 = reason
	if command -v hook_ack_append >/dev/null 2>&1; then
		hook_ack_append "lint-dispatch.$2" "$3" "$1"
	fi
}

# ---- Dispatch ----
# Path order matters: actions workflows are *.yml, so the workflow check
# must run BEFORE the generic yaml branch.
case "$FILE" in
*.github/workflows/*.yml | *.github/workflows/*.yaml)
	if command -v actionlint >/dev/null 2>&1 && [ -f "$FILE" ]; then
		if RESULT=$(actionlint "$FILE" 2>&1); then
			lint_log_append "$FILE" "actionlint" "pass" 0 ""
		else
			issues=$(printf '%s\n' "$RESULT" | grep -cE ':[0-9]+:[0-9]+:' || echo "1")
			lint_log_append "$FILE" "actionlint" "fail" "${issues:-1}" "$(printf '%s' "$RESULT" | head -3 | tr '\n' ' ')"
			_lint_pending_append "$FILE" "actionlint" "fail-${issues:-1}-issues"
			echo "$RESULT"
			echo '{"additionalContext": "actionlint found issues in the workflow you just edited — lint-gate will block commit/test/push until fixed. Fix now, same-turn."}'
			# v4.26 #627 consolidation: standardize on exit-non-zero across
			# all linter branches (was advisory-only in the prior split
			# lint-actions.sh; consolidating raises the bar to match yamllint).
			exit 1
		fi
	fi
	;;
*.yml | *.yaml)
	if command -v yamllint >/dev/null 2>&1 && [ -f "$FILE" ]; then
		# Config: .yamllint.yaml SSOT at repo root (v4.24-O #601).
		RESULT=$(yamllint "$FILE" 2>&1)
		LINT_EXIT=$?
		if [ "$LINT_EXIT" -eq 0 ]; then
			lint_log_append "$FILE" "yamllint" "pass" 0 ""
		else
			issues=$(printf '%s\n' "$RESULT" | grep -cE '^[[:space:]]+[0-9]+:[0-9]+' || echo "1")
			lint_log_append "$FILE" "yamllint" "fail" "${issues:-1}" "$(printf '%s' "$RESULT" | head -3 | tr '\n' ' ')"
			_lint_pending_append "$FILE" "yamllint" "fail-${issues:-1}-issues"
			echo "$RESULT"
			echo '{"additionalContext": "yamllint found issues in the file you just edited — lint-gate will block commit/test/push until fixed. Fix now, same-turn."}'
			exit "$LINT_EXIT"
		fi
	fi
	;;
*.sh | *.bats)
	if [ -f "$FILE" ]; then
		ISSUES=""
		if command -v shellcheck >/dev/null 2>&1; then
			# v0.8.1 (#55): capture rc + output separately so we can
			# distinguish: rc=0 clean / rc!=0-with-findings / rc!=0-CRASH.
			# Prior `if SC=$(shellcheck ...)` treated a shellcheck CRASH
			# (Haskell exception "Non-exhaustive patterns in checkCmd")
			# as "fail" then grepped for "^In .*line" which matches 0 →
			# logged as "fail-0-issues" giving operators a sentinel they
			# can't resolve.
			SC=$(shellcheck -S warning "$FILE" 2>&1)
			sc_rc=$?
			if [ "$sc_rc" -eq 0 ]; then
				lint_log_append "$FILE" "shellcheck" "pass" 0 ""
			elif printf '%s\n' "$SC" | grep -qE "Uncaught exception|Non-exhaustive patterns|HasCallStack backtrace"; then
				# Shellcheck itself crashed — log as "skip" so the gate
				# distinguishes "linter broken" from "code has issues".
				# Emit stderr breadcrumb naming the actual exception so
				# the operator has actionable detail (and can file an
				# upstream bug against the linter if needed).
				echo "lint-dispatch: shellcheck CRASHED on $FILE — Haskell exception (likely upstream bug):" >&2
				printf '%s\n' "$SC" | head -5 | sed 's/^/    /' >&2
				echo "  Workaround: file an upstream linter issue + try rewriting the offending pattern. lint-gate treats this as 'skip' (not fail) so commits aren't blocked indefinitely." >&2
				lint_log_append "$FILE" "shellcheck" "skip" 0 "shellcheck crashed (Haskell exception) — likely upstream bug"
				_lint_pending_append "$FILE" "shellcheck" "crashed-upstream-bug"
			else
				sc_count=$(printf '%s\n' "$SC" | grep -cE '^In .*line [0-9]+:' || echo "1")
				lint_log_append "$FILE" "shellcheck" "fail" "${sc_count:-1}" "$(printf '%s' "$SC" | head -3 | tr '\n' ' ')"
				_lint_pending_append "$FILE" "shellcheck" "fail-${sc_count:-1}-issues"
				ISSUES="$ISSUES\nShellCheck:\n$SC"
			fi
		fi
		if command -v shfmt >/dev/null 2>&1; then
			DIFF=$(shfmt -d "$FILE" 2>&1)
			if [ -z "$DIFF" ]; then
				lint_log_append "$FILE" "shfmt" "pass" 0 ""
			else
				# v4.28-W3-C (#676): auto-apply shfmt -w instead of just
				# reporting drift. Stops the recurrence where the same
				# style mistake (e.g. line-continuation `\` instead of
				# trailing `||`) lands in PR after PR. Auto-fix is safe
				# because shfmt -w is bit-for-bit deterministic + only
				# rewrites whitespace/structure, never logic. The pre-fix
				# diff goes to stderr so the operator sees what changed
				# (and can revert if needed via git).
				if shfmt -w "$FILE" 2>/dev/null; then
					echo "lint-dispatch: shfmt auto-fixed formatting in $FILE" >&2
					echo "  pre-fix diff (for review):" >&2
					printf '%s\n' "$DIFF" | sed 's/^/    /' >&2
					lint_log_append "$FILE" "shfmt" "pass" 0 "auto-fixed via shfmt -w"
					# v4.28-W3-C: file on disk changed under the operator.
					# Acknowledge-pending sentinel blocks next Bash/Edit
					# until operator Reads the file. Cleared by hook-ack-
					# clear.sh on PostToolUse Read.
					_lint_pending_append "$FILE" "shfmt" "auto-fixed"
				else
					# shfmt -w failed (e.g. file became unwritable mid-run).
					# Fall back to the prior advisory behavior so the gate
					# sees fail + the operator gets the diff.
					lint_log_append "$FILE" "shfmt" "fail" 1 "formatting diff present — shfmt -w failed; run manually"
					_lint_pending_append "$FILE" "shfmt" "auto-fix-failed"
					ISSUES="$ISSUES\nshfmt formatting diff (auto-fix failed):\n$DIFF"
				fi
			fi
		fi
		if [ -n "$ISSUES" ]; then
			# `printf '%b'` interprets escape sequences portably; `echo -e`
			# is non-portable across bash/sh.
			printf '%b\n' "$ISSUES"
			echo '{"additionalContext": "shellcheck/shfmt found issues in the shell script you just edited — lint-gate will block commit/test/push until fixed. Fix now, same-turn."}'
			# v4.26 #627 consolidation: standardize on exit-non-zero (was
			# advisory-only in prior split lint-shell.sh).
			exit 1
		fi
	fi
	;;
esac

exit 0
