#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Edit|Write|MultiEdit|NotebookEdit
# auto-register: true
# v0.7.1 (#23): stricter Phase 1 directive enforcement (partial #732 fix).
#
# WHY this exists: ship-pr-cycle.sh emits a Phase 1 directive ("fire 5
# parallel Agent calls") via stdout when `next` is invoked at the phase1
# stage. Today Claude can ignore that directive — summarize, stall, or
# fire Bash/Edit calls before the 5 Agents. The existing phase1-log-
# pending-gate fires AFTER agents return (forcing review-log.sh per
# agent), but there's no symmetric gate BEFORE agents fire.
#
# This hook closes the gap: when a Phase 1 round directive marker exists
# AND no Agent/Skill call has been observed yet for that round, the next
# non-Agent/Skill tool call is REFUSED with a directive-replay message.
#
# Marker location (re-uses existing ship-pr-cycle marker infrastructure):
#   .claude/.session-state/ship-cycle/<sha>.phase1-directive.txt
#   — written by ship-pr-cycle.sh `_write_phase1_directive_marker()` when
#   cmd_next emits the phase1 directive (#732 r2). Contains directive text.
#
# Cleared by ship-pr-cycle.sh `_clear_phase1_directive_marker()` when
# state advances past phase1.
#
# Bypass: PHASE1_DIRECTIVE_GUARD_SKIP=1 inline sentinel (audit-logged).

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DENY="$HOOK_DIR/../_lib/hook-deny.sh"
LIB_SENTINEL="$HOOK_DIR/../_lib/hook-inline-sentinel.sh"
if [ -f "$LIB_DENY" ]; then
	# shellcheck source=../_lib/hook-deny.sh
	source "$LIB_DENY"
else
	hook_deny() {
		echo "$1: $2" >&2
		exit 2
	}
fi
if [ -f "$LIB_SENTINEL" ]; then
	# shellcheck source=../_lib/hook-inline-sentinel.sh
	source "$LIB_SENTINEL"
else
	hook_inline_sentinel_check() { return 1; }
fi
# v0.30.E (#191): cmd-anchor for the read-only allowlist below.
LIB_ANCHOR="$HOOK_DIR/../_lib/cmd-anchor.sh"
if [ -f "$LIB_ANCHOR" ]; then
	# shellcheck source=../_lib/cmd-anchor.sh
	source "$LIB_ANCHOR"
fi

# Outside-git-repo: allow (hook can fire anywhere). Capture stderr to
# distinguish "not a repo" from corruption.
git_err=$(mktemp)
git_rc=0
REPO_ROOT=$(git rev-parse --show-toplevel 2>"$git_err") || git_rc=$?
if [ "$git_rc" -ne 0 ]; then
	[ -s "$git_err" ] && echo "phase1-directive-pending-guard: git rev-parse failed (rc=$git_rc) — allowing call: $(head -c 200 "$git_err")" >&2
	rm -f "$git_err"
	exit 0
fi
rm -f "$git_err"

DIRECTIVE_DIR="$REPO_ROOT/.claude/.session-state/ship-cycle"
[ -d "$DIRECTIVE_DIR" ] || exit 0

# Find phase1-directive markers (existing ship-pr-cycle infrastructure).
# Use find with explicit rc capture (v0.6.5+ pattern). Pattern matches the
# `_phase1_directive_marker_file()` filename convention: `<sha>.phase1-directive.txt`.
find_err=$(mktemp)
find_out=$(mktemp)
find_rc=0
find "$DIRECTIVE_DIR" -maxdepth 1 -name '*.phase1-directive.txt' -print0 >"$find_out" 2>"$find_err" || find_rc=$?
if [ "$find_rc" -ne 0 ]; then
	hook_deny "phase1-directive-pending-guard" "find failed enumerating directive dir (rc=$find_rc) — fail-closed: $(head -c 200 "$find_err")"
fi
rm -f "$find_err"

pending_count=0
pending_list=""
while IFS= read -r -d '' f; do
	sha=$(basename "$f" .phase1-directive.txt)
	# v0.27.0 #173 Layer 1: self-heal stale markers whose SHA is now
	# reachable from origin/main. Catches merge-commit / fast-forward /
	# rebase-and-push-retaining-SHA flows. Squash-merge writes a NEW
	# commit on main, so the ORIGINAL topic-branch HEAD sha is NOT a
	# direct ancestor of main — Layer 1 will NOT clean those; Layer 2
	# (skill-side rm in github-pr-merge) catches squash-merges by
	# capturing the pre-merge HEAD sha + removing the marker before the
	# branch is deleted. Layer 3 (post-merge hook) provides cross-clone
	# coverage for non-squash paths the operator pulled from main.
	if git merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
		rm -f "$f"
		continue
	fi
	# v0.28.0 #174: also drop markers whose sha is no longer reachable
	# from ANY local ref (abandoned commits — branch deleted, commit
	# rebased away). 2026-05-28 observed 34 accumulating across prior
	# sessions in a peer repo (#174 Axis 2).
	# CR fix: validate hex-sha basename BEFORE for-each-ref (skip
	# editor swap files); separate rc from empty-output (rc!=0 keeps
	# marker rather than flipping `!` into mass-rm on git error).
	if [[ $sha =~ ^[0-9a-f]{7,40}$ ]]; then
		_ref_out=$(git for-each-ref --contains "$sha" --format='%(refname)' 2>/dev/null) && _ref_rc=0 || _ref_rc=$?
		if [ "$_ref_rc" -eq 0 ] && [ -z "$_ref_out" ]; then
			rm -f "$f"
			continue
		fi
	fi
	pending_count=$((pending_count + 1))
	pending_list="${pending_list}  - sha=$sha (directive emitted; agents not yet fired)
"
done <"$find_out"
rm -f "$find_out"

[ "$pending_count" -eq 0 ] && exit 0

# Read stdin to extract command for inline-sentinel bypass + tool detection.
if ! PAYLOAD=$(cat 2>/dev/null); then
	echo "phase1-directive-pending-guard: stdin read failed — allowing call" >&2
	exit 0
fi

# Extract tool name + command. If it's Agent or Skill, allow (those are what
# we want to fire). Other tool types refused until directive cleared.
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

case "$TOOL" in
Agent | Skill)
	# Allow Agent + Skill calls — those ARE the Phase 1 firing path.
	exit 0
	;;
esac

# Allow review-log.sh explicitly (the way to clear the directive after
# agents return). Mirrors phase1-log-pending-gate's escape hatch.
if printf '%s' "$CMD" | grep -qE '((^|[;&|][[:space:]]*)([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*)\.?/?\.claude/hooks/review-log\.sh'; then
	exit 0
fi

# v0.30.E (#191): allow a SINGLE, SIMPLE read-only INSPECTION command through
# while a directive is pending. The guard's purpose is to stop the main loop
# from doing PRODUCTIVE work (Edit/Write/commit/push) or stalling before
# firing the Phase 1 agents — NOT to block harmless reads. Critically, this
# PreToolUse hook ALSO fires inside the Phase 1 subagents (code-reviewer et
# al.), whose job is to run `git diff`/`cat`/`grep` over the diff; denying
# those reads mid-review was the #191 bug. Non-Bash write tools (Edit, Write,
# MultiEdit, NotebookEdit) are never read-only — the [ "$TOOL" = Bash ] guard
# means they fall straight through to the deny.
#
# SECURITY (v0.30.E r2, #191 Phase 1): a read verb at the FRONT does NOT make
# a COMPOUND command read-only. `git diff && git push`, `cat $(rm -rf x)`,
# `git diff | tee f`, `git diff --output=f`, and `find . -delete` all launder
# a mutation behind a leading read verb. So we REJECT (fall through to deny)
# any command that can chain, substitute, pipe, background, redirect to a
# file, or invoke a per-tool write action — and only THEN allowlist the
# leading verb of what remains (which is now guaranteed a single simple cmd).
if [ "$TOOL" = "Bash" ] && declare -f match_cmd_at_anchor >/dev/null 2>&1; then
	# Strip harmless discard/dup redirects (2>/dev/null, 2>&1, >/dev/null,
	# &>/dev/null) so they don't trip the `>` reject; fold newlines to `;`
	# so a multi-line command is caught by the separator reject below.
	_resid=$(printf '%s' "$CMD" |
		sed -E 's/2>&1/ /g; s/[0-9]*>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g; s/&>>?[[:space:]]*\/dev\/null([[:space:]]|$)/ /g' |
		tr '\n' ';')
	# THREAT MODEL (#191 P1 r1-r3): this guard is a WORKFLOW NUDGE for a
	# cooperative agent — it stops the main loop from doing productive work
	# (commit/push/Edit/Write) or stalling before firing Phase 1 agents. It is
	# NOT an adversarial sandbox: the realistic failure is Claude absent-
	# mindedly committing before agents fire, not Claude crafting `find -rm`
	# to evade its own guard. Prompt-injection of a subagent is defended by
	# the auto-mode classifier + other gates, not here. So the screen below is
	# BEST-EFFORT for the known write/exec-via-flag classes; it does not
	# attempt to be exhaustive against every tool implementation's flag zoo
	# (the local `find` is bfs with `-rm`, `grep` is ugrep with `--filter` —
	# implementations vary and cannot all be enumerated).
	#
	# Reject if the residue contains ANY of:
	#   [;&|`]      — statement separator / background / pipe / backtick-subst
	#   $( <( >(    — command / process substitution
	#   >           — a surviving file-writing redirect
	#   --*output=  — git --output + semgrep --json-output/--sarif-output/...
	#                 (the whole --<fmt>-output family writes a file / POSTs to
	#                 a URL). Anchored so the READ flag --output-indicator-* is
	#                 NOT false-rejected.
	#   --autofix   — semgrep in-place source rewrite (#191 r3)
	#   --pre / --hostname-bin — ripgrep exec-a-command flags (#191 r2)
	#   -delete / -rm / -exec* / -ok* / -fprint* / -fls — find write/exec
	#                 actions (-rm is the bfs alias for -delete, #191 r3)
	# Anything matching is NOT a single simple read-only command → deny.
	#
	# RULE for adding a verb to the allowlist below: it must be a tool with NO
	# subprocess-spawn / file-write FLAG in common implementations. cat/head/
	# tail/ls/wc/grep qualify; rg/find/git-grep/semgrep-autofix did NOT (each
	# found in r1-r3). git read subcmds qualify with --output screened.
	if printf '%s' "$_resid" | grep -qE '[;&|`]|\$\(|<\(|>\(|>|(^|[[:space:]])--[a-z-]*output([[:space:]=]|$)|(^|[[:space:]])--(autofix|allow-local-builds)([[:space:]=]|$)|(^|[[:space:]])--(pre|hostname-bin)([[:space:]=]|$)|(^|[[:space:]])-(delete|rm|exec|execdir|ok|okdir|fprint|fprintf|fprint0|fls)([[:space:]]|$)'; then
		: # compound / substitution / pipe / redirect / exec-or-write-flag — deny
	else
		# Single simple command: allowlist its leading read-only verb. git
		# mutating verbs (commit/push/add/reset/...) are excluded — only read
		# subcommands listed. sed/awk/jq/yq excluded (write modes: sed -i,
		# sed -n 'w', awk redirects). `rg` excluded too (--pre/--hostname-bin
		# exec — #191 r2); subagents use the Grep TOOL (unaffected by this
		# Bash-only hook) or `grep`, plus the Read tool + git diff.
		# NB: `git grep` is intentionally NOT here — it has
		# --open-files-in-pager[=<cmd>] which execs a pager (same exec-flag
		# class as rg --pre, #191 r2). Plain `grep` (no such flag) covers
		# search. git diff's `-O<orderfile>` (read) is fine — only --output
		# writes, and that's screened above.
		#
		# v0.31 #225 (silent-failure-hunter #4): the sanctioned test runners
		# scripts/test.sh + scripts/test-touched.sh are allowed so a Phase-1
		# REVIEW subagent can verify behaviorally (red/green) WITHOUT resorting to
		# PHASE1_DIRECTIVE_GUARD_SKIP. They are read-only w.r.t. source — they write
		# only gitignored verification artifacts under .claude/ (bats-run.jsonl,
		# test-run-summary.jsonl, the .review-cache ledger) + temp dirs, not the
		# productive commit/push/Edit work this guard exists to defer. The single
		# pattern accepts an optional env-prefix (e.g. `BASE=main
		# scripts/test-touched.sh` — the documented scope-vs-main form) and the
		# `bash <runner>` form, reusing the env-prefix idiom of the review-log
		# allowlist above + _lib/cmd-anchor.sh. The compound/redirect/exec-flag
		# screen above still runs FIRST (so `scripts/test.sh; rm …` is denied).
		for _ro in \
			'git[[:space:]]+(diff|log|show|status|rev-parse|for-each-ref|branch|merge-base|ls-files|cat-file|describe|blame)' \
			'cat' 'head' 'tail' 'grep' 'find' 'ls' 'wc' 'semgrep' \
			'([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(bash[[:space:]]+)?(\./)?scripts/test(-touched)?\.sh'; do
			if match_cmd_at_anchor "$_ro" "$CMD"; then
				exit 0
			fi
		done
	fi
fi

# Inline-sentinel bypass.
if hook_inline_sentinel_check "PHASE1_DIRECTIVE_GUARD_SKIP" "$CMD" "phase1-directive-pending"; then
	exit 0
fi

hook_deny "phase1-directive-pending-guard" \
	"$pending_count Phase 1 round directive(s) pending — fire Phase 1 agents BEFORE next non-Agent/Skill tool call:
$pending_list
Required action: fire the 5 parallel Agent calls (code-reviewer, code-simplifier,
comment-analyzer, pr-test-analyzer, silent-failure-hunter) + run semgrep + fire
Skill(security-review). See ship-pr-cycle.sh directive output for round number.

Bypass (audit-logged): PHASE1_DIRECTIVE_GUARD_SKIP=1 <cmd>"
