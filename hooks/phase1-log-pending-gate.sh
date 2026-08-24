#!/bin/bash
# r1 CR #5 fix: project-mandated `set -euo pipefail`. Multiple early-out
# `exit 0` paths still work because `set -e` only aborts on UNHANDLED
# non-zero rc. Critical paths use `||` / `if !` for graceful handling.
set -euo pipefail
# event: PreToolUse
# matcher: Bash|Agent|Skill|Edit|Write|MultiEdit|NotebookEdit
# auto-register: false  # de-registered 2026-08-24 (see 2564): assumed synchronous Agent returns; the installer must NOT re-wire it
# v4.28-W4 (#721) — mechanically enforce phase1-log chain. Refuses any
# tool call when `.claude/.session-state/phase1-log-pending/*.txt`
# files exist. Each pending file is written by phase1-post-agent-nudge.sh
# when a Phase 1 agent returns; review-log.sh deletes the file when the
# operator logs that agent's findings.
#
# Why this exists (#721):
# Throughout PR #708 the chain stalled because Claude produced agent
# output (security-review markdown, summary text) BEFORE firing
# review-log.sh per-agent. The advisory directive from
# phase1-post-agent-nudge.sh competed with skill output + UserPromptSubmit
# context + task reminders and got missed. User flagged this 5+ times.
# This hook makes the directive MECHANICAL — the next tool call REFUSES
# until review-log fires for the pending agent.
#
# Bypass: PHASE1_LOG_PENDING_SKIP=1 inline sentinel (audit-logged).

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

# CR Phase 2 major: was `2>/dev/null || exit 0` (fail-OPEN). If git
# rev-parse fails for any reason inside a real repo (corrupted .git,
# permission), gate would silently allow tool calls — defeating the
# mechanism. Now: capture stderr + advisory + exit 0 only when we're
# genuinely outside a git repo (gh hooks run anywhere).
git_err=$(mktemp)
git_rc=0
REPO_ROOT=$(git rev-parse --show-toplevel 2>"$git_err") || git_rc=$?
if [ "$git_rc" -ne 0 ]; then
	# Outside a repo or git failure. Allow but surface stderr so an
	# inside-repo failure (corruption/perms) is visible.
	[ -s "$git_err" ] && echo "phase1-log-pending-gate: git rev-parse failed (rc=$git_rc) — allowing call: $(head -c 200 "$git_err")" >&2
	rm -f "$git_err"
	exit 0
fi
rm -f "$git_err"
PENDING_DIR="$REPO_ROOT/.claude/.session-state/phase1-log-pending"

# No pending dir → no pending entries → allow.
[ -d "$PENDING_DIR" ] || exit 0

# Find all pending files. r1 SFH #2 fix + r2 CA #1 fix: capture find
# stderr AND rc — process substitution `< <(find ...)` does NOT
# propagate find's rc to $? (the `done` rc is the loop body's, not
# find's). Write find output to a temp file first, capture rc directly,
# then iterate. On non-zero rc, fail-CLOSED (refuse the tool call) since
# directory state is unknown — silently allowing on find failure defeats
# the entire mechanism this hook exists to enforce.
pending_count=0
pending_list=""
find_err=$(mktemp)
find_out=$(mktemp)
find_rc=0
find "$PENDING_DIR" -maxdepth 1 -name '*.txt' -print0 >"$find_out" 2>"$find_err" || find_rc=$?
if [ "$find_rc" -ne 0 ]; then
	hook_deny "phase1-log-pending-gate" "find failed enumerating pending dir (rc=$find_rc) — fail-closed: $(head -c 200 "$find_err")"
fi
rm -f "$find_err"
while IFS= read -r -d '' f; do
	pending_count=$((pending_count + 1))
	# Format: <agent>-<sha>.txt → strip path + extension for display
	pending_list="${pending_list}  - $(basename "$f" .txt)
"
done <"$find_out"
rm -f "$find_out"

[ "$pending_count" -eq 0 ] && exit 0

# Read stdin to extract command for inline-sentinel bypass check.
# r1 SFH #5 fix: surface stdin failure to stderr (mirror sibling
# phase1-post-agent-nudge.sh pattern). Operator using the documented
# bypass deserves a signal when the bypass silently no-ops.
if ! PAYLOAD=$(cat 2>/dev/null); then
	echo "phase1-log-pending-gate: stdin read failed — bypass sentinels disabled for this call" >&2
	PAYLOAD="{}"
fi
# r1 SFH #1 fix: surface jq parse failure so operator can debug
# why their bypass sentinel didn't fire.
jq_err=$(mktemp)
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>"$jq_err"); then
	echo "phase1-log-pending-gate: jq failed parsing tool_input.command — bypass sentinels disabled: $(head -c 200 "$jq_err")" >&2
	CMD=""
fi
rm -f "$jq_err"

# Inline-sentinel bypass: PHASE1_LOG_PENDING_SKIP=1 in the command.
if hook_inline_sentinel_check "PHASE1_LOG_PENDING_SKIP" "$CMD" "phase1-log-pending"; then
	exit 0
fi

# (#2535 r1 security-review) ALLOW Agent/Skill while a log is pending.
#
# This gate exists to stop the main loop doing PRODUCTIVE work (or narrating)
# before logging an agent's findings. Firing another REVIEW agent is not
# productive work — it is the review itself, and the directive explicitly asks
# for "5 parallel Agent calls".
#
# Blocking Agent here made that impossible, because agents are ASYNC: the
# PostToolUse nudge writes the pending file when the Agent tool call returns —
# i.e. at LAUNCH — while the findings count only exists ~10 minutes later when
# the agent actually completes. So the gate demanded a number that could not yet
# exist, and refused every call (including the next Agent) until it was given.
# The designed parallel-5 block collapsed into a serialized
# fire → block → wait → log chain, ~5x the wall-clock, with the operator wedged
# between each step and no permitted action at all.
#
# Bash/Edit/Write/MultiEdit/NotebookEdit stay blocked, so productive work still
# cannot proceed until every pending agent is logged — the property #721 was
# written to enforce is preserved exactly.
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
case "$TOOL" in
Agent)
	# Agent is unconditionally allowed: the whole point of the async fix is
	# firing the round's review agents in PARALLEL, and an Agent cannot be
	# logged until it returns.
	exit 0
	;;
Skill)
	# Skill is NOT blanket-allowed (CR-in-CI #2540 + phase2): a Skill can invoke
	# Bash internally, so `Skill) exit 0` was a hole straight through the gate —
	# exactly the productive-work path #721 exists to block. Restrict to the
	# explicit review skills the phase-1 directive actually fires (SKILL.md step
	# 4 fires security-review as a SEPARATE Skill call, so it must pass). Every
	# other Skill is denied until the pending logs are recorded.
	_SKILL_NAME=$(printf '%s' "$PAYLOAD" |
		jq -r '.tool_input.command // .tool_input.skill // .tool_input.name // ""' 2>/dev/null || echo "")
	# Strip any plugin namespace ("pr-review-toolkit:code-reviewer" → the tail)
	# so the allowlist matches regardless of how the skill is addressed.
	_SKILL_NAME=${_SKILL_NAME##*:}
	case "$_SKILL_NAME" in
	security-review | code-reviewer | code-simplifier | comment-analyzer | pr-test-analyzer | silent-failure-hunter)
		exit 0
		;;
	esac
	# fall through to the deny below
	;;
esac

# Allow review-log.sh itself through (it's the way out of the lock).
#
# SECURITY (#2535 r1): the previous pattern here was the same one confirmed
# exploitable in phase1-directive-pending-guard.sh — it admitted an arbitrary
# `NAME=value` env prefix (so `BASH_ENV=/tmp/evil.sh .claude/hooks/review-log.sh`
# sourced attacker code, review-log.sh having a `#!/bin/bash` shebang), and it
# had no `^` anchor or end bound, so `git commit -am x; .claude/hooks/review-log.sh`
# was admitted whole. Anchored, env-prefix-free, canonical-path-only. Arguments
# are still permitted — the call is `review-log.sh phase1 <round> <agent> <n> ok`.
# The launder screen is SHARED with phase1-directive-pending-guard.sh (#2535
# phase2). An inline copy here diverged from the guard's: it lacked the
# discard-redirect stripping, so `review-log.sh … 2>/dev/null` was allowed by one
# gate and denied by the other. Two copies of a security predicate drift; source
# the one definition. Best-effort — if the lib is unreachable, fall back to a
# STRICTER inline screen (no stripping), because a false deny on the escape
# hatch is recoverable and a false allow is not.
# Resolve across both supported layouts (mirrors _resolve_guard_lib in the
# sibling guard) rather than a single hardcoded hop that silently reverts to the
# inline fallback elsewhere (CR-in-CI #2540). The inline fallback here is
# deliberately STRICTER, so a miss fails safe — but resolving correctly means it
# is rarely needed.
_LPG_LAUNDER=""
for _lpg_c in "$HOOK_DIR/../_lib/cmd-launder-screen.sh" "$HOOK_DIR/../../_lib/cmd-launder-screen.sh"; do
	# Explicit if-then, NOT `[ -r x ] && { ...; }`: when NEITHER path is readable
	# the AND-list leaves the loop's exit status non-zero. Dogfooded — this file's
	# `set -e` does not abort on it (the left operand of && is exempt) — but the
	# construct makes the hook's survival depend on that subtlety, and a hook that
	# aborts fails OPEN (the gate silently stops gating). Explicit form can never
	# return non-zero. (CR-in-CI #2540 phase2)
	if [ -r "$_lpg_c" ]; then
		_LPG_LAUNDER="$_lpg_c"
		break
	fi
done
if [ -n "$_LPG_LAUNDER" ]; then
	# shellcheck source=../_lib/cmd-launder-screen.sh
	. "$_LPG_LAUNDER" 2>/dev/null || true
fi
if ! declare -f cmd_launders_mutation >/dev/null 2>&1; then
	cmd_launders_mutation() {
		# SIGPIPE-safe: NO `grep -q` at the end of a pipe. This gate calls the
		# predicate NEGATED (`! cmd_launders_mutation` below), and with the
		# sourcing hook under `set -o pipefail` a `grep -q` early-match makes the
		# upstream `tr` die with 141, the pipeline reports non-zero, `!` flips it
		# to 0, and a real laundering command is ALLOWED (CR-in-CI #2540). Capture
		# the transform, match in-shell, fail CLOSED. Deliberately STRICTER than
		# the shared lib (no discard-redirect stripping): a false deny on the
		# review-log.sh escape hatch is recoverable, a false allow is not.
		local _screened
		_screened=$(printf '%s' "$1" | tr '\n' ';') || return 0
		local _re='[;&|`]|\$\(|<\(|[0-9]*>'
		[[ $_screened =~ $_re ]]
	}
fi
if printf '%s' "$CMD" | grep -qE '^(bash[[:space:]]+)?(\./)?(\.claude/)?hooks/review-log\.sh([[:space:]]|$)' &&
	! cmd_launders_mutation "$CMD"; then
	exit 0
fi

# Refuse with listing of pending agents.
hook_deny "phase1-log-pending-gate" \
	"$pending_count Phase 1 agent return(s) need review-log.sh BEFORE the next Bash/Edit/Write call:
$pending_list
Run for each: .claude/hooks/review-log.sh phase1 <round> <agent> <findings_count> ok
(Agent/Skill calls ARE permitted while pending — fire the rest of the round's
agents in parallel, then log each as it returns. Agent is unrestricted; Skill is
limited to the review skills: security-review, code-reviewer, code-simplifier,
comment-analyzer, pr-test-analyzer, silent-failure-hunter.)

Bypass (audit-logged): PHASE1_LOG_PENDING_SKIP=1 <cmd>"
