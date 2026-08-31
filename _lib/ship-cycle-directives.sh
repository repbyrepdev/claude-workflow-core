#!/bin/bash
set -u
# auto-register: false
# v0.32.12 (#283): ship-pr-cycle next-step directive emitter — the SSOT for the
# per-stage/edge directive bodies.
#
# ship-pr-cycle.sh sources this + _lib/hook-ack.sh, then calls
# `_emit_stage_directive <label>` at each stage/edge transition. The directive:
#   - ALWAYS prints to stdout (advisory, immediate),
#   - registers an UN-SKIPPABLE hook-ack pending entry (the operator must Read
#     the diagnostic file to ack before the next Bash/Edit/Write) — UNLESS
#     SHIP_PR_IN_RESUME=1, in which case only the stdout print happens.
#
# Why suppress under SHIP_PR_IN_RESUME: cmd_resume auto-walks intermediate
# stages in a loop; a pending entry for each would be stale by the time control
# returns to the operator. Only the stage `resume` STOPS at needs a directive,
# and that stage's own path (e.g. the phase1 agent directive) handles it.
#
# Read-to-clear (hook-ack-clear.sh on PostToolUse Read) ⇒ NO deadlock, unlike a
# stage marker that only clears on advance. Reuses the existing hook-ack infra —
# no parallel system (#283).
#
# Bodies live here (one `case` arm each) so a directive is defined ONCE even
# when emitted from multiple call sites. IMPLEMENTED arms:
# push-to-pr, merge-conflict, merge-gate, pr-create-preread, phase2-preread,
# cr-thread-reply.
# Add an arm per NEW stage/edge as #283 expands (round-complete, skill-usage,
# efficiency-grouping, ...). KEEP THIS LIST IN SYNC — it drifted once already
# (cr-thread-reply shipped without being listed), and the list is what a
# reader consults before adding an arm that already exists.
#
# PREREAD ARMS (#223, epics #1375/#1384) — pr-create-preread, phase2-preread:
# a CREATION-TIME enforcement gate. Unlike the advisory arms above (whose
# ack file_path is a generated DIAGNOSTIC the operator reads to ack), a
# preread arm keys its ack-pending file_path at the ACTUAL template/SKILL.md
# the operator must read BEFORE the creation step proceeds. Reading THAT file
# is what clears the block (hook-ack-clear.sh on PostToolUse Read matches the
# file_path) — so the Read of the template IS the enforced preread. This
# closes the gap that let a PR body be drafted without first reading
# .github/pull_request_template.md. The preread file_path is emitted via
# `_emit_preread_ack` (a thin wrapper around hook_ack_append) rather than the
# diagnostic-file path the other arms use.

# _emit_preread_ack <label> <preread_file_rel> <body>
# Registers a hook-ack-pending entry whose file_path is the REPO-RELATIVE
# preread target (the template/SKILL.md), so the next Bash/Edit/Write is
# BLOCKED until the operator Reads that exact file. Best-effort: degrades to
# the (already-printed) stdout directive if hook-ack infra is unavailable or
# we are inside a resume auto-walk. Mirrors _emit_stage_directive's guards.
_emit_preread_ack() {
	local label=${1:-} preread=${2:-}
	[ -n "$preread" ] || return 0
	# Auto-walk (cmd_resume) suppresses the ack-pending; the caller's stdout
	# print still fires so the resume log carries the directive for context.
	if [ "${SHIP_PR_IN_RESUME:-0}" = "1" ]; then
		return 0
	fi
	command -v hook_ack_append >/dev/null 2>&1 || return 0
	# file_path = the preread target itself (NOT a diagnostic). hook-ack-clear
	# matches absolute/repo-relative/basename forms, so the repo-relative path
	# clears when the operator Reads the file by its absolute path.
	hook_ack_append "ship-pr-cycle-preread" "$label" "$preread" 2>/dev/null || true
}

_emit_stage_directive() {
	local label=${1:-} body preread=""
	case "$label" in
	push-to-pr)
		body="PR is pushed. Run 'scripts/ship-pr-cycle.sh next' again to watch CR-in-CI to terminal (it auto-polls). CR-in-CI is the SERVER-SIDE GitHub bot, INDEPENDENT of the 10/hr local CR-CLI budget — it posts findings as PR review COMMENTS (not always a required-check failure), so poll the PR comments + the summary comment, not just 'gh pr checks'. The CR summary comment flips to 'No actionable comments 🎉' when clean — read THAT. If you step away, ScheduleWakeup ~270s. NEVER post '@coderabbitai review' (no-op + noise)."
		;;
	merge-conflict)
		body="Merge conflict on this PR. Resolve via CodeRabbit's resolver — run the cr-resolve-conflict skill ('run.sh --pr <N>'), which posts '@coderabbitai resolve merge conflict' + polls the outcome. Do NOT hand-resolve and do NOT spend the local CR-CLI budget on conflicts. If CR declines/times out (rc 2): 'git fetch origin && git rebase origin/<base>', resolve, push. Once the resolution commit lands, re-run 'next' — if CR resolved it server-side, pull first (--ff-only) so the merged result is re-reviewed before merge-gate."
		;;
	merge-gate)
		body="merge-gate — the ONLY operator merge gate (per the 4-gate autonomy model). Before approving: confirm required checks are green AND CR is clean via the github-pr-merge skill's _pr-cr-findings.sh (ALL THREE buckets zero: unresolved current + stranded-outdated + walkthrough pre-merge). APPROVE=1 is the ONLY sanctioned proceed — never a *_SKIP. Merge via the github-pr-merge skill 'run.sh' (--squash --delete-branch). AFTER merge: remember merge != deploy — the rollout/verify step (consumer pin bumps, hash-drift --verify, refresh-from-source) is SEPARATE."
		;;
	pr-create-preread)
		# #223 CREATION-TIME PREREAD GATE. preread keys the ack at the PR
		# template so the NEXT command is BLOCKED until the operator Reads it.
		preread=".github/pull_request_template.md"
		body="PREREAD GATE — no PR exists yet for this branch. BEFORE creating the PR you MUST Read the PR template so the body conforms to it (this gap once let a PR body be drafted without it):
    1. Read .github/pull_request_template.md  (← reading THIS file clears the block below)
    2. Read skills/github-pr-creation/SKILL.md (the creation procedure SSOT)
  Until you Read .github/pull_request_template.md, the next Bash/Edit/Write is BLOCKED (hook-ack pending). Then open the PR via the github-pr-creation skill ('/github-pr-creation' or run.sh), filling EVERY template section. Then re-run 'scripts/ship-pr-cycle.sh next' from push to advance to cr-in-ci-wait.
  Opt-out (manual PR control): SHIP_NO_PR=1 ship-pr-cycle.sh next"
		;;
	phase2-preread)
		# #223 PREREAD GATE at phase2 entry — read the Phase 2 process SSOT
		# before running the local CR-CLI loop. preread keys the ack at the
		# ship-pr-cycle SKILL.md (the Phase 2 procedure lives there). The plugin
		# ships it at skills/ship-pr-cycle/SKILL.md; a CONSUMER repo has it at
		# .claude/skills/ship-pr-cycle/SKILL.md (#223 r1 code-reviewer) —
		# hook-ack-clear's path-SUFFIX match clears the block when EITHER is Read:
		# both absolute paths end with the same `/skills/ship-pr-cycle/SKILL.md`
		# suffix (dogfood-verified, CR-CLI r1), while an unrelated same-basename
		# SKILL.md does NOT clear it (the basename-collision the suffix match fixed).
		preread="skills/ship-pr-cycle/SKILL.md"
		body="PREREAD GATE — advanced INTO phase2 (local CR-CLI review loop). BEFORE running CR, Read the Phase 2 process so you apply the cap/cache/prove-yourself discipline correctly:
    1. Read the ship-pr-cycle SKILL.md — skills/ship-pr-cycle/SKILL.md in the plugin, or .claude/skills/ship-pr-cycle/SKILL.md in a consumer repo (← reading it clears the block below; see the [phase2] section + 'Phase 2 / CR findings' rule)
  Until you Read it, the next Bash/Edit/Write is BLOCKED (hook-ack pending). Phase 2 invokes the local CR-CLI via the cap from phase1-scaler; the content-hash cache short-circuits re-review of an unchanged surface (don't burn the 10/hr budget). On findings: apply OR reject-with-prove-yourself in-PR, commit, let post-commit resume re-fire — do NOT advance with open findings. Then re-run 'scripts/ship-pr-cycle.sh next'."
		;;
	cr-thread-reply)
		body="CR THREAD REPLY — classify each UNADDRESSED thread, then reply with evidence. The rule is: never resolve a CR thread by hand; reply and let CR resolve. This stage is where that reply happens, and it is the step whose absence stalled #2540 and #2635 at merge-gate with non-zero threads and no defined action.
  Read the list above, then per thread (node ids via --json):
    verified-fixed     → scripts/cr/thread-reply.sh <pr> --thread <id> --class verified-fixed --path <p> --body '...'
                         Cite the commit AND the verified line range. --path is REQUIRED and is checked with
                         'git show HEAD:<path>' BEFORE the reply posts — on #2540 a commit message claimed a fix
                         that had been lost from the tree, and CR was right to keep flagging it.
    false-positive     → --class false-positive --body '...'   Include the command you ran and its output.
    rejected-by-design → --class rejected-by-design --body '...'  Include the rationale AND where it is recorded in-tree.
    actionable         → NOT repliable. Fix it: coderabbit:autofix, commit, let the delta re-review confirm.
  A replied thread becomes 'replied-awaiting-CR' — a distinct, NON-blocking state.
  UNADDRESSED and STRANDED threads both block. STRANDED (unresolved + outdated) is NOT repliable — replying to
  every unaddressed thread and re-running will still be refused while one exists. Resolve those instead:
      scripts/cr/resolve-stranded.sh <pr>
  Re-run 'scripts/ship-pr-cycle.sh next' once unaddressed AND stranded are both zero."
		;;
	*)
		echo "_emit_stage_directive: unknown label '$label' — no directive emitted" >&2
		return 0
		;;
	esac
	printf '\n  ⚠ NEXT — do NOT skip this step:\n%s\n' "$body"
	# Auto-walk (cmd_resume) suppresses the ack-pending; stdout print above still
	# fires so the resume log carries the directive for context.
	if [ "${SHIP_PR_IN_RESUME:-0}" = "1" ]; then
		return 0
	fi
	# PREREAD arms (#223): key the ack-pending at the preread FILE itself, so
	# Reading that file (template/SKILL.md) clears the block — that Read IS the
	# enforced preread. Returns here so the diagnostic-file path below (used by
	# the advisory arms) is not also taken.
	if [ -n "$preread" ]; then
		_emit_preread_ack "$label" "$preread"
		return 0
	fi
	# Best-effort ack-enforcement: any failure degrades to the stdout print
	# (advisory) — never aborts the orchestrator, never deadlocks.
	command -v hook_ack_diagnostic_write >/dev/null 2>&1 || return 0
	local diag
	diag=$(hook_ack_diagnostic_write "ship-pr-cycle-next" "$label" "$body" 2>/dev/null) || return 0
	[ -n "$diag" ] || return 0
	hook_ack_append "ship-pr-cycle-next" "$label" "$diag" 2>/dev/null || true
}
