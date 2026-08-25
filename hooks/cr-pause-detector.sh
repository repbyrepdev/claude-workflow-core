#!/bin/bash
set -euo pipefail
# event: PostToolUse
# matcher: Bash
# enforcement: inform — fail-soft auto-remediation; blocking would abort the push tool-result (see header)
# v4.28-W4 (#708) — CR pause-detector: after a successful `git push` to a
# branch with an open PR, check whether CodeRabbit has posted a "Reviews
# paused" notice that has not yet been resumed. If detected, auto-post
# `@coderabbitai resume`; the `@coderabbitai review` follow-up fires ONLY
# when commits landed at-or-after the pause AND no review is already
# queued (#2571 — an unconditional review-request contradicted the
# ship-cycle never-post rule and burned CR rate allowance).
#
# Real-world burn pattern this prevents (PR #683): 10+ rounds of
# push → wait 5min → no review → push again, before noticing the pause.
# Memory rule feedback_cr_review_trigger.md documents the manual flow;
# this hook makes it mechanical.
#
# Two invocation modes:
#   1. PostToolUse hook (default): reads payload from stdin. Trigger:
#      successful `git push` Bash tool-call.
#   2. CLI mode: `cr-pause-detector.sh --pr <N>` (v4.28-W4 #744). Skips
#      the payload check + branch resolution. Lets ship-pr-cycle scripts
#      and CR-poll Monitors invoke pause-check explicitly. Closes the
#      race window where CR auto-pauses AFTER the push (past the
#      hook's check window).
#
# Logic:
#   1. Resolve current branch + open PR for that branch (hook mode) OR
#      take PR from --pr arg (CLI mode).
#   2. Fetch PR's issue-comments timeline; locate the LATEST CR comment
#      containing the "Reviews paused" notice.
#   3. Locate the LATEST `@coderabbitai resume` comment authored by ANY
#      user on the PR.
#   4. If pause-notice timestamp > resume timestamp (or no resume exists),
#      post `@coderabbitai resume`; ALSO post `@coderabbitai review` only
#      when head-commit >= pause-notice time and no CR in-progress marker
#      is newer than the pause (#2571). Append a record (review_posted
#      field) to .claude/logs/cr-resume-fired.jsonl.
#
# Fail-soft: any gh API failure → log to stderr + exit 0. Hook is advisory
# — blocking would abort the user's git-push tool-result, costing more
# than the missed nudge.

# CLI mode detection: if first arg is --pr, take PR explicitly + skip
# payload check below.
EXPLICIT_PR=""
if [ "${1:-}" = "--pr" ]; then
	EXPLICIT_PR="${2:-}"
	if [ -z "$EXPLICIT_PR" ] || ! [[ $EXPLICIT_PR =~ ^[0-9]+$ ]]; then
		echo "error: --pr requires a numeric value (got: '${EXPLICIT_PR:-}')" >&2
		exit 2
	fi
fi

command -v jq >/dev/null 2>&1 || {
	echo "cr-pause-detector: jq missing — skipping" >&2
	exit 0
}

if [ -z "$EXPLICIT_PR" ]; then
	# Hook mode: payload-driven. Surface read/parse failures to stderr
	# so a broken PostToolUse payload doesn't fail-open silently — the
	# operator gets a breadcrumb instead of a missed pause-resume.
	PAYLOAD=$(cat) || {
		echo "cr-pause-detector: stdin read failed (rc=$?) — skipping" >&2
		exit 0
	}
	cmd_err=$(mktemp)
	# Use jq's `has(...)` to distinguish "field present but empty" from
	# "field absent". An empty payload {} or missing tool_input.command
	# is malformed and gets a stderr breadcrumb — don't silently treat
	# it as not-a-push.
	CMD=$(printf '%s' "$PAYLOAD" | jq -r 'if (.tool_input // {} | has("command")) then .tool_input.command else "__MISSING__" end' 2>"$cmd_err") || {
		echo "cr-pause-detector: payload jq parse failed for .tool_input.command ($(head -c 200 "$cmd_err")) — skipping" >&2
		rm -f "$cmd_err"
		exit 0
	}
	if [ "$CMD" = "__MISSING__" ]; then
		echo "cr-pause-detector: payload missing .tool_input.command — skipping (malformed)" >&2
		rm -f "$cmd_err"
		exit 0
	fi
	# exitCode must be present + numeric. jq's `tonumber` will throw on
	# non-numeric, captured by stderr branch.
	RC=$(printf '%s' "$PAYLOAD" | jq -r 'if (.tool_response // {} | has("exitCode")) then (.tool_response.exitCode | tonumber) else "__MISSING__" end' 2>"$cmd_err") || {
		echo "cr-pause-detector: payload jq parse failed for .tool_response.exitCode (non-numeric? $(head -c 200 "$cmd_err")) — skipping" >&2
		rm -f "$cmd_err"
		exit 0
	}
	if [ "$RC" = "__MISSING__" ]; then
		echo "cr-pause-detector: payload missing .tool_response.exitCode — skipping (malformed)" >&2
		rm -f "$cmd_err"
		exit 0
	fi
	rm -f "$cmd_err"
	[ -z "$CMD" ] && exit 0
	[ "$RC" = "0" ] || exit 0

	# Anchor `git push` match: command-start OR shell-separator, optionally
	# preceded by env-var prefixes (so `GIT_TRACE=1 git push` still matches).
	# Same anchoring shape as pr-trigger.sh to stay consistent.
	if ! printf '%s' "$CMD" | grep -qE '((^|[;&|][[:space:]]*)([A-Z_][A-Z0-9_]*=[^[:space:]]*[[:space:]]+)*)git[[:space:]]+push(\b|$)'; then
		exit 0
	fi
fi

# gh required from here on. If missing, advisory-exit.
command -v gh >/dev/null 2>&1 || {
	echo "cr-pause-detector: gh missing — skipping" >&2
	exit 0
}

# Repo root + cd are needed in BOTH modes so gh calls resolve the same
# nameWithOwner. Branch + PR resolution only happen in hook mode (CLI
# mode takes PR from --pr arg).
git_err=$(mktemp)
git_rc=0
REPO_ROOT=$(git rev-parse --show-toplevel 2>"$git_err") || git_rc=$?
if [ "$git_rc" -ne 0 ] || [ -z "$REPO_ROOT" ]; then
	[ -s "$git_err" ] && echo "cr-pause-detector: git rev-parse --show-toplevel failed (rc=$git_rc) — skipping ($(head -c 200 "$git_err"))" >&2
	rm -f "$git_err"
	exit 0
fi
rm -f "$git_err"
cd "$REPO_ROOT" || {
	echo "cr-pause-detector: cannot cd to $REPO_ROOT — skipping" >&2
	exit 0
}

if [ -n "$EXPLICIT_PR" ]; then
	# CLI mode: skip branch resolution, take PR from arg.
	PR="$EXPLICIT_PR"
else
	# Hook mode: resolve current branch + open PR.
	git_err=$(mktemp)
	git_rc=0
	BRANCH=$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>"$git_err") || git_rc=$?
	if [ "$git_rc" -ne 0 ] || [ -z "$BRANCH" ]; then
		[ -s "$git_err" ] && echo "cr-pause-detector: git rev-parse --abbrev-ref HEAD failed (rc=$git_rc) — skipping ($(head -c 200 "$git_err"))" >&2
		rm -f "$git_err"
		exit 0
	fi
	rm -f "$git_err"
	[ "$BRANCH" = "main" ] && exit 0

	# Resolve open PR for current branch.
	gh_err=$(mktemp)
	gh_rc=0
	PR=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty' 2>"$gh_err") || gh_rc=$?
	if [ "$gh_rc" -ne 0 ]; then
		echo "cr-pause-detector: gh pr list failed for $BRANCH (rc=$gh_rc) — skipping ($(head -c 200 "$gh_err"))" >&2
		rm -f "$gh_err"
		exit 0
	fi
	rm -f "$gh_err"
	[ -n "$PR" ] || exit 0
fi

# Resolve nameWithOwner for the gh api call below.
# silent-failure-hunter r2 #2: same rc-branch pattern.
gh_err=$(mktemp)
gh_rc=0
NWO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>"$gh_err") || gh_rc=$?
if [ "$gh_rc" -ne 0 ] || [ -z "$NWO" ]; then
	echo "cr-pause-detector: gh repo view failed (rc=$gh_rc) — skipping ($(head -c 200 "$gh_err"))" >&2
	rm -f "$gh_err"
	exit 0
fi
rm -f "$gh_err"

# Fetch all issue-comments. Need both author + body + createdAt for
# pause/resume correlation. issue-comments includes both bot pause
# notices and human resume comments; review-comments would miss them.
# Comment-analyzer r2 #4: relocated rationale here from above NWO block.
#
# silent-failure-hunter r2 #2: rc-branch + ALSO surface stderr advisory
# even on rc=0 with stderr (paginate-partway warnings).
gh_err=$(mktemp)
gh_rc=0
COMMENTS_JSON=$(gh api "repos/$NWO/issues/$PR/comments" --paginate 2>"$gh_err") || gh_rc=$?
if [ "$gh_rc" -ne 0 ]; then
	echo "cr-pause-detector: gh api comments failed (rc=$gh_rc) — skipping ($(head -c 200 "$gh_err"))" >&2
	rm -f "$gh_err"
	exit 0
fi
if [ -s "$gh_err" ]; then
	# Even on rc=0, stderr non-empty signals paginate warnings or partial
	# fetches — surface for forensics but still proceed with the JSON we got.
	echo "cr-pause-detector: gh api comments fetch had stderr ($(head -c 200 "$gh_err"))" >&2
fi
rm -f "$gh_err"
[ -n "$COMMENTS_JSON" ] || exit 0

# Latest pause notice from CR bot. CR uses author.login = "coderabbitai"
# (lowercase; verified against #683's pause comment timeline). Match the
# full phrase "Reviews paused" (substring) — comment-analyzer r2 #3:
# loose match on "paused" alone would false-fire on review summaries
# mentioning the word in passing.
#
# silent-failure-hunter r2 #3: capture jq stderr so a parse failure on
# truncated/malformed JSON surfaces — prior `2>/dev/null || echo ""`
# silently treated jq failures as "no pause notice" + exited.
jq_err=$(mktemp)
jq_rc=0
LATEST_PAUSE_TS=$(printf '%s' "$COMMENTS_JSON" | jq -r '
	[.[] | select(.user.login == "coderabbitai" and (.body | contains("Reviews paused")))]
	| sort_by(.created_at) | last | .created_at // empty
' 2>"$jq_err") || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
	echo "cr-pause-detector: jq pause-extraction failed (rc=$jq_rc) — skipping ($(head -c 200 "$jq_err"))" >&2
	rm -f "$jq_err"
	exit 0
fi

# No pause notice → nothing to do.
if [ -z "$LATEST_PAUSE_TS" ]; then
	rm -f "$jq_err"
	exit 0
fi

# Latest user-side resume command. CR's docs document `@coderabbitai
# resume` as the literal trigger from a HUMAN user. CR's pause notice
# itself contains the instructional text "To resume, comment @coderabbitai
# resume" — without the bot-author filter, the pause notice's body
# would match its own resume pattern, treating "no human resumed yet"
# as "resumed at the same instant", and the audit log's prior_resume_ts
# would echo the pause's own timestamp instead of JSON null.
# pr-test-analyzer r2 #4 surfaced this via the prior_resume_ts==null
# assertion on the no-prior-resume fixture.
jq_rc=0
LATEST_RESUME_TS=$(printf '%s' "$COMMENTS_JSON" | jq -r '
	[.[] | select(.user.login != "coderabbitai" and (.body | test("@coderabbitai[[:space:]]+resume"; "i")))]
	| sort_by(.created_at) | last | .created_at // empty
' 2>"$jq_err") || jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
	echo "cr-pause-detector: jq resume-extraction failed (rc=$jq_rc) — skipping ($(head -c 200 "$jq_err"))" >&2
	rm -f "$jq_err"
	exit 0
fi
rm -f "$jq_err"

# If a resume is newer than the latest pause, the pause has already been
# acknowledged by a human — no-op so we don't spam the PR.
if [ -n "$LATEST_RESUME_TS" ]; then
	# String comparison of ISO-8601 timestamps is lexically ordered =
	# chronologically ordered. No date-parse dance needed.
	if [ "$LATEST_RESUME_TS" \> "$LATEST_PAUSE_TS" ]; then
		exit 0
	fi
fi

# #2571: decide whether the `@coderabbitai review` follow-up is JUSTIFIED
# before posting it. The ship-cycle rule is NEVER post it (no-op + noise:
# each request spends CR's rate allowance — the same budget whose
# exhaustion causes the 50-min "Review limit reached" stalls). The ONE
# legitimate case: the HEAD COMMIT TIME is at-or-after the pause notice
# (a committer-time proxy for "work landed during the pause" — a commit
# authored before the pause but pushed during it is MISSED by design;
# fail direction is the safe one, the next push recovers) — AND CR is
# not already processing. Anything else gets resume only; the next push (or
# the rolling allowance) triggers the review naturally.
NEED_REVIEW_POST=0
# Epoch comparison, no timezone parsing: %ct is the commit time as a UNIX
# epoch; the pause notice's created_at is GitHub UTC-Z, converted via
# BSD-date (-j -f) with a GNU-date (-d) fallback. Any conversion failure
# leaves NEED_REVIEW_POST=0 — fail toward NOT posting the banned request.
HEAD_COMMIT_EPOCH=$(git -C "$REPO_ROOT" log -1 --format=%ct 2>/dev/null || echo "")
PAUSE_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$LATEST_PAUSE_TS" +%s 2>/dev/null ||
	date -u -d "$LATEST_PAUSE_TS" +%s 2>/dev/null || echo "")
# WARN on undeterminable inputs (phase2 CR): the default is still
# NOT-posting, but "could not determine" must be distinguishable from
# "determined no" in the log trail.
if ! [[ $HEAD_COMMIT_EPOCH =~ ^[0-9]+$ ]]; then
	echo "cr-pause-detector: WARN — head commit time unavailable (git log failed); review-post decision defaults to NOT posting" >&2
fi
if ! [[ $PAUSE_EPOCH =~ ^[0-9]+$ ]]; then
	echo "cr-pause-detector: WARN — pause timestamp '$LATEST_PAUSE_TS' not parseable by date; review-post decision defaults to NOT posting" >&2
fi
if [[ $HEAD_COMMIT_EPOCH =~ ^[0-9]+$ ]] && [[ $PAUSE_EPOCH =~ ^[0-9]+$ ]]; then
	if [ "$HEAD_COMMIT_EPOCH" -ge "$PAUSE_EPOCH" ]; then
		# CR in-progress markers (either wording generation) newer than the
		# pause mean a review is already queued — do not double-request.
		jq_rc=0
		CR_BUSY=$(printf '%s' "$COMMENTS_JSON" | jq -r --arg ts "$LATEST_PAUSE_TS" '
			[.[] | select(.user.login == "coderabbitai"
				and .created_at > $ts
				and ((.body | contains("Currently processing")) or (.body | contains("Come back again in a few minutes"))))]
			| length' 2>/dev/null) || jq_rc=$?
		if [ "$jq_rc" -eq 0 ] && [ "$CR_BUSY" = "0" ]; then
			NEED_REVIEW_POST=1
		fi
	fi
fi

# Pause-not-yet-resumed. Post resume (+ review ONLY when justified above).
# Two separate comments when both fire, so CR's parser sees them as
# distinct triggers (combining into one
# multi-command body has been observed to silently drop the second).
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_DIR="$REPO_ROOT/.claude/logs"
LOG="$LOG_DIR/cr-resume-fired.jsonl"
# silent-failure-hunter r1 #6: under set -euo pipefail, mkdir failure
# (read-only FS, perms) would abort the script before audit log + the
# operator-visible stderr advisories at the end of the script fire. Guard so a fail-soft path
# stays fail-soft.
mkdir -p "$LOG_DIR" 2>/dev/null || {
	echo "cr-pause-detector: cannot create $LOG_DIR — pause detected on PR #$PR but cannot audit-log; skipping" >&2
	exit 0
}

# p2r4 CR: the two posts are tracked INDEPENDENTLY — one shared rc
# could not say which failed, and the audit status blamed both.
RESUME_RC=0
REVIEW_RC=0
REVIEW_POSTED_OK=0
gh pr comment "$PR" --body "@coderabbitai resume" >/dev/null 2>&1 || RESUME_RC=$?
if [ "$RESUME_RC" -eq 0 ] && [ "$NEED_REVIEW_POST" = "1" ]; then
	# r1 F13: the audit field records the OUTCOME — a decided-but-failed
	# post must not read as posted.
	if gh pr comment "$PR" --body "@coderabbitai review" >/dev/null 2>&1; then
		REVIEW_POSTED_OK=1
	else
		REVIEW_RC=$?
	fi
fi
POST_RC=$((RESUME_RC != 0 ? RESUME_RC : REVIEW_RC))

# Audit-log the attempt regardless of POST_RC so a failed post still
# leaves a breadcrumb for forensics. status names WHICH post failed.
STATUS="ok"
if [ "$RESUME_RC" -ne 0 ]; then
	STATUS="errored-resume-post-failed"
elif [ "$REVIEW_RC" -ne 0 ]; then
	STATUS="errored-review-post-failed"
fi
# code-reviewer r1 #4: `prior_resume_ts` was emitted as empty string
# when no prior resume existed — downstream couldn't distinguish
# 'never resumed' from 'resumed at unparseable timestamp'. Now: emit
# as JSON null when absent. --argjson with a JSON literal handles the
# null vs string-with-content branch cleanly.
if [ -n "${LATEST_RESUME_TS:-}" ]; then
	resume_arg=(--arg prior_resume_ts "$LATEST_RESUME_TS")
else
	resume_arg=(--argjson prior_resume_ts null)
fi
# silent-failure-hunter r3 #2: under set -euo pipefail, jq failure or
# >>"$LOG" failure (ENOSPC, perms changed mid-script) would abort BEFORE
# the operator-visible stderr advisories below fire. Capture rc so the
# operator still gets a console signal even when forensics-write fails.
log_rc=0
# v4.28-W4 #744: CLI mode skips branch resolution → BRANCH unbound under
# set -u. Default to "(cli)" so the audit log is still well-formed.
jq -nc --arg ts "$TS" --arg pr "$PR" --arg branch "${BRANCH:-(cli)}" \
	--arg pause_ts "$LATEST_PAUSE_TS" "${resume_arg[@]}" \
	--arg status "$STATUS" --argjson rc "$POST_RC" --argjson review_posted "$REVIEW_POSTED_OK" \
	'{ts:$ts, pr:($pr|tonumber), branch:$branch, pause_ts:$pause_ts, prior_resume_ts:$prior_resume_ts, status:$status, post_rc:$rc, review_posted:($review_posted == 1)}' \
	>>"$LOG" || log_rc=$?
if [ "$log_rc" -ne 0 ]; then
	echo "cr-pause-detector: audit-log write failed (rc=$log_rc) for PR #$PR — post may have happened but is not recorded in $LOG" >&2
fi

if [ "$POST_RC" -eq 0 ]; then
	if [ "$NEED_REVIEW_POST" = "1" ]; then
		echo "cr-pause-detector: PR #$PR was paused — auto-posted @coderabbitai resume + review (commits landed during the pause, no review queued)" >&2
	else
		echo "cr-pause-detector: PR #$PR was paused — auto-posted @coderabbitai resume ONLY (#2571: no post-pause commits, review already queued, OR the decision inputs were undeterminable — see any WARNs above; the banned review-request stays unposted)" >&2
	fi
else
	echo "cr-pause-detector: PR #$PR pause detected but gh pr comment failed (rc=$POST_RC); see $LOG" >&2
fi

exit 0
