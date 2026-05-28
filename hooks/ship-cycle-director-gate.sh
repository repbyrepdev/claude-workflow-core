#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# auto-register: true
# v0.8.4 (#63) — ship-pr-cycle director-gate.
#
# Refuses workflow-critical Bash commands unless the current ship-pr-cycle
# stage permits them. Forces operator to call `ship-pr-cycle.sh next` so
# the cycle remains the single director of every transition.
#
# Why: operator (Claude) repeatedly fired `coderabbit review`, `git push`,
# `gh pr merge`, and Phase 1 agents WITHOUT first asking the cycle what
# stage allowed them. Burned 4+ hours + 3+ CR-budget cycles on a single-
# line pin-bump PR (FCP #59 dogfood, 2026-05). The cycle's directive
# surfacing was ambiguous (CONVERGED signal buried by boilerplate);
# a PreToolUse refusal is the only reliable enforcement.
#
# Refusal patterns + graduation-aware behavior:
#
#   COMMAND PATTERN              | not-graduated     | graduated
#   coderabbit review            | REFUSE            | OK at stage=phase2
#   scripts/cr/local-review.sh   | REFUSE            | OK at stage=phase2
#   git push                     | REFUSE            | OK at stage=push
#   gh pr merge                  | REFUSE            | OK at stage=merge-gate
#
# Other commands (git commit, agent invocations, etc.) are not matched
# by the case statement below and exit silently rc=0. The decision-matrix
# stops here — substring match, not word-boundary, so `echo 'git push docs'`
# would also trigger; the trade-off is acceptable because PreToolUse only
# fires on actual command invocations, not file contents.
#
# Refusal stderr ALWAYS quotes the literal directive:
#   Run `.claude/skills/ship-pr-cycle/run.sh next` first.
#
# Bypasses (both audit-logged to .claude/logs/ship-cycle-gate-skip.jsonl
# with the bypassed command captured):
#   - SHIP_CYCLE_GATE_SKIP=1 — emergency override
#   - SKILL_WRAPPER=1 — sanctioned skill-internal invocation
#
# Fail-open chosen for: jq missing, malformed PreToolUse stdin, git failure.
# Rationale: a security-adjacent hook that fails CLOSED on infra glitches
# locks the operator out of ALL Bash. Trade-off: fail-open emits an audible
# WARN on stderr so the failure mode is visible, not silent.
#
# Input:  PreToolUse JSON on stdin with .tool_input.command.
# Output: rc=0 to allow; rc=2 + stderr to deny; rc=0 with stderr WARN on
#         infrastructure failure (jq missing, malformed stdin, etc.).

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_DIR="$REPO_ROOT/.claude/logs"
AUDIT_LOG="$LOG_DIR/ship-cycle-gate-skip.jsonl"

# v0.8.4 CR r1 F1/F4 fix: jq-missing check at top level (not inside a
# subshell-invoked function), so `exit 0` actually exits the script.
if ! command -v jq >/dev/null 2>&1; then
	echo "ship-cycle-director-gate: WARN — jq missing, fail-open" >&2
	exit 0
fi

# JSON-line audit log helper. Always emits valid JSONL so consumers
# (memory-consolidate, retro, capture-signal) can jq-walk the file.
_audit() {
	local event="$1" cmd="$2"
	mkdir -p "$LOG_DIR"
	local cmd_json
	cmd_json=$(printf '%s' "$cmd" | jq -Rs . 2>/dev/null || printf '"%s"' "<jq-quote-failed>")
	printf '{"ts":"%s","event":"%s","cmd":%s}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$cmd_json" >>"$AUDIT_LOG"
}

# Read stdin once. jq stderr captured so we can WARN on malformed input
# (the prior fail-silent path would let dangerous commands through with
# no diagnostic).
INPUT=$(cat)
jq_err=$(mktemp -t scgate-jq.XXXXXX) || jq_err="/dev/null"
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>"$jq_err") || {
	[ -s "$jq_err" ] && echo "ship-cycle-director-gate: WARN — malformed PreToolUse JSON (jq err): $(head -c 200 "$jq_err") — fail-open" >&2
	[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
	exit 0
}
[ "$jq_err" != "/dev/null" ] && rm -f "$jq_err"
[ -z "$CMD" ] && exit 0

# Honored bypasses (BOTH audit-logged with command captured, per F6/F7).
if [ "${SHIP_CYCLE_GATE_SKIP:-0}" = "1" ]; then
	_audit "SHIP_CYCLE_GATE_SKIP" "$CMD"
	exit 0
fi
if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	# Sanctioned but still logged so 'why didn't the gate fire' is answerable.
	_audit "SKILL_WRAPPER" "$CMD"
	exit 0
fi

# Detect command category. v0.27.0 #173 Layer 4 (Phase 1 r1 fix): use
# bash `[[ =~ ]]` (string-anchor) instead of `grep -qE` (line-anchor).
# Grep's `^` matches start-of-LINE, so heredoc bodies containing a
# workflow command name on an interior line tripped the gate as a
# false positive. Bash regex matches against the whole string, so `^`
# binds to the actual start of the command text only.
_cmd_starts_with() {
	local cmd=$1 needle=$2
	# Anchored against WHOLE string; optional `K=V` env-var prefixes;
	# `[^[:space:]]*` stops at whitespace (env-var values with quoted
	# internal spaces should be invoked via the matching skill wrapper).
	[[ $cmd =~ ^([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*$needle ]]
}
CATEGORY=""
if _cmd_starts_with "$CMD" "coderabbit review" || _cmd_starts_with "$CMD" "scripts/cr/local-review\.sh" || _cmd_starts_with "$CMD" "\\./scripts/cr/local-review\.sh"; then
	CATEGORY="cr-cli"
elif _cmd_starts_with "$CMD" "gh pr merge"; then
	CATEGORY="merge"
elif _cmd_starts_with "$CMD" "git push"; then
	CATEGORY="push"
else
	exit 0
fi

# Stderr-capture helper used across all subsequent calls. tmpfile fallback
# to /dev/null + audible WARN on mktemp failure (F6 fix — was silently
# falling back to /dev/null which then suppressed every downstream WARN).
# N1 fix — mktemp stderr now leaks to operator's stderr naturally (was
# 2>/dev/null which left the WARN content-less when mktemp failed).
_capture_err_tmp() {
	local prefix="$1" out
	out=$(mktemp -t "$prefix.XXXXXX") || {
		echo "ship-cycle-director-gate: WARN — mktemp for $prefix failed; downstream WARNs will be context-less" >&2
		out="/dev/null"
	}
	printf '%s' "$out"
}

# Stderr-aware WARN: surfaces captured stderr if available, otherwise
# emits an explicit "no stderr captured" so the cascade (mktemp fail +
# downstream op fail) is never silent. N2/N4 fix.
_warn_with_err() {
	local context="$1" err_file="$2"
	if [ -s "$err_file" ]; then
		echo "ship-cycle-director-gate: WARN — ${context}: $(head -c 200 "$err_file")" >&2
	else
		echo "ship-cycle-director-gate: WARN — ${context} (no stderr captured)" >&2
	fi
}

# Resolve current sha. F2 fix — was: bare 2>/dev/null suppressing real
# git errors. CR r2 fix — actually honor fail-open contract: if git
# resolution fails, exit 0 (the documented infra-glitch behavior) rather
# than fall through with empty sha and hit the rc=2 denial path.
sha_err=$(_capture_err_tmp "scgate-sha")
sha=$(git rev-parse HEAD 2>"$sha_err") || {
	_warn_with_err "git rev-parse HEAD failed — fail-open" "$sha_err"
	[ "$sha_err" != "/dev/null" ] && rm -f "$sha_err"
	exit 0
}
[ "$sha_err" != "/dev/null" ] && rm -f "$sha_err"

sf="$REPO_ROOT/.claude/.session-state/ship-cycle/$sha.json"
STAGE=""
if [ -n "$sha" ] && [ -f "$sf" ]; then
	stage_err=$(_capture_err_tmp "scgate-stage")
	STAGE=$(jq -r '.stage // ""' "$sf" 2>"$stage_err") || {
		_warn_with_err "state file $sf unparseable" "$stage_err"
		STAGE=""
	}
	[ "$stage_err" != "/dev/null" ] && rm -f "$stage_err"
fi

# Resolve branch. F3 fix — was: bare 2>/dev/null. CR r2 fix —
# honor fail-open on git failure (exit 0, not continue with empty branch).
branch_err=$(_capture_err_tmp "scgate-branch")
branch=$(git rev-parse --abbrev-ref HEAD 2>"$branch_err") || {
	_warn_with_err "git rev-parse --abbrev-ref HEAD failed — fail-open" "$branch_err"
	[ "$branch_err" != "/dev/null" ] && rm -f "$branch_err"
	exit 0
}
[ "$branch_err" != "/dev/null" ] && rm -f "$branch_err"

# Resolve graduation marker via the SSOT library.
# CR r2 fix — track GRAD_FAIL_OPEN flag. Every "fail-open on graduation"
# WARN sets the flag; we exit 0 below if it's set so the documented
# fail-open contract is actually honored (previously empty GRAD fell
# through to deny because all categories require GRAD=yes).
GRAD=""
GRAD_FAIL_OPEN=0
if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
	grad_lib="$REPO_ROOT/_lib/phase-graduation.sh"
	# Cache-resolved plugin path fallback for consumer repos where
	# _lib/ lives under .claude/plugins/cache/...
	if [ ! -f "$grad_lib" ]; then
		find_err=$(_capture_err_tmp "scgate-find")
		grad_lib=$(find "$HOME/.claude/plugins/cache/claude-workflow-core" \
			-maxdepth 4 -type f -name "phase-graduation.sh" 2>"$find_err" | head -1)
		if [ -z "$grad_lib" ]; then
			_warn_with_err "phase-graduation.sh not found at REPO_ROOT/_lib or plugin cache — fail-open on graduation" "$find_err"
			GRAD_FAIL_OPEN=1
		fi
		[ "$find_err" != "/dev/null" ] && rm -f "$find_err"
	fi
	if [ -n "$grad_lib" ] && [ -f "$grad_lib" ]; then
		# Subshell isolation: any source/parse error inside the lib cannot
		# abort the gate script. F1 fix — inner `. lib 2>/dev/null` was
		# eating source-time parse errors before outer capture saw them.
		# rc=0 → graduated; rc=1 → not graduated (silent); rc=99 → function
		# missing (lib incomplete); rc>1 (≠99) → real lib error.
		grad_err=$(_capture_err_tmp "scgate-grad")
		grc=0
		(
			# shellcheck source=/dev/null
			. "$grad_lib"
			command -v graduation_check >/dev/null 2>&1 || exit 99
			graduation_check "$branch"
		) 2>"$grad_err" || grc=$?
		if [ "$grc" -eq 0 ]; then
			GRAD="yes"
		elif [ "$grc" -eq 99 ]; then
			echo "ship-cycle-director-gate: WARN — graduation_check function missing after sourcing $grad_lib (lib incomplete) — fail-open on graduation" >&2
			GRAD_FAIL_OPEN=1
		elif [ "$grc" -gt 1 ]; then
			if [ -s "$grad_err" ]; then
				echo "ship-cycle-director-gate: WARN — graduation_check rc=$grc: $(head -c 200 "$grad_err") — fail-open on graduation" >&2
			else
				echo "ship-cycle-director-gate: WARN — graduation_check rc=$grc (no stderr captured) — fail-open on graduation" >&2
			fi
			GRAD_FAIL_OPEN=1
		fi
		[ "$grad_err" != "/dev/null" ] && rm -f "$grad_err"
	fi
fi

# Honor documented fail-open contract — when graduation lookup itself
# failed (lib missing, function missing, check errored), allow the
# command rather than deny. The WARN above tells the operator why.
[ "$GRAD_FAIL_OPEN" = "1" ] && exit 0

# Decision matrix.
allow=0
deny_reason=""
# CR r2 fix — all three categories require GRAD=yes. The state file is
# sha-keyed so without the branch-level graduation check, the same
# commit's `push`/`merge-gate` state could carry across branches and
# let a non-graduated branch bypass the gate.
case "$CATEGORY" in
cr-cli)
	if [ "$GRAD" = "yes" ] && [ "$STAGE" = "phase2" ]; then
		allow=1
	else
		deny_reason="CR-CLI requires graduated branch + cycle stage=phase2 (current=${STAGE:-<unset>}, graduated=${GRAD:-no})."
	fi
	;;
push)
	if [ "$GRAD" = "yes" ] && [ "$STAGE" = "push" ]; then
		allow=1
	else
		deny_reason="git push requires graduated branch + cycle stage=push (current=${STAGE:-<unset>}, graduated=${GRAD:-no})."
	fi
	;;
merge)
	if [ "$GRAD" = "yes" ] && [ "$STAGE" = "merge-gate" ]; then
		allow=1
	else
		deny_reason="gh pr merge requires graduated branch + cycle stage=merge-gate (current=${STAGE:-<unset>}, graduated=${GRAD:-no})."
	fi
	;;
esac

if [ "$allow" = "1" ]; then
	exit 0
fi

cat >&2 <<EOF
BLOCKED by ship-cycle-director-gate: $deny_reason

Run \`.claude/skills/ship-pr-cycle/run.sh next\` first to confirm the next step.
Or invoke via the matching skill wrapper:
  - CR-CLI:  github-pr-creation skill (auto-fires CR-CLI at phase2)
  - push:    handled by ship-pr-cycle.sh next at stage=push
  - merge:   github-pr-merge skill at stage=merge-gate

Bypasses (audit-logged):  SHIP_CYCLE_GATE_SKIP=1 <cmd>  |  SKILL_WRAPPER=1 <cmd>
EOF
exit 2
