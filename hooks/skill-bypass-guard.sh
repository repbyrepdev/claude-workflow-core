#!/bin/bash
set -euo pipefail
# event: PreToolUse
# matcher: Bash
# v4.17.A/B/I #501/#502/#509 — PreToolUse/Bash guard that catches raw
# gh-CLI invocations for PR/issue/release create + PR merge, redirects
# Claude to the correct skill instead of letting Claude bypass template
# + board-sync + skill logic.
#
# WHY: observed 2026-04-20 during v4.15 ship — Claude used:
#   - gh pr create (should be github-pr-creation skill — template,
#     labels, issue link, area detection, milestone attach)
#   - gh issue create × N (should be github-issue-creation skill —
#     template match, ai-triage local replica, project-board-sync)
#   - gh pr merge (should be github-pr-merge skill — pre-merge checks,
#     user-confirmation gate, post-merge pull + verify-specifics + tag
#     eligibility)
#   - gh release create (should be covered by github-pr-merge Step X
#     after tag; invokes .claude/local-backups/run-workflow.sh release
#     during cap-deferral)
# Each bypass loses template compliance + local-replica firing +
# post-create automation.
#
# HOW: on every Bash tool call, inspect .tool_input.command. If it
# matches one of the bypass patterns, emit a JSON hookSpecificOutput
# with permissionDecision="deny" telling Claude to invoke the proper
# skill, then exit 0 (v4.17.R migration from exit 2 — see below).
#
# BLOCKING MECHANISM (v4.17.R, PR #511 CR): this hook previously used
# `exit 2` to block. Per CR research + anthropics/claude-code issues #24327,
# #26923, #13756, #40580, exit 2 is unreliable for Bash tool blocking in
# Claude Code — it often reports the error but lets the command run
# anyway. The documented reliable path is exit 0 + JSON:
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#    "permissionDecision":"deny","permissionDecisionReason":"..."}}
# All block sites in this hook use the `deny()` helper to emit that
# structure + stderr audit log + exit 0.
#
# ESCAPE HATCH: two env vars, either one bypasses. BOTH are checked in
# TWO places (v4.17.O): process environment (preferred — `export X=1`
# before Claude starts) AND command-string prefix (`X=1 gh pr ...`).
# The inline-prefix path exists because PreToolUse runs before `bash`
# interprets the command — the var isn't in the hook's env yet, so we
# grep the command string. Both paths log a stderr audit trail.
#   - PHASE1_GATE_SKIP=1 — shared with phase1-before-cr.sh (whole-pipeline
#     emergency bypass, use sparingly).
#   - GH_SKILL_BYPASS_SKIP=1 — this hook only. Use for meta-PRs that MUST
#     shell out raw gh (the PR that adds/edits this hook, skill-internal
#     tooling that wraps gh for its own purpose, etc.).

# v4.17.S: jq is load-bearing for the deny path. Check at startup so
# a missing binary surfaces immediately (exit 2 is acceptable here —
# it's a tool-missing error, not a block decision).
command -v jq >/dev/null 2>&1 || {
	echo "skill-bypass-guard: jq not found — cannot emit deny JSON, exiting" >&2
	exit 2
}

# v4.17.R: emit JSON permissionDecision=deny + stderr log + exit 0.
# Replaces previous `exit 2` pattern (unreliable blocking).
# v4.17.S: capture jq output to a variable first. errexit is suspended
# when deny() is called via `|| deny "..."`, so a runtime jq failure
# would otherwise let `exit 0` run with no JSON emitted = silent pass-
# through. The `|| exit 2` fallback is safer than that (even if exit 2
# is unreliable, it's strictly better than empty-stdout + exit 0).
deny() {
	local reason="$1" json
	echo "skill-bypass-guard: $reason" >&2
	json=$(jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}') || {
		echo "skill-bypass-guard: jq emit failed — falling back to exit 2" >&2
		exit 2
	}
	printf '%s\n' "$json"
	exit 0
}

# v4.17.K (CR #500): fail-closed on stdin/jq parse — prior `|| exit 0`
# silently disabled the guard on any malformed payload.
# v4.17.AA: `if !` form instead of `|| deny` for clarity (CR #511 Phase 2).
if ! PAYLOAD=$(cat); then
	deny "stdin read failed — failing closed"
fi
if ! CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""'); then
	deny "payload unparseable — failing closed"
fi
# v4.17.S: legitimate-empty exit path (non-Bash PreToolUse, or Bash
# with empty command string). Logged so drift in payload shape surfaces.
if [ -z "$CMD" ]; then
	echo "skill-bypass-guard: empty command — passing through (non-Bash payload or blank command)" >&2
	exit 0
fi

# v4.28-W4 (#677): canonical command-anchor regex shared across hooks.
# CMD_SEGMENT_ANCHOR / CMD_SEGMENT_END are interpolated into the
# `grep -qE` patterns below.
# shellcheck source=../_lib/cmd-anchor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/cmd-anchor.sh"

# Env override — check process env first, then command-string prefix
# (v4.17.O). Both return the same exit-0 bypass; the bypass_var tag
# records which path matched for the audit log.
#
# v4.20 (#504): SKILL_WRAPPER=1 is a sanctioned-path marker to be set by
# future skill wrapper scripts (deferred to #519 skill-as-script track)
# when they need to invoke gh CLI internally. Hook lands ahead of the
# wrappers so the guard is ready when they ship. Distinct from the
# emergency GH_SKILL_BYPASS_SKIP path because the intent is "this IS
# the sanctioned skill flow" rather than "override for a meta-PR".
bypass_var=""
if [ "${SKILL_WRAPPER:-0}" = "1" ]; then
	bypass_var="SKILL_WRAPPER(env)"
elif [ "${GH_SKILL_BYPASS_SKIP:-0}" = "1" ]; then
	bypass_var="GH_SKILL_BYPASS_SKIP(env)"
elif [ "${PHASE1_GATE_SKIP:-0}" = "1" ]; then
	bypass_var="PHASE1_GATE_SKIP(env)"
elif printf '%s' "$CMD" | grep -qE '(^|[[:space:]])SKILL_WRAPPER=1([[:space:]]|;|&|$)'; then
	bypass_var="SKILL_WRAPPER(prefix)"
elif printf '%s' "$CMD" | grep -qE '(^|[[:space:]])GH_SKILL_BYPASS_SKIP=1([[:space:]]|;|&|$)'; then
	bypass_var="GH_SKILL_BYPASS_SKIP(prefix)"
elif printf '%s' "$CMD" | grep -qE '(^|[[:space:]])PHASE1_GATE_SKIP=1([[:space:]]|;|&|$)'; then
	bypass_var="PHASE1_GATE_SKIP(prefix)"
fi
if [ -n "$bypass_var" ]; then
	echo "skill-bypass-guard: ${bypass_var} — bypassing skill guard for: $(printf '%s' "$CMD" | head -c 80)" >&2
	exit 0
fi

# v4.28-W3-C (#659) + r1 follow-up: test-fixture heuristic. A command
# that includes `mktemp -d` AND `git init` AND `git commit` — all three
# anchored to command-start (^) or shell separator ([;&|]) — is
# overwhelmingly a test-isolation pattern. The tempdir setup used by
# ~50 bats tests in this repo. Allow the `git commit` in that context
# without forcing the /git-commit skill (which would refuse a temp repo).
#
# Anchor contract (3 conditions, ALL required):
#   1. `mktemp -d` (optionally inside `tmp=$(...)`) at segment-start
#   2. `git init` at segment-start
#   3. `git commit` at segment-start
# Each condition uses `grep -qE` with `(^|[;&|][[:space:]]*)` segment-
# start anchor — substring inside echo/cat arg won't fire.
#
# Why the 3rd anchor (`git commit`): without it, raw `git commit` could
# evade the gate by appending `mktemp -d ...` and `git init ...` strings
# anywhere in the command. The 3-anchor form requires the actual fixture
# pattern (all three real commands present) to match.
#
# r2 CR MAJOR fix: previously this set exit 0 unconditionally on the
# 3-anchor match, which let a mixed command like
# `mktemp -d ... && git init && gh pr merge 123 && git commit ...`
# slip through the dispatcher entirely. Now: set a context flag that
# narrowly bypasses ONLY the git-commit dispatcher below; gh/bats and
# all other blocked verbs in the same command are still enforced.
fixture_git_commit_context=0
if printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)(tmp=\$\()?[[:space:]]*mktemp[[:space:]]+-d([[:space:]]|\)|$)' &&
	printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)git[[:space:]]+init([[:space:]]|$)' &&
	printf '%s' "$CMD" | grep -qE '(^|[;&|][[:space:]]*)git[[:space:]]+commit([[:space:]]|$)'; then
	fixture_git_commit_context=1
fi

# Patterns: anchored to command-start (^) OR shell separator ([;&|]) —
# same anchor-set as phase1-before-cr.sh v4.17.E, so raw `gh` inside a
# --notes/--body quoted string doesn't fire. Each entry: "subcmd|skill|reason".
# The `\$` in the grep -E below is a literal `$` passed to regex
# (bash double-quote escape); regex `([[:space:]]|$)` = space or EOL.
GH_RULES=(
	"pr[[:space:]]+create|github-pr-creation|PR creation needs template compliance (Summary/Changes/Testing/Encryption/Pre-merge/Rollback), label application, issue linking, active-milestone attach."
	"issue[[:space:]]+create|github-issue-creation|Issue creation needs template match, ai-triage (local replica during cap-deferral) for priority/area labels + board Type pill, project-board-sync Step 9 for Status/Priority/Area field dual-write."
	"pr[[:space:]]+merge|github-pr-merge|PR merge needs pre-merge check validation (all required passing), explicit user-confirmation gate, post-merge pull + deploy-verify (if compose/config touched) + tag-eligibility. Raw merge skips all of that."
	"release[[:space:]]+create|github-pr-merge|Release create should fire via post-merge step (invokes .claude/local-backups/run-workflow.sh release during cap-deferral). Raw gh release create skips the workflow replica + auto-changelog + asset attach logic."
)

# CR #634 finding 136: env-assignment matcher must accept lowercase names
# AND quoted/spaced values. Original `[A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+`
# missed `foo=1 git commit ...` and `X="a b" bats ...`.
#
# v4.28-W5 #858 fix: the third alternation MUST exclude leading quotes.
# Prior: `[^[:space:]]+` matched `"Updated` (the literal opening-quote +
# content of an unclosed quoted value), so the regex engine treated
# `CMD="Updated bats test 6"` as `CMD="Updated bats...` — env-prefix
# accepting `"Updated` as unquoted value + space + bats as verb. Result:
# any --fix-summary / commit-message arg containing "bats" tripped the
# guard. Fix: require unquoted env-values to NOT start with `"` or `'`,
# forcing the quoted alternations to handle quoted values exclusively.
#
# #2396: the prefix now comes from _lib/cmd-anchor.sh's CMD_HARDENED_PREFIX,
# which supersets the old inline env-assignment prefix with command-wrapper
# (`command`/`builtin`/`sudo -E`/`env X=1`) and grouping (`{ v; }`/`( v )`)
# detection — `{ gh pr merge 5; }` and `sudo -E git commit` no longer slip
# the guard. The explicit else-branch keeps the old env-only prefix if the
# sourced lib predates #2396 (mixed-version tree mid-re-pin) — degraded
# coverage there, never a set -u abort inside a PreToolUse guard.
if [ -n "${CMD_HARDENED_PREFIX:-}" ]; then
	ENV_PREFIX="$CMD_HARDENED_PREFIX"
else
	ENV_PREFIX='([A-Za-z_][A-Za-z0-9_]*=('"'"'[^'"'"']*'"'"'|"[^"]*"|[^"'"'"'[:space:]][^[:space:]]*)[[:space:]]+)*'
fi

# CR #634 finding 177: also extract the inner command from shell-wrapper
# invocations like `bash -lc 'git commit ...'` or `sh -c 'bats foo.bats'`.
# Strip the wrapper to get the inner command, then match against the same
# regexes. WRAPPED_CMD is "" when CMD doesn't have a wrapper.
# Use `|` as the sed delimiter so `/bin/bash` slashes don't break parsing.
WRAPPED_CMD=$(printf '%s' "$CMD" | sed -nE "s|.*(bash\|sh\|zsh\|/bin/bash\|/bin/sh\|/bin/zsh)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*['\"]([^'\"]+)['\"].*|\3|p" | head -1)

SKILL=""
REASON=""
for rule in "${GH_RULES[@]}"; do
	IFS='|' read -r subcmd skill reason <<<"$rule"
	pattern="${CMD_SEGMENT_ANCHOR}${ENV_PREFIX}gh[[:space:]]+${subcmd}${CMD_SEGMENT_END}"
	matched=0
	if printf '%s' "$CMD" | grep -qE "$pattern"; then
		matched=1
	elif [ -n "$WRAPPED_CMD" ] && printf '%s' "$WRAPPED_CMD" | grep -qE "$pattern"; then
		matched=1
	fi
	if [ "$matched" = "1" ]; then
		SKILL="$skill"
		REASON="$reason"
		break
	fi
done

# v4.27 (#632): extend bypass coverage beyond gh-CLI to raw git commit and
# raw bats invocations. Both bypass critical workflow infrastructure:
#   - `git commit` skips Conventional Commits validation, Copilot draft,
#     and the SKILL_WRAPPER=1 audit trail the /git-commit skill provides.
#   - `bats` skips the .claude/logs/bats-run.jsonl content-hash log that
#     bats-gate.sh (pre-commit) requires; next commit then fails bats-gate.
# Anchor: command-start or shell separator (same as gh rules) so quoted
# strings inside `gh pr comment --body "use git commit"` don't false-fire.

# git commit → /git-commit skill (uses .claude/skills/git-commit/run.sh)
if [ -z "$SKILL" ]; then
	gc_pattern="${CMD_SEGMENT_ANCHOR}${ENV_PREFIX}git[[:space:]]+commit${CMD_SEGMENT_END}"
	gc_matched=0
	if printf '%s' "$CMD" | grep -qE "$gc_pattern"; then
		gc_matched=1
	elif [ -n "$WRAPPED_CMD" ] && printf '%s' "$WRAPPED_CMD" | grep -qE "$gc_pattern"; then
		gc_matched=1
	fi
	if [ "$gc_matched" = "1" ]; then
		# r2 CR fix: bypass git-commit dispatcher ONLY in fixture context
		# (mktemp -d + git init + git commit). Mixed commands carrying gh
		# or other blocked verbs are still caught by the dispatchers above
		# — SKILL is non-empty by this point if any of them matched.
		if [ "${fixture_git_commit_context:-0}" = "1" ]; then
			echo "skill-bypass-guard: test-fixture pattern (mktemp -d + git init + git commit) — bypassing git-commit dispatcher for: $(printf '%s' "$CMD" | head -c 80)" >&2
			exit 0
		fi
		SKILL="git-commit"
		REASON="git commit needs Conventional Commits format (.github/commit-template.yml SSOT), Co-Authored-By trailer, optional Copilot draft, post-commit template lint. The /git-commit skill (run.sh wrapper) sets SKILL_WRAPPER=1 to satisfy this guard + handles all of that."
	fi
fi

# Emit gh/git-commit directive if any matched.
if [ -n "$SKILL" ]; then
	# v4.17.R: emit the full directive as the permissionDecisionReason so
	# Claude reads it via the JSON deny structure (not relying on stderr).
	CMD_PREVIEW=$(printf '%s' "$CMD" | head -c 120)
	DIRECTIVE="BLOCKED: raw command invocation detected — use skill instead.
Command: ${CMD_PREVIEW}...
Required skill: ${SKILL}
Why: ${REASON}
To proceed: invoke the ${SKILL} skill (natural-language trigger like \"create an issue\" / \"open a PR\" / \"merge it\" / \"commit\", OR via the Skill tool with skill=\"${SKILL}\"). The skill handles template/labels/board-sync/post-action automation that raw command bypasses.
Emergency override (skill broken / meta-PR touching skill itself): GH_SKILL_BYPASS_SKIP=1 <your-command> (bypass logged to stderr with source tag)."
	deny "$DIRECTIVE"
fi

# bats → scripts/test-touched.sh (or scripts/test.sh for explicit cases).
# Different directive template: target is a script, not a skill.
bats_pattern="${CMD_SEGMENT_ANCHOR}${ENV_PREFIX}bats${CMD_SEGMENT_END}"
bats_matched=0
if printf '%s' "$CMD" | grep -qE "$bats_pattern"; then
	bats_matched=1
elif [ -n "$WRAPPED_CMD" ] && printf '%s' "$WRAPPED_CMD" | grep -qE "$bats_pattern"; then
	bats_matched=1
fi
if [ "$bats_matched" = "1" ]; then
	CMD_PREVIEW=$(printf '%s' "$CMD" | head -c 120)
	BATS_DIRECTIVE="BLOCKED: raw bats invocation — bypasses bats-run.jsonl content-hash log.
Command: ${CMD_PREVIEW}...
Why blocked: bats-gate.sh (pre-commit) reads .claude/logs/bats-run.jsonl to verify touched .sh files have a recent (<1h) hash-verified pass. Raw \`bats <file>\` skips the log entirely → next git commit fails bats-gate.

To proceed (in order of preference):
  1. scripts/test-touched.sh
       Iteration loop, scoped to touched .sh + .bats via # covers: headers.
       Routes through scripts/test.sh internally (logs each run with hash).
  2. scripts/test.sh path/to/file.bats
       Single .bats file, hash-recorded.
  3. scripts/test.sh
       Full suite (pre-push or weekly baseline).

Emergency override (user-facing — audit-logged): GH_SKILL_BYPASS_SKIP=1 bats <file>"
	deny "$BATS_DIRECTIVE"
fi

# coderabbit → scripts/cr/local-review.sh (#2548).
#
# This block existed for `git commit`, `gh pr create`, `gh pr merge` and `bats`
# — and not for `coderabbit`, which is how six Phase-2 reviews on PR #2635 were
# spent outside the ledger. The raw CLI writes NEITHER of the two records the
# cycle depends on:
#
#   - .claude/logs/cr-local-review.jsonl — the per-SHA ledger that
#     pre-push-pipeline-gate reads. Without a row, the gate correctly says
#     "no review has ever run" for a SHA that was in fact reviewed six times.
#   - the rolling budget log, which scripts/cr/local-review.sh writes INLINE
#     (see its `LOG=.../cr-budget.jsonl` and the jq append beside it). So
#     `rate-budget.sh --check` reported 0/10 used while the real spend was ~7
#     of the prepaid hourly bucket.
#
#     NB for whoever edits budget logging next: hooks/cr-log-invocation.sh
#     looks like the writer and is NOT — nothing executes it; its only
#     references are comments and docs. An earlier version of this comment
#     named it, which would have sent you to edit a file that never runs.
#
# Neither failure is visible at the time — you get a review, it just does not
# count. That is exactly the "advisory gate that can be walked past" class
# epic #2544 exists to close, so it is closed the same way as the others.
#
# Only `review` is blocked. Read-only subcommands (--version, auth, --help)
# spend no budget and write no ledger row, so they stay free.
#
# GLOBAL FLAGS BEFORE THE SUBCOMMAND: `coderabbit --plain review` and
# `coderabbit -c cfg.yaml review` spend exactly the same budget and write
# exactly the same absent ledger row, and the earlier pattern — which required
# `review` to sit immediately after the binary — matched neither. A guard that
# is one flag away from being walked past is the advisory gate this block was
# written to replace, so the flags are absorbed:
#
#   ((-{1,2}[A-Za-z0-9][A-Za-z0-9-]*(=[^[:space:]]+)?|<value>)[[:space:]]+)*
#
# A bare value is accepted between flags because a separated option argument
# (`-c cfg.yaml`) is one, and this hook cannot know which flags take one. The
# cost of that generosity is that a DIFFERENT subcommand reached past a flag —
# `coderabbit --plain auth review-something` — could match. That direction is
# a false BLOCK with a stated override, not a false allow, which is the side a
# fail-closed gate errs on.
cr_flag_run='((-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*(=[^[:space:]]+)?|[A-Za-z0-9._/-]+)[[:space:]]+)*'
cr_pattern="${CMD_SEGMENT_ANCHOR}${ENV_PREFIX}coderabbit[[:space:]]+${cr_flag_run}review${CMD_SEGMENT_END}"
cr_matched=0
if printf '%s' "$CMD" | grep -qE "$cr_pattern"; then
	cr_matched=1
elif [ -n "$WRAPPED_CMD" ] && printf '%s' "$WRAPPED_CMD" | grep -qE "$cr_pattern"; then
	cr_matched=1
fi
# No per-block SKILL_WRAPPER check here, deliberately: the global bypass near
# the top already exits 0 for both the exported and the command-prefix forms,
# so a local copy is unreachable. (And the wrapper's own `coderabbit review`
# is a SUBPROCESS of local-review.sh, which no PreToolUse hook observes at
# all — the exemption it appeared to provide was for a case that cannot
# arise.) No sibling block carries one either.
if [ "$cr_matched" = "1" ]; then
	CMD_PREVIEW=$(printf '%s' "$CMD" | head -c 120)
	CR_DIRECTIVE="BLOCKED: raw \`coderabbit review\` — bypasses the per-SHA ledger AND the budget log.
Command: ${CMD_PREVIEW}...
Why blocked: the raw CLI writes neither .claude/logs/cr-local-review.jsonl (which pre-push-pipeline-gate reads to confirm Phase 2 ran for this SHA) nor .claude/review-log/cr-budget.jsonl (which scripts/cr/local-review.sh appends to inline, and rate-budget.sh reads). You still get a review — it just does not count, and the spend is invisible. Six reviews were lost this way on PR #2635.

To proceed:
  1. scripts/cr/local-review.sh [--base main]
       Budget preflight, Phase-1 convergence check, HEAD-freshness check,
       then the same review — ledgered and budget-logged.

Emergency override (user-facing — audit-logged): GH_SKILL_BYPASS_SKIP=1 coderabbit review ..."
	deny "$CR_DIRECTIVE"
fi

exit 0
